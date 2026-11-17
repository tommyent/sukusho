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
