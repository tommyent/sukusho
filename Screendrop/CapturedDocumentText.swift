//
//  CapturedDocumentText.swift
//  Screendrop
//

import CoreGraphics
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
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { placed.append(Placed(block: .paragraph(text), box: paragraph.boundingRegion.boundingBox.cgRect)) }
        }
        let blocks = ordered(placed)
        return blocks.isEmpty ? nil : blocks
    }
}
