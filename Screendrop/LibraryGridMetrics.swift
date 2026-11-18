import AppKit

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

/// Index paths and flat positions for the same ordered snapshot of cards.
nonisolated struct LibraryDisplayOrder {
    let paths: [IndexPath]
    private let starts: [Int]

    init(sectionCounts: [Int]) {
        var paths: [IndexPath] = []
        var starts: [Int] = []
        for (section, count) in sectionCounts.enumerated() {
            starts.append(paths.count)
            paths += (0..<count).map { IndexPath(item: $0, section: section) }
        }
        self.starts = starts
        self.paths = paths
    }

    static func selected<Entry: Identifiable>(_ entries: [Entry], ids: Set<Entry.ID>) -> [Entry] {
        entries.filter { ids.contains($0.id) }
    }

    func index(at path: IndexPath) -> Int? {
        guard path.count == 2, starts.indices.contains(path.section) else { return nil }
        let index = starts[path.section] + path.item
        return paths.indices.contains(index) && paths[index] == path ? index : nil
    }
}

/// The pills read left to right within each corner of the picture.
nonisolated struct LibraryCardMarks {
    enum CloudState { case unshared, shared, received }
    enum Pill: Equatable {
        case encrypted, password, expiry(Date), comments(Int), likes(Int), tall, versions(Int)
        case duration(String), kind(String), gallery(Int)
    }
    let cloud: CloudState?
    var settings: [Pill] = []
    var social: [Pill] = []
    var content: [Pill] = []

    init(cloud: CloudState?, upload: CloudUpload?, tall: Bool, versions: Int = 1, content last: Pill? = nil) {
        self.cloud = cloud
        if upload?.encrypted == true { settings.append(.encrypted) }
        if upload?.hasPassword == true { settings.append(.password) }
        if let expires = upload?.expiresAt { settings.append(.expiry(expires)) }
        if let n = upload?.commentCount, n > 0 { social.append(.comments(n)) }
        if let n = upload?.likeCount, n > 0 { social.append(.likes(n)) }
        if tall { content.append(.tall) }
        if versions > 1 { content.append(.versions(versions)) }
        if let last { content.append(last) }
    }

    init(captureLink: String?, upload: CloudUpload?, tall: Bool, recordingLength: String?) {
        self.init(cloud: captureLink == nil ? .unshared : .shared, upload: upload,
                  tall: tall, content: recordingLength.map(Pill.duration))
    }

    init(upload: CloudUpload, tall: Bool, localLength: String?) {
        let last: Pill?
        if let ids = upload.galleryItemIDs { last = .gallery(ids.count) }
        else if upload.isVideo { last = .duration(upload.duration.map(Self.duration) ?? localLength ?? "—") }
        else { last = nil }
        self.init(cloud: upload.isReceived ? .received : .shared, upload: upload, tall: tall, content: last)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let whole = Int(min(seconds.rounded(), Double(Int.max / 2)))
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    init(clip: ClipboardEntry, upload: CloudUpload?) {
        self.init(cloud: clip.cloudLinks.isEmpty ? nil : .shared, upload: upload,
                  tall: clip.kind == .image && TallCapture.isTall(width: clip.pixelWidth, height: clip.pixelHeight),
                  versions: clip.earlierVersions.count + 1, content: ClipboardList.kindWord(of: clip).map(Pill.kind))
    }
}

nonisolated enum TallCapture {
    static func isTall(width: Int, height: Int) -> Bool {
        width > 0 && Double(height) > Double(width) * 2.5
    }
}

nonisolated struct LibraryCardDensity {
    let width: CGFloat
    var showsSocial: Bool { width >= 200 }
    var showsPillText: Bool { width >= 180 }
    var separatesLocks: Bool { width >= 165 }
    var showsFullDate: Bool { width >= 155 }
}
