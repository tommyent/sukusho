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

    /// Entries whose capture is gone. Only a complete scan can say that: one
    /// where History and the Recordings folder both read in full. An empty
    /// scan more likely means a failed load than a Library emptied at once,
    /// so it removes nothing either.
    static func removed(entryIDs: some Sequence<String>, liveIDs: Set<String>, isComplete: Bool) -> [String] {
        !isComplete || liveIDs.isEmpty ? [] : entryIDs.filter { !liveIDs.contains($0) }
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

/// Library search text, matched the way the name and tags are: ignoring
/// case and accents, so "cafe" finds "Café".
nonisolated struct CaptureLibraryQuery: Equatable {
    let text: String
    let folded: String

    init(_ raw: String) {
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = Self.fold(text)
    }

    var isEmpty: Bool { text.isEmpty }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `foldedText` is a capture's recognized text, already folded once.
    func matches(fields: [String], foldedText: String?) -> Bool {
        isEmpty || fields.contains { $0.localizedStandardContains(text) } || foldedText?.contains(folded) == true
    }

    /// Paragraphs that contain the query first, each group in its own order.
    func ordered(_ paragraphs: [String]) -> [String] {
        guard !isEmpty else { return paragraphs }
        let hits = paragraphs.map { Self.fold($0).contains(folded) }
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

    private static let codeMarks = ["{", "}", "()", "=>", "->", ";", "//", "let ", "var ", "func ", "const ", "return ", "import ", "def "]

    private static func looksLikeCode(_ line: String) -> Bool {
        codeMarks.contains { line.contains($0) }
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
