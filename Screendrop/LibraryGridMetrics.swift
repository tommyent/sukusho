import CoreGraphics

/// How the Library's grids lay out cards, Finder-style: cards keep one width and a wider window fits more
/// columns. The gaps share the leftover width up to 32 pt; past that it goes to the side margins, so the block
/// sits centred instead of spreading wide gaps (design pass choice 3) or leaving a strip on one side.
/// Shared by the captures and Cloud grid (`LibraryCollectionLayout`) and the clipboard grid, whose arrow keys
/// step by `columns`.
nonisolated struct LibraryGridMetrics: Equatable, Sendable {
    let cellWidth: CGFloat
    let columns: Int
    /// Between neighbouring cards in a row.
    let spacing: CGFloat
    let leftInset: CGFloat
    let rightInset: CGFloat

    static let minimumGap: CGFloat = 16
    static let maximumGap: CGFloat = 32

    init(width: CGFloat, cardWidth: CGFloat) {
        let width = max(200, width)
        let gap = Self.minimumGap
        cellWidth = max(1, min(cardWidth, width - 2 * gap))
        let fitting = max(1, floor((width - gap) / (cellWidth + gap)))
        spacing = min(Self.maximumGap, max(gap, floor((width - fitting * cellWidth) / (fitting + 1))))
        let rowWidth = fitting * cellWidth + (fitting - 1) * spacing
        columns = Int(fitting)
        leftInset = max(gap, floor((width - rowWidth) / 2))
        // Rounding goes to the right margin, less half a point of slack so the last column can't wrap.
        rightInset = max(gap, width - rowWidth - leftInset - 0.5)
    }
}
