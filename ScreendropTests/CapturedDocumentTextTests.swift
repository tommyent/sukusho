import AppKit
import CoreText
import Testing

@Suite
struct CapturedDocumentTextTests {
    @Test func blocksKeepTheirShapeInBothClipboardForms() {
        let blocks: [CapturedTextBlock] = [
            .paragraph("Prices & <terms>"),
            .table([["Plan", "Price"], ["Pro", "$8\tmonthly"]]),
            .list([(marker: "•", text: "First"), (marker: "•", text: "Second")]),
            .list([(marker: "1.", text: "One")]),
        ]
        #expect(CapturedDocumentText.plainText(blocks) == "Prices & <terms>\nPlan\tPrice\nPro\t$8 monthly\n• First\n• Second\n1. One")
        #expect(CapturedDocumentText.html(blocks) == "<meta charset=\"utf-8\"><p>Prices &amp; &lt;terms&gt;</p>"
            + "<table><tr><td>Plan</td><td>Price</td></tr><tr><td>Pro</td><td>$8\tmonthly</td></tr></table>"
            + "<ul><li>First</li><li>Second</li></ul><ol><li>One</li></ol>")
    }

    @Test func blocksReadTopToBottomAndATablesOwnParagraphsAreLeftOut() {
        let table = CapturedDocumentText.Placed(block: .table([["A", "B"]]), box: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2))
        let inside = CapturedDocumentText.Placed(block: .paragraph("A"), box: CGRect(x: 0.15, y: 0.45, width: 0.1, height: 0.05))
        let above = CapturedDocumentText.Placed(block: .paragraph("Heading"), box: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1))
        let below = CapturedDocumentText.Placed(block: .paragraph("Footnote"), box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1))
        #expect(CapturedDocumentText.ordered([below, inside, table, above])
            == [.paragraph("Heading"), .table([["A", "B"]]), .paragraph("Footnote")])
    }

    /// Vision itself, on a table drawn here. Cells hold two characters or more: a lone digit
    /// came back empty (seen 2026-11-10, macOS 27.3). Slow the first time a build runs, and skipped where
    /// the recognizer finds no table, since what it reads is Apple's to change.
    @Test func aDrawnTableComesBackAsRows() async throws {
        let width = 900, height = 420
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(.black); context.setLineWidth(2)
        let rows = [["Plan", "Seats", "Price"], ["Starter", "30", "$12"], ["Team", "10", "$45"], ["Business", "50", "$180"]]
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let rect = CGRect(x: 60 + c * 260, y: height - 90 - r * 80, width: 260, height: 80)
                context.stroke(rect)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell, attributes: [
                    .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]))
                context.textPosition = CGPoint(x: rect.minX + 20, y: rect.minY + 28)
                CTLineDraw(line, context)
            }
        }
        let image = try #require(context.makeImage())
        guard let blocks = await CapturedDocumentText.structuredBlocks(in: image),
              case let .table(found)? = blocks.first(where: { if case .table = $0 { true } else { false } }) else {
            print("SKIP: Vision found no table in the drawn fixture")
            return
        }
        #expect(found == rows)
        #expect(CapturedDocumentText.plainText(blocks).contains("Team\t10\t$45"))
    }
}
