import CoreGraphics
import CryptoKit
import Foundation

/// One line Vision read, its box normalized to the image with a top-left origin.
nonisolated struct CaptureTextLine: Sendable, Equatable {
    var text: String
    var box: CGRect
}

/// The words the Library found in one capture. Kept apart from the capture,
/// its sidecar and History, so the whole index can be thrown away and read
/// again. It never leaves this Mac.
nonisolated struct CaptureTextEntry: Codable, Sendable, Equatable {
    /// Bump to read every capture again after the reading changes.
    static let currentVersion = 1

    var id: String
    var version = Self.currentVersion
    /// The capture's path plus modification date when it was read, so an
    /// edited capture is read again.
    var fingerprint: String
    var paragraphs: [String]
    /// A recording's saved captions, joined.
    var transcript: String?

    /// What the inspector shows and Copy Text copies.
    var displayParagraphs: [String] { paragraphs + (transcript.map { [$0] } ?? []) }

    func isCurrent(fingerprint: String) -> Bool {
        version == Self.currentVersion && self.fingerprint == fingerprint
    }
}

nonisolated extension CaptureTextEntry {
    /// What a read found: each frame's lines regrouped into paragraphs, with
    /// text a later frame repeats dropped. Nil when no frame could be read,
    /// even beside a transcript, so the capture stays unread and is tried
    /// again instead of being stored without the words on screen.
    init?(id: String, fingerprint: String, frames: [[CaptureTextLine]?], transcript: String?) {
        let read = frames.compactMap { $0 }
        guard !read.isEmpty else { return nil }
        var seen = Set<String>()
        self.init(id: id, fingerprint: fingerprint,
                  paragraphs: read.flatMap(CaptureReadableText.paragraphs).filter { seen.insert($0).inserted },
                  transcript: transcript?.isEmpty == false ? transcript : nil)
    }
}

/// Which captures to read and which entries to forget after a Library scan.
nonisolated enum CaptureTextIndexPlan {
    struct Capture: Sendable, Equatable {
        var id: String
        var fingerprint: String
        var createdAt: Date
    }

    /// Captures with no current entry, newest first.
    static func stale(_ captures: [Capture], entries: [String: CaptureTextEntry], skipping: Set<String> = []) -> [Capture] {
        captures.filter { capture in
            !skipping.contains(capture.fingerprint) && entries[capture.id]?.isCurrent(fingerprint: capture.fingerprint) != true
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// The long side, in pixels, to read a width × height image at: at most
    /// 4096, but never shrinking the short side below 1600, so Retina body
    /// text in a tall scrolling capture stays legible when read in tiles
    /// (at 1000, Vision misread 24 px text), never past 40 MP decoded, and
    /// never larger than the image. 4096 for an unknown size.
    static func readingSize(width: Int, height: Int) -> Int {
        let long = Double(max(width, height)), short = Double(min(width, height))
        guard short > 0 else { return 4096 }
        let scale = min(1, max(4096 / long, 1600 / short), (40_000_000 / (long * short)).squareRoot())
        return Int((long * scale).rounded())
    }

    /// Entries whose capture is gone. Only a complete scan can say that: one
    /// where History and the Recordings folder both read in full. An empty
    /// scan more likely means a failed load than a Library emptied at once,
    /// so it removes nothing either.
    static func removed(entryIDs: some Sequence<String>, liveIDs: Set<String>, isComplete: Bool) -> [String] {
        !isComplete || liveIDs.isEmpty ? [] : entryIDs.filter { !liveIDs.contains($0) }
    }
}

/// Vision reads an image at a bounded size of its own, so a long scrolling
/// capture read in one go comes back empty. One more than twice as long as
/// it is wide (or the other way round) is read in overlapping tiles about
/// 1.5 short sides long; each tile keeps only the lines centred in its own
/// band, so the overlap yields each line once.
nonisolated enum CaptureTextTiling {
    struct Tile: Equatable {
        /// In the image's pixels, top-left origin, as `CGImage.cropping` takes it.
        var rect: CGRect
        /// Where along the long side this tile's lines may be centred.
        var owned: Range<CGFloat>
    }

    static func tiles(width: Int, height: Int) -> [Tile] {
        let w = CGFloat(width), h = CGFloat(height)
        let isTall = h >= w
        let long = max(w, h), short = min(w, h)
        guard short > 0, long > short * 2 else { return [Tile(rect: CGRect(x: 0, y: 0, width: w, height: h), owned: 0..<max(long, 1))] }
        let length = (short * 1.5).rounded(), overlap = (short / 5).rounded()
        var tiles: [Tile] = []
        var start: CGFloat = 0
        while true {
            let end = min(start + length, long)
            let owned = (start == 0 ? 0 : start + overlap / 2)..<(end >= long ? long : end - overlap / 2)
            tiles.append(Tile(rect: isTall ? CGRect(x: 0, y: start, width: w, height: end - start)
                                           : CGRect(x: start, y: 0, width: end - start, height: h), owned: owned))
            if end >= long { return tiles }
            start = end - overlap
        }
    }

    /// Each tile's lines, its boxes normalized to the tile, as one image's.
    static func merge(_ pieces: [(tile: Tile, lines: [CaptureTextLine])], width: Int, height: Int) -> [CaptureTextLine] {
        let w = CGFloat(width), h = CGFloat(height)
        return pieces.flatMap { tile, lines in
            lines.compactMap { line in
                let r = tile.rect
                let box = CGRect(x: (r.minX + line.box.minX * r.width) / w, y: (r.minY + line.box.minY * r.height) / h,
                                 width: line.box.width * r.width / w, height: line.box.height * r.height / h)
                let centre = h >= w ? box.midY * h : box.midX * w
                return tile.owned.contains(centre) ? CaptureTextLine(text: line.text, box: box) : nil
            }
        }
    }
}

/// The index on disk: one small JSON file per capture.
nonisolated struct CaptureTextIndexStore: Sendable {
    let directory: URL

    func loadAll() -> [String: CaptureTextEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var entries: [String: CaptureTextEntry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(CaptureTextEntry.self, from: data) else { continue }
            entries[entry.id] = entry
        }
        return entries
    }

    func save(_ entry: CaptureTextEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url(for: entry.id), options: .atomic)
    }

    func remove(ids: [String]) {
        for id in ids { try? FileManager.default.removeItem(at: url(for: id)) }
    }

    /// Recording IDs hold file paths, so files are named by a hash of the ID.
    func url(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

/// Library search text. Plain words match the way the name and tags always
/// have, ignoring case and accents, so "cafe" finds "Café"; operators such as
/// `app:chrome` narrow by a field. Every part has to match.
nonisolated struct CaptureLibraryQuery: Equatable {
    /// The operators the field understands. Anything else with a colon (a
    /// URL, `foo:bar`) stays a plain word.
    static let operatorNames: Set<String> = ["app"]

    /// The plain text between operators, each run matched as typed.
    let phrases: [String]
    private let foldedPhrases: [String]
    /// `app:` values, folded.
    let apps: [String]

    init(_ raw: String) {
        let parsed = Self.parse(raw)
        phrases = parsed.phrases
        foldedPhrases = parsed.phrases.map(Self.fold)
        apps = (parsed.operators["app"] ?? []).map(Self.fold)
    }

    var isEmpty: Bool { phrases.isEmpty && apps.isEmpty }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Splits typed text into plain phrases and operator values. An operator
    /// starts a word; its value, after at most one space, runs to the next
    /// space or is quoted: `app:"visual studio"`. An operator with no value
    /// yet is ignored.
    static func parse(_ raw: String) -> (phrases: [String], operators: [String: [String]]) {
        var phrases: [String] = []
        var operators: [String: [String]] = [:]
        var plain = ""
        func flush() {
            let phrase = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { phrases.append(phrase) }
            plain = ""
        }
        var index = raw.startIndex
        while index < raw.endIndex {
            let atWordStart = index == raw.startIndex || raw[raw.index(before: index)].isWhitespace
            let colon = raw[index...].firstIndex { $0 == ":" || $0.isWhitespace }
            let name = colon.map { raw[index..<$0].lowercased() } ?? ""
            guard atWordStart, let colon, raw[colon] == ":", operatorNames.contains(name) else {
                plain.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            var valueStart = raw.index(after: colon)
            // One space after the colon is fine: "app: chrome".
            if valueStart < raw.endIndex, raw[valueStart] == " " {
                let next = raw.index(after: valueStart)
                if next < raw.endIndex, !raw[next].isWhitespace { valueStart = next }
            }
            let value: Substring
            if valueStart < raw.endIndex, raw[valueStart] == "\"" {
                valueStart = raw.index(after: valueStart)
                let close = raw[valueStart...].firstIndex(of: "\"") ?? raw.endIndex
                value = raw[valueStart..<close]
                index = close < raw.endIndex ? raw.index(after: close) : close
            } else {
                let end = raw[valueStart...].firstIndex(where: \.isWhitespace) ?? raw.endIndex
                value = raw[valueStart..<end]
                index = end
            }
            flush()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { operators[name, default: []].append(trimmed) }
        }
        flush()
        return (phrases, operators)
    }

    /// `fields` are matched as typed; `foldedText` is a capture's recognized
    /// text, already folded once.
    func matches(fields: [String], foldedText: String?, source: CaptureSource? = nil) -> Bool {
        apps.allSatisfy { source?.matchesApp($0) == true }
            && zip(phrases, foldedPhrases).allSatisfy { phrase, folded in
                fields.contains { $0.localizedStandardContains(phrase) } || foldedText?.contains(folded) == true
            }
    }

    /// Paragraphs that contain a phrase first, each group in its own order.
    func ordered(_ paragraphs: [String]) -> [String] {
        guard !foldedPhrases.isEmpty else { return paragraphs }
        let hits = paragraphs.map { paragraph in
            let folded = Self.fold(paragraph)
            return foldedPhrases.contains { folded.contains($0) }
        }
        return zip(paragraphs, hits).filter(\.1).map(\.0) + zip(paragraphs, hits).filter { !$0.1 }.map(\.0)
    }
}

/// Turns Vision's lines into readable paragraphs. Vision reports each visual
/// line on its own, row by row, which interleaves columns and breaks prose
/// mid-sentence. A line joins the paragraph whose last line sits directly
/// above it, at the same left edge and text size, so wrapped prose reads as
/// one paragraph and a sidebar stays apart from the content beside it.
/// Stray fragments ("G", a lone line number) are left out.
/// Adapted from upstream Screendrop's CaptureReadableText (CC0).
nonisolated enum CaptureReadableText {
    static func paragraphs(from lines: [CaptureTextLine]) -> [String] {
        var paragraphs: [Paragraph] = []
        for line in lines where isMeaningful(line.text) {
            let isCode = looksLikeCode(line.text)
            if let index = paragraphs.lastIndex(where: { $0.continues(with: line.box, isCode: isCode) }) {
                paragraphs[index].lines.append(line.text)
                paragraphs[index].lastBox = line.box
                paragraphs[index].isCode = paragraphs[index].isCode || isCode
            } else {
                paragraphs.append(Paragraph(lines: [line.text], lastBox: line.box, minX: line.box.minX, isCode: isCode))
            }
        }
        return paragraphs.map { joined($0.lines) }
    }

    private struct Paragraph {
        var lines: [String]
        var lastBox: CGRect
        /// The first line's left edge.
        let minX: CGFloat
        var isCode: Bool

        /// `box` is the next line: directly below the last one, at its text
        /// size, and at its left edge. Code may also indent or outdent.
        func continues(with box: CGRect, isCode lineIsCode: Bool) -> Bool {
            let lineHeight = lastBox.height
            guard lineHeight > 0,
                  abs(box.height - lineHeight) < lineHeight * 0.35,
                  box.minY > lastBox.minY + lineHeight * 0.5,
                  box.minY - lastBox.maxY < lineHeight * 0.9 else { return false }
            if abs(box.minX - lastBox.minX) < 0.015 { return true }
            return (isCode || lineIsCode) && box.minX > minX - 0.015 && box.minX - minX < 0.15
        }
    }

    private static let codeSymbols = ["{", "}", "()", "=>", "->", ";", "//"]
    private static let codeKeywords = ["let ", "var ", "func ", "const ", "return ", "import ", "def "]

    /// A symbol anywhere, or a keyword where a statement starts with code
    /// after it: an assignment or subscript, or a call straight after one
    /// name. "let total = 2" and "def greet(name):" are code; "return the
    /// form (signed)" and "import duties: pay by Friday" aren't.
    private static func looksLikeCode(_ line: String) -> Bool {
        codeSymbols.contains { line.contains($0) }
            || codeKeywords.contains { line.hasPrefix($0) }
                && (line.contains { "=[".contains($0) } || line.range(of: #"^\w+ [A-Za-z_][\w.]*\("#, options: .regularExpression) != nil)
    }

    /// Prose rejoins into flowing text; code keeps its lines.
    private static func joined(_ lines: [String]) -> String {
        guard lines.count > 1 else { return lines.first ?? "" }
        if lines.filter(looksLikeCode).count * 3 >= lines.count { return lines.joined(separator: "\n") }
        return lines.dropFirst().reduce(lines[0]) { text, line in
            text.hasSuffix("-") ? String(text.dropLast()) + line : text + " " + line
        }
    }

    /// At least two letters or digits, and a letter unless it's a longer
    /// run such as a date or an amount.
    private static func isMeaningful(_ text: String) -> Bool {
        let alphanumerics = text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        guard alphanumerics.count >= 2 else { return false }
        return alphanumerics.contains(where: CharacterSet.letters.contains) || text.count >= 5
    }
}
