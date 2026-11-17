import CoreGraphics

/// How the Library's grids lay out cards, Finder-style: cards keep one width and a wider window fits more
/// columns. The gaps grow with the cards, from a fifth to half a card's width, so cards breathe at every slider
/// size the way Finder's icon view does (owner, 2026-11-16: "how much better Finder spaces things out"); past
/// that the leftover goes to even side margins, never a strip on one side.
/// Shared by the captures and Cloud grid (`LibraryCollectionLayout`) and the clipboard grid, whose arrow keys
/// step by `columns`.
nonisolated struct LibraryGridMetrics: Equatable, Sendable {
    let cellWidth: CGFloat
    let columns: Int
    /// Between neighbouring cards in a row.
    let spacing: CGFloat
    /// Between rows.
    let lineSpacing: CGFloat
    let leftInset: CGFloat
    let rightInset: CGFloat

    /// The narrowest margin at either side, and above and below the grid.
    static let edgeMargin: CGFloat = 24
    /// The picture's inset inside its card, the same at the sides and the top, so it sits on the card as a chip
    /// (owner's pick, 2026-11-17). The caption lines up with it.
    static let pictureInset: CGFloat = 6
    /// The caption below the picture: a name and a small detail line, with their padding.
    static let captionHeight: CGFloat = 50

    static func minimumGap(for cellWidth: CGFloat) -> CGFloat { max(20, (cellWidth * 0.2).rounded()) }
    static func maximumGap(for cellWidth: CGFloat) -> CGFloat { max(minimumGap(for: cellWidth), (cellWidth * 0.5).rounded()) }

    init(width: CGFloat, cardWidth: CGFloat) {
        let width = max(200, width)
        let edge = Self.edgeMargin
        cellWidth = max(1, min(cardWidth, width - 2 * edge))
        let gap = Self.minimumGap(for: cellWidth)
        let fitting = max(1, floor((width - 2 * edge + gap) / (cellWidth + gap)))
        spacing = min(Self.maximumGap(for: cellWidth), max(gap, floor((width - fitting * cellWidth) / (fitting + 1))))
        // The card's own gap, not the row's: with one column, `spacing` is mostly margin, and rows 110 pt apart at
        // the largest size read as unrelated (VM, 2026-11-16).
        lineSpacing = gap
        let rowWidth = fitting * cellWidth + (fitting - 1) * spacing
        columns = Int(fitting)
        leftInset = max(edge, floor((width - rowWidth) / 2))
        // Rounding goes to the right margin, less half a point of slack so the last column can't wrap.
        rightInset = max(edge, width - rowWidth - leftInset - 0.5)
    }

    /// A whole card: as tall as before the picture was inset (a 16:10 picture over a 62 pt caption), so the chip
    /// takes the room above the caption.
    var cardHeight: CGFloat { floor(cellWidth * 0.625) + 62 }
    /// The picture's height inside a card: what the inset and the caption leave.
    var pictureHeight: CGFloat { cardHeight - Self.pictureInset - Self.captionHeight }
}
