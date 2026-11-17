//
//  CapturedDocumentText.swift
//  Screendrop
//

import CoreGraphics
import CoreImage
import Foundation
import Vision

/// One piece of a captured area's text, as Vision's document recognition groups it.
nonisolated enum CapturedTextBlock: Equatable, Sendable {
    case paragraph(String)
    /// Each item's marker as written ("•", "2.") and its text.
    case list([(marker: String, text: String)])
    /// Rows of cells.
    case table([[String]])

    static func == (lhs: CapturedTextBlock, rhs: CapturedTextBlock) -> Bool {
        switch (lhs, rhs) {
        case let (.paragraph(a), .paragraph(b)): a == b
        case let (.list(a), .list(b)): a.map(\.marker) == b.map(\.marker) && a.map(\.text) == b.map(\.text)
        case let (.table(a), .table(b)): a == b
        default: false
        }
    }
}

/// Capture Text for areas that hold a table or a list: the text keeps its shape. Two versions go
/// on the clipboard, so Paste gives the structure where an app takes it and Paste and Match
/// Style gives plain text.
nonisolated enum CapturedDocumentText {
    /// A block and where it sits, in Vision's normalized space (origin bottom-left).
    struct Placed {
        let block: CapturedTextBlock
        let box: CGRect
    }

    /// Top to bottom. A paragraph inside a table or a list is that table's or list's own text
    /// again, and is left out.
    static func ordered(_ placed: [Placed]) -> [CapturedTextBlock] {
        let structures = placed.filter { if case .paragraph = $0.block { false } else { true } }
        return placed.filter { item in
            guard case .paragraph = item.block else { return true }
            return !structures.contains { $0.box.insetBy(dx: -0.005, dy: -0.005).contains(CGPoint(x: item.box.midX, y: item.box.midY)) }
        }
        .sorted { $0.box.maxY > $1.box.maxY }
        .map(\.block)
    }

    /// Rows as tab-separated lines, which spreadsheets paste as cells; list items one per line
    /// behind their markers.
    static func plainText(_ blocks: [CapturedTextBlock]) -> String {
        blocks.map { block in
            switch block {
            case let .paragraph(text): text
            case let .list(items): items.map { $0.marker.isEmpty ? $0.text : "\($0.marker) \($0.text)" }.joined(separator: "\n")
            case let .table(rows):
                rows.map { $0.map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ") }
                    .joined(separator: "\t") }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    static func html(_ blocks: [CapturedTextBlock]) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        let body = blocks.map { block in
            switch block {
            case let .paragraph(text): return "<p>\(escaped(text))</p>"
            case let .list(items):
                // Numbered or lettered markers make an ordered list; bullets and hyphens don't.
                let tag = items.first?.marker.contains(where: \.isLetter) == true
                    || items.first?.marker.contains(where: \.isNumber) == true ? "ol" : "ul"
                return "<\(tag)>" + items.map { "<li>\(escaped($0.text))</li>" }.joined() + "</\(tag)>"
            case let .table(rows):
                return "<table>" + rows.map { "<tr>" + $0.map { "<td>\(escaped($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
            }
        }.joined()
        return "<meta charset=\"utf-8\">" + body
    }

    /// The blocks of `image` when it holds a table or a list; nil otherwise, and when Vision
    /// fails, so plain text keeps going through `ImageTextRecognizer` exactly as before.
    /// The image Vision reads best: a capture under 1.5 pixels per point (a 1× display) scaled to 2. At 1×, 10 pt text
    /// lost whole words ("Uses") and misread others, and the same capture scaled up read cleanly (Fable live check C,
    /// 2026-11-17). Anything sharper, or an image that can't be scaled, is returned as it is.
    static func readable(_ image: CGImage, pixelsPerPoint: CGFloat) -> CGImage {
        guard let scale = readableScale(width: image.width, height: image.height, pixelsPerPoint: pixelsPerPoint) else { return image }
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter?.setValue(scale, forKey: kCIInputScaleKey)
        filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter?.outputImage,
              let scaled = CIContext().createCGImage(output, from: output.extent.integral) else { return image }
        return scaled
    }

    /// At most this many pixels after scaling, about 144 MB at 4 bytes a pixel (Astra, 2026-11-17: an 8K capture at 1×
    /// would have become 15360 × 8640, about 531 MB).
    static let readableMaxPixels = 36_000_000.0

    /// How much `readable` scales an image by: 2× its pixels per point, less when that would pass `readableMaxPixels`,
    /// and nil when it's sharp enough already or the cap leaves too little gain to be worth it.
    static func readableScale(width: Int, height: Int, pixelsPerPoint: CGFloat) -> CGFloat? {
        guard pixelsPerPoint > 0, pixelsPerPoint < 1.5, width > 0, height > 0 else { return nil }
        let scale = min(2 / pixelsPerPoint, CGFloat((readableMaxPixels / Double(width * height)).squareRoot()))
        return scale >= 1.25 ? scale : nil
    }

    /// Capture Text's image of `url`, upright and made `readable` when the drawn `area` (in points) gives its pixels
    /// per point. Decoding and scaling are slow on a big capture: call it off the main actor.
    static func readableImage(at url: URL, area: CGRect?) -> CGImage? {
        guard let image = ScreenshotImageLoader.uprightImage(at: url) else { return nil }
        guard let area, area.width > 0 else { return image }
        return readable(image, pixelsPerPoint: CGFloat(image.width) / area.width)
    }

    static func structuredBlocks(in image: CGImage) async -> [CapturedTextBlock]? {
        guard let document = try? await RecognizeDocumentsRequest().perform(on: image).first?.document,
              !document.tables.isEmpty || !document.lists.isEmpty else { return nil }
        var placed: [Placed] = []
        for table in document.tables {
            let rows = table.rows.map { $0.map { $0.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines) } }
            if rows.contains(where: { !$0.isEmpty }) {
                placed.append(Placed(block: .table(rows), box: table.boundingRegion.boundingBox.cgRect))
            }
        }
        for list in document.lists where !list.items.isEmpty {
            let items = list.items.map { (marker: $0.markerString.trimmingCharacters(in: .whitespaces),
                                          text: $0.itemString.trimmingCharacters(in: .whitespacesAndNewlines)) }
            placed.append(Placed(block: .list(items), box: list.boundingRegion.boundingBox.cgRect))
        }
        for paragraph in document.paragraphs {
            // Its screen lines, not its transcript (which Vision has already joined): Capture Text joins them itself,
            // unless "Keep line breaks" is on (Fable live check B, 2026-11-17).
            let text = paragraph.lines.map(\.transcript).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { placed.append(Placed(block: .paragraph(text), box: paragraph.boundingRegion.boundingBox.cgRect)) }
        }
        let blocks = ordered(placed)
        return blocks.isEmpty ? nil : blocks
    }
}

/// Capture Text's paragraphs: lines the screen wrapped mid-sentence are joined, and everything else keeps its breaks
/// (owner, 2026-11-17: paragraphs by default, with a setting to keep the screen's lines).
nonisolated enum CaptureTextParagraphs {
    static func reflowed(_ blocks: [CapturedTextBlock]) -> [CapturedTextBlock] {
        blocks.map { block in
            if case let .paragraph(text) = block { return .paragraph(reflowed(text)) }
            return block
        }
    }

    /// Joins a line to the next when the sentence runs on: the line doesn't end a sentence, the next isn't a list item,
    /// and either the next starts in lowercase or the line is about as long as the longest (it wrapped rather than
    /// ended). Blank lines, list items, headings and code keep their breaks; a word split by a hyphen is joined whole.
    static func reflowed(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Code keeps every line.
        guard nonBlank.count > 1 else { return cleaned(text) }
        guard nonBlank.filter(looksLikeCode).count * 3 < nonBlank.count else { return text }
        let longest = nonBlank.map { $0.trimmingCharacters(in: .whitespaces).count }.max() ?? 0
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let last = out.last, !line.isEmpty, !last.isEmpty, joins(last, line, longest: longest) else {
                out.append(line)
                continue
            }
            out[out.count - 1] = last.hasSuffix("-") && line.first?.isLowercase == true && last.dropLast().last?.isLetter == true
                ? String(last.dropLast()) + line
                : last + " " + line
        }
        return cleaned(out.joined(separator: "\n"))
    }

    /// The first words of what was copied, for the message that says it's on the clipboard.
    static func firstWords(of text: String, limit: Int = 8) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let shown = words.prefix(limit).joined(separator: " ")
        return words.count > limit ? shown + "…" : shown
    }

    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func joins(_ line: String, _ next: String, longest: Int) -> Bool {
        guard !isListItem(next), !isListItem(line) || !next.isEmpty else { return false }
        // Any script's sentence end (Astra R5-5: Arabic "؟" ran on into the next sentence), or a clause's.
        if let end = line.last, end.unicodeScalars.last?.properties.isSentenceTerminal == true || ":;؛\"”»)".contains(end) {
            return false
        }
        if next.first?.isLowercase == true { return true }
        // Long enough to have reached the edge, so it wrapped; a short line without an ending is a heading.
        return Double(line.count) >= Double(longest) * 0.7 && !isListItem(line)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^([•◦▪‣\-–—*·]|\d{1,3}[.)]|[a-zA-Z][.)])\s"#, options: .regularExpression) != nil
    }

    private static func looksLikeCode(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.hasSuffix("{") || line.hasSuffix("}") || line.hasSuffix(";") || line.hasPrefix("//")
            || ["func ", "let ", "var ", "const ", "def ", "return ", "import ", "#include"].contains { line.hasPrefix($0) }
    }

    /// Footnote marks, only on lines with no code and only where the text says they are ones (Astra R5-3 and R5A-2,
    /// 2026-11-17: "array[2]" and "let a = [[1],[2]]" lost indices): a misread "!2]" or "|2]" (Fable saw "!2]" in
    /// Wikipedia text), or "[2]" right after a sentence's punctuation or a space after it, as Vision reads
    /// "display.[2]" ("display. [2]"), each followed by a space, punctuation or the line's end. A "[2]" stuck to a
    /// word ("Tokyo[3] is") goes only when the same text has one of those marks too; otherwise it may be an index
    /// ("x[2] and y[3]") and stays.
    private static func cleaned(_ text: String) -> String {
        let marked = #"(?:(?<=[\p{L}.,;:)”"])[!|]\d{1,3}\]|(?<=[.,;:”"])\[\d{1,3}\]|(?<=[.,;:)”"]) [\[!|]\d{1,3}\])(?=\s|$|[.,;:])"#
        let lines = text.components(separatedBy: "\n")
        let isProse = { (line: String) in !looksLikeCode(line) && !line.contains("=") }
        let hasMarks = lines.contains { isProse($0) && $0.range(of: marked, options: .regularExpression) != nil }
        return lines.map { line in
            guard isProse(line) else { return line }
            var line = line.replacingOccurrences(of: marked, with: "", options: .regularExpression)
            if hasMarks {
                line = line.replacingOccurrences(of: #"(?<=\p{L})\[\d{1,3}\](?= \p{L})"#, with: "", options: .regularExpression)
            }
            return line
        }.joined(separator: "\n")
    }
}
