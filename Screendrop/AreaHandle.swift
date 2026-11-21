import CoreGraphics

/// The eight handles of an area being adjusted: four corners and four edges.
nonisolated enum AreaHandle: CaseIterable, Sendable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    static let size: CGFloat = 9

    /// Where this handle sits on `area`, in the same (unflipped) coordinates.
    func rect(in area: CGRect) -> CGRect {
        let x: CGFloat = switch self {
        case .bottomLeft, .left, .topLeft: area.minX
        case .bottom, .top: area.midX
        case .bottomRight, .right, .topRight: area.maxX
        }
        let y: CGFloat = switch self {
        case .bottomLeft, .bottom, .bottomRight: area.minY
        case .left, .right: area.midY
        case .topLeft, .top, .topRight: area.maxY
        }
        return CGRect(x: x - Self.size / 2, y: y - Self.size / 2, width: Self.size, height: Self.size)
    }

    /// `area` moved (no handle) or resized by its handle by `delta`, kept inside `bounds` and at least `minimum` wide
    /// and high. A resize keeps the opposite edges where they are.
    static func adjust(_ area: CGRect, handle: AreaHandle?, by delta: CGSize, within bounds: CGRect, minimum: CGFloat) -> CGRect {
        guard let handle else {
            let x = min(max(area.minX + delta.width, bounds.minX), bounds.maxX - area.width)
            let y = min(max(area.minY + delta.height, bounds.minY), bounds.maxY - area.height)
            return CGRect(x: x, y: y, width: area.width, height: area.height)
        }
        var minX = area.minX, maxX = area.maxX, minY = area.minY, maxY = area.maxY
        switch handle {
        case .bottomLeft, .left, .topLeft: minX = min(max(minX + delta.width, bounds.minX), maxX - minimum)
        case .bottomRight, .right, .topRight: maxX = max(min(maxX + delta.width, bounds.maxX), minX + minimum)
        case .bottom, .top: break
        }
        switch handle {
        case .bottomLeft, .bottom, .bottomRight: minY = min(max(minY + delta.height, bounds.minY), maxY - minimum)
        case .topLeft, .top, .topRight: maxY = max(min(maxY + delta.height, bounds.maxY), minY + minimum)
        case .left, .right: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// When the area picker gives up as cancelled because macOS's own Screenshot UI is running (sd-7l2f). One ⇧⌘5 opens both
/// Capture Text's picker and macOS's Screenshot toolbar; the toolbar takes Escape without Sukusho losing the keyboard or
/// another app activating (seen in the VM), and a stray click deliberately leaves the picker open, so it dimmed the
/// screen until a second Escape. macOS starts that UI afresh, as com.apple.screencaptureui, for each ⇧⌘5, and it quits
/// when done.
nonisolated enum AreaPickerSystemScreenshot {
    static let bundleID = "com.apple.screencaptureui"

    /// `running`: the apps the running-applications list reports as newly started.
    static func endsPicker(running bundleIDs: [String?]) -> Bool {
        bundleIDs.contains(bundleID)
    }
}

/// Which selection a queued "Screenshot UI started" belongs to (Sol, SP-1): each selection gets its own generation, and
/// closing one moves on, so a callback queued for a picker that has since closed can't cancel one opened after it.
nonisolated struct AreaPickerSession {
    private(set) var generation = 0
    private(set) var isOpen = false

    /// A new selection; the callbacks scheduled for it carry the returned generation.
    mutating func open() -> Int {
        generation += 1
        isOpen = true
        return generation
    }

    /// The selection ended, however it ended: everything already queued for it is now stale.
    mutating func close() {
        generation += 1
        isOpen = false
    }

    /// Whether a callback scheduled for `generation`, reporting `running`, cancels the open selection.
    func cancels(_ generation: Int, running bundleIDs: [String?]) -> Bool {
        isOpen && generation == self.generation && AreaPickerSystemScreenshot.endsPicker(running: bundleIDs)
    }
}

/// The horizontal and vertical hairline guides through the pointer before a drag starts.
nonisolated struct AreaPickerGuides: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat

    /// Pixel-aligned coordinates for the guide lines on one display, or nil when the pointer isn't on this display
    /// or a drag, adjustment or Shift-snap box is active.
    static func position(
        pointer: CGPoint?,
        in bounds: CGRect,
        pixelScale: CGSize,
        isDragging: Bool,
        isAdjusting: Bool,
        hasSnap: Bool
    ) -> AreaPickerGuides? {
        guard !isDragging, !isAdjusting, !hasSnap, let pointer,
              pointer.x >= bounds.minX, pointer.x <= bounds.maxX,
              pointer.y >= bounds.minY, pointer.y <= bounds.maxY else { return nil }
        return AreaPickerGuides(
            x: align(pointer.x, in: bounds.minX...bounds.maxX, scale: pixelScale.width),
            y: align(pointer.y, in: bounds.minY...bounds.maxY, scale: pixelScale.height)
        )
    }

    /// Snaps a 1-point stroke center to whole pixels: half-pixel offset on odd scales (1x), whole-pixel on even (2x).
    private static func align(_ value: CGFloat, in range: ClosedRange<CGFloat>, scale: CGFloat) -> CGFloat {
        let s = max(1, scale)
        if Int(s.rounded()).isMultiple(of: 2) {
            return min(max((value * s).rounded() / s, range.lowerBound), range.upperBound)
        }
        let half = 0.5 / s
        guard range.upperBound - range.lowerBound >= 1 / s else { return (range.lowerBound + range.upperBound) / 2 }
        let snapped = ((value * s).rounded(.down) + 0.5) / s
        return min(max(snapped, range.lowerBound + half), range.upperBound - half)
    }
}
