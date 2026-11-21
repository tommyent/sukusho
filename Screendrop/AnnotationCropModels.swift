//
//  AnnotationCropModels.swift
//  Screendrop
//
//  Geometry and presets for the crop tool. The engine works in the source's
//  pixel space (top-left origin, y-down), so aspect ratios are exact and a
//  selection can sit on whole pixels. Every drag is computed from the rect at
//  its start plus the pointer's total travel: a drag never accumulates
//  rounding or clamping drift, and grabbing a handle off-centre never jumps.
//

import CoreGraphics

/// Aspect ratio presets offered while cropping.
enum CropAspectRatio: String, CaseIterable, Identifiable {
    case freeform
    case original
    case square
    case sixteenNine
    case nineSixteen
    case fourThree
    case threeTwo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .square: "1:1"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        }
    }

    /// The pixel width / height ratio for this preset, or `nil` for freeform.
    func pixelRatio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .freeform:
            return nil
        case .original:
            return imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square:
            return 1
        case .sixteenNine:
            return 16.0 / 9.0
        case .nineSixteen:
            return 9.0 / 16.0
        case .fourThree:
            return 4.0 / 3.0
        case .threeTwo:
            return 3.0 / 2.0
        }
    }

    /// The desired normalized `width / height` ratio of the crop rect that
    /// produces `pixelRatio` once scaled back into pixels. Still used by
    /// Studio's video crop until it moves onto `CropGeometry`.
    func normalizedRatio(imageSize: CGSize) -> CGFloat? {
        guard let pixelRatio = pixelRatio(imageSize: imageSize),
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }
        return pixelRatio * imageSize.height / imageSize.width
    }

    var locksAspect: Bool {
        self != .freeform
    }
}

/// The eight drag handles around a crop rectangle.
nonisolated enum CropHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var isCorner: Bool {
        xDirection != 0 && yDirection != 0
    }

    /// -1 for a handle on the left edge, 1 on the right, 0 for neither.
    var xDirection: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    /// -1 for a handle on the top edge, 1 on the bottom, 0 for neither.
    var yDirection: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }

    /// Unit position (0...1) of the handle within the crop rect.
    var unitPoint: CGPoint {
        CGPoint(x: (xDirection + 1) / 2, y: (yDirection + 1) / 2)
    }

    /// The corner a drag from an anchor heads into.
    static func corner(xDirection: CGFloat, yDirection: CGFloat) -> CropHandle {
        switch (xDirection < 0, yDirection < 0) {
        case (true, true): .topLeft
        case (false, true): .topRight
        case (true, false): .bottomLeft
        case (false, false): .bottomRight
        }
    }

    fileprivate var isLeft: Bool { xDirection < 0 }
    fileprivate var isTop: Bool { yDirection < 0 }
}

/// Pure crop geometry. Rects, bounds and minimum sizes share one space; the
/// result always lies inside `bounds` and is never smaller than the minimum
/// (unless the bounds themselves are).
nonisolated enum CropGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Resizes `start` as if `handle` were dragged by `translation`.
    ///
    /// - Corners move two edges; with an `aspect` (width / height) the size
    ///   follows the pointer's projection onto the rect's diagonal.
    /// - Edges move one edge; with an `aspect` the other dimension follows,
    ///   centred on the rect and shifted only as far as the bounds require.
    /// - `fromCenter` mirrors the drag on the opposite side, keeping the
    ///   centre fixed.
    static func resize(
        _ start: CGRect,
        handle: CropHandle,
        by translation: CGSize,
        in bounds: CGRect,
        aspect: CGFloat?,
        minimumSize: CGSize,
        fromCenter: Bool = false
    ) -> CGRect {
        let start = start.standardized
        var x = Axis(
            start: start.minX, end: start.maxX, direction: handle.xDirection,
            delta: translation.width, lower: bounds.minX, upper: bounds.maxX, fromCenter: fromCenter
        )
        var y = Axis(
            start: start.minY, end: start.maxY, direction: handle.yDirection,
            delta: translation.height, lower: bounds.minY, upper: bounds.maxY, fromCenter: fromCenter
        )

        if let aspect, aspect > 0 {
            let proposedHeight: CGFloat
            switch (handle.xDirection != 0, handle.yDirection != 0) {
            case (true, true):
                // Projection of the proposed size onto the (aspect, 1) diagonal.
                proposedHeight = (x.size * aspect + y.size) / (aspect * aspect + 1)
            case (true, false):
                proposedHeight = x.size / aspect
            default:
                proposedHeight = y.size
            }
            let height = clamp(
                proposedHeight,
                min: max(minimumSize.height, minimumSize.width / aspect),
                max: min(y.room, x.room / aspect)
            )
            x.size = height * aspect
            y.size = height
        } else {
            x.size = clamp(x.size, min: minimumSize.width, max: x.room)
            y.size = clamp(y.size, min: minimumSize.height, max: y.room)
        }

        return CGRect(x: x.placedMinimum, y: y.placedMinimum, width: x.size, height: y.size)
    }

    /// A new selection dragged out from `anchor` to `point`, as if the anchor
    /// were a zero-size rect whose corner is being pulled.
    static func span(
        from anchor: CGPoint,
        to point: CGPoint,
        in bounds: CGRect,
        aspect: CGFloat?,
        minimumSize: CGSize,
        fromCenter: Bool = false
    ) -> CGRect {
        let anchor = CGPoint(
            x: clamp(anchor.x, min: bounds.minX, max: bounds.maxX),
            y: clamp(anchor.y, min: bounds.minY, max: bounds.maxY)
        )
        let translation = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
        return resize(
            CGRect(origin: anchor, size: .zero),
            handle: .corner(
                xDirection: translation.width < 0 ? -1 : 1,
                yDirection: translation.height < 0 ? -1 : 1
            ),
            by: translation,
            in: bounds,
            aspect: aspect,
            minimumSize: minimumSize,
            fromCenter: fromCenter
        )
    }

    /// Translates `start`, stopping flush against the bounds.
    static func move(_ start: CGRect, by translation: CGSize, in bounds: CGRect) -> CGRect {
        let start = start.standardized
        return CGRect(
            x: clamp(start.minX + translation.width, min: bounds.minX, max: bounds.maxX - start.width),
            y: clamp(start.minY + translation.height, min: bounds.minY, max: bounds.maxY - start.height),
            width: start.width,
            height: start.height
        )
    }

    /// The largest rect of `aspect` centred in `bounds`.
    static func largest(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0 else { return bounds }
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// `rect` reshaped to `aspect` about its centre, keeping its area where
    /// the bounds allow, so switching ratios keeps the selection's scale.
    static func reshaped(_ rect: CGRect, aspect: CGFloat, in bounds: CGRect) -> CGRect {
        let rect = rect.standardized
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return largest(aspect: aspect, in: bounds) }
        var width = (rect.width * rect.height * aspect).squareRoot()
        var height = width / aspect
        let fit = min(1, bounds.width / width, bounds.height / height)
        width *= fit
        height *= fit
        return move(
            CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height),
            by: .zero,
            in: bounds
        )
    }

    /// `rect` with every edge on a whole unit (a pixel, in pixel space),
    /// still inside `bounds`.
    static func snapped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        func snap(_ lower: CGFloat, _ upper: CGFloat, within low: CGFloat, _ high: CGFloat) -> (CGFloat, CGFloat) {
            let low = low.rounded(.up)
            let high = max(low + 1, high.rounded(.down))
            let start = clamp(lower.rounded(), min: low, max: high - 1)
            return (start, clamp(upper.rounded(), min: start + 1, max: high))
        }
        let (minX, maxX) = snap(rect.minX, rect.maxX, within: bounds.minX, bounds.maxX)
        let (minY, maxY) = snap(rect.minY, rect.maxY, within: bounds.minY, bounds.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Minimum selection size inside `bounds`: `preferred` capped at half each
    /// image dimension (at least 1 px, or the bound if smaller), and never
    /// larger than `start` when resizing a box that already starts smaller.
    static func minimumSize(
        preferred: CGFloat,
        in bounds: CGRect,
        startingFrom start: CGRect? = nil
    ) -> CGSize {
        func axis(_ preferred: CGFloat, bound: CGFloat, start: CGFloat?) -> CGFloat {
            guard bound > 0 else { return 0 }
            let cap = Swift.max(Swift.min(1, bound), (bound / 2).rounded(.down))
            var floor = Swift.min(preferred, cap)
            if let start, start > 0 {
                floor = Swift.min(floor, start)
            }
            return floor
        }
        return CGSize(
            width: axis(preferred, bound: bounds.width, start: start?.width),
            height: axis(preferred, bound: bounds.height, start: start?.height)
        )
    }

    // MARK: Private

    /// One dimension of a resize: what stays fixed, how big the drag asks the
    /// rect to be, and how much room that leaves before the bounds.
    private struct Axis {
        /// The fixed edge, or the centre for centred and undragged axes.
        let anchor: CGFloat
        var size: CGFloat
        let room: CGFloat
        let direction: CGFloat
        let isCentered: Bool
        let lower: CGFloat
        let upper: CGFloat

        init(
            start: CGFloat, end: CGFloat, direction: CGFloat, delta: CGFloat,
            lower: CGFloat, upper: CGFloat, fromCenter: Bool
        ) {
            self.direction = direction
            self.lower = lower
            self.upper = upper
            let center = (start + end) / 2
            if direction == 0 {
                anchor = center
                size = end - start
                room = upper - lower
                isCentered = true
            } else if fromCenter {
                anchor = center
                size = end - start + 2 * direction * delta
                room = 2 * max(0, min(center - lower, upper - center))
                isCentered = true
            } else if direction > 0 {
                anchor = start
                size = end - start + delta
                room = upper - start
                isCentered = false
            } else {
                anchor = end
                size = end - start - delta
                room = end - lower
                isCentered = false
            }
        }

        var placedMinimum: CGFloat {
            if isCentered {
                return CropGeometry.clamp(anchor - size / 2, min: lower, max: upper - size)
            }
            return direction > 0 ? anchor : anchor - size
        }
    }

    /// Clamps into `min...max`; when the range is empty, `max` wins, so a
    /// result never leaves its bounds to honour a minimum size.
    fileprivate static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}

/// What a press in crop mode grabs.
nonisolated enum CropDragTarget: Equatable {
    case handle(CropHandle)
    /// Inside the selection: moves it.
    case move
    /// Outside the selection: drags out a new one.
    case newSelection
}

/// A crop drag in progress, in the image's pixel space except where noted.
nonisolated struct CropDrag {
    let target: CropDragTarget
    let startRect: CGRect
    let startPoint: CGPoint
    /// The pointer where the drag began and where it is now, in viewport
    /// points. Auto-scrolling re-applies the drag at the latest one.
    let startPointer: CGPoint
    var pointer: CGPoint
    /// A new selection begins only once the pointer travels, so a click
    /// outside the box leaves it alone.
    var hasTravelled = false
}

extension CropDrag {
    /// Whether pointer travel from `startPointer` to `pointer` is enough to
    /// begin mutating the selection. A handle or move activates on any motion
    /// (never on mouse-down); a new selection waits for 3 pt so a stray click
    /// outside the box leaves it alone.
    func shouldActivate(at pointer: CGPoint) -> Bool {
        let distance = hypot(pointer.x - startPointer.x, pointer.y - startPointer.y)
        return target == .newSelection ? distance >= 3 : distance > 0
    }

    /// The selection this drag makes with the pointer at `point` (pixels).
    /// `lockedAspect` is a preset's ratio; without one, `holdsAspect` (Shift)
    /// keeps the ratio the drag started with, or a square for a new selection.
    func rect(
        at point: CGPoint,
        in bounds: CGRect,
        lockedAspect: CGFloat?,
        minimumSize: CGSize,
        holdsAspect: Bool,
        fromCenter: Bool
    ) -> CGRect {
        let aspect = lockedAspect ?? {
            guard holdsAspect else { return nil }
            if target == .newSelection { return 1 }
            return startRect.height > 0 ? startRect.width / startRect.height : nil
        }()
        let translation = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)

        let next: CGRect
        switch target {
        case .handle(let handle):
            next = CropGeometry.resize(
                startRect, handle: handle, by: translation, in: bounds,
                aspect: aspect, minimumSize: minimumSize, fromCenter: fromCenter
            )
        case .move:
            next = CropGeometry.move(startRect, by: translation, in: bounds)
        case .newSelection:
            next = CropGeometry.span(
                from: startPoint, to: point, in: bounds,
                aspect: aspect, minimumSize: minimumSize, fromCenter: fromCenter
            )
        }
        return CropGeometry.snapped(next, in: bounds)
    }
}

/// What a press grabs on a crop box drawn on screen, in view points.
nonisolated enum CropHitTest {
    /// How far a corner's hit zone reaches outside and inside the selection.
    /// It reaches further in than out: the outside can be cut off by the
    /// viewport edge, the inside never is.
    static let cornerReachOutside: CGFloat = 10
    static let cornerReachInside: CGFloat = 22
    /// The same for an edge's hit zone, which runs the edge's whole length.
    static let edgeReachOutside: CGFloat = 8
    static let edgeReachInside: CGFloat = 10

    /// A corner, then an edge, then the inside of the box; anywhere else
    /// starts a new selection.
    static func target(at point: CGPoint, box: CGRect) -> CropDragTarget {
        for handle in CropHandle.allCases where handle.isCorner {
            if zone(for: handle, of: box, outside: cornerReachOutside, inside: cornerReachInside).contains(point) {
                return .handle(handle)
            }
        }
        for handle in CropHandle.allCases where !handle.isCorner {
            if zone(for: handle, of: box, outside: edgeReachOutside, inside: edgeReachInside).contains(point) {
                return .handle(handle)
            }
        }
        return box.contains(point) ? .move : .newSelection
    }

    /// A handle's hit zone around `box`. Along an axis the handle sits on, it
    /// straddles that edge; along the other, it spans the box. The inside
    /// reach shrinks on a small box so its middle stays free for moving.
    private static func zone(for handle: CropHandle, of box: CGRect, outside: CGFloat, inside: CGFloat) -> CGRect {
        func span(_ direction: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> ClosedRange<CGFloat> {
            let inward = min(inside, (upper - lower) / 3)
            if direction < 0 { return (lower - outside)...(lower + inward) }
            if direction > 0 { return (upper - inward)...(upper + outside) }
            return lower...upper
        }
        let x = span(handle.xDirection, box.minX, box.maxX)
        let y = span(handle.yDirection, box.minY, box.maxY)
        return CGRect(x: x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }
}

/// Normalized crop editor retained for Studio's video crop and video redaction
/// region picking until Studio moves onto `CropGeometry`.
enum CropRectEditor {
    static let unit = CropGeometry.unit

    static func resize(
        _ rect: CGRect,
        handle: CropHandle,
        to point: CGPoint,
        aspect: CGFloat?,
        minWidth: CGFloat,
        minHeight: CGFloat,
        fromCenter: Bool = false
    ) -> CGRect {
        let p = CGPoint(x: clamp(point.x), y: clamp(point.y))

        if fromCenter {
            return resizeFromCenter(
                rect,
                handle: handle,
                to: p,
                aspect: aspect,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if handle.isCorner {
            return resizeCorner(
                rect,
                isLeft: handle.isLeft,
                isTop: handle.isTop,
                to: p,
                aspect: aspect,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        switch handle {
        case .left:
            minX = min(p.x, maxX - minWidth)
        case .right:
            maxX = max(p.x, minX + minWidth)
        case .top:
            minY = min(p.y, maxY - minHeight)
        case .bottom:
            maxY = max(p.y, minY + minHeight)
        default:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func move(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let x = clamp(rect.minX + delta.width, max: 1 - rect.width)
        let y = clamp(rect.minY + delta.height, max: 1 - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    static func applyAspect(to rect: CGRect, aspect: CGFloat) -> CGRect {
        guard aspect > 0 else { return rect }

        var width = rect.width
        var height = rect.height
        if width / height > aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }

        width = min(width, 1)
        height = min(height, 1)
        if width / height > aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }

        var result = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )

        if result.minX < 0 { result.origin.x = 0 }
        if result.minY < 0 { result.origin.y = 0 }
        if result.maxX > 1 { result.origin.x = 1 - result.width }
        if result.maxY > 1 { result.origin.y = 1 - result.height }
        return result
    }

    // MARK: Private

    private static func resizeFromCenter(
        _ rect: CGRect,
        handle: CropHandle,
        to point: CGPoint,
        aspect: CGFloat?,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)

        var halfWidth = rect.width / 2
        var halfHeight = rect.height / 2

        if handle.isCorner {
            halfWidth = abs(point.x - center.x)
            halfHeight = abs(point.y - center.y)
            if let aspect, aspect > 0 {
                if halfWidth / halfHeight > aspect {
                    halfWidth = halfHeight * aspect
                } else {
                    halfHeight = halfWidth / aspect
                }
            }
        } else {
            switch handle {
            case .left, .right:
                halfWidth = abs(point.x - center.x)
            case .top, .bottom:
                halfHeight = abs(point.y - center.y)
            default:
                break
            }
        }

        halfWidth = max(halfWidth, minWidth / 2)
        halfHeight = max(halfHeight, minHeight / 2)

        let maxHalfWidth = min(center.x, 1 - center.x)
        let maxHalfHeight = min(center.y, 1 - center.y)
        halfWidth = min(halfWidth, maxHalfWidth)
        halfHeight = min(halfHeight, maxHalfHeight)

        if let aspect, aspect > 0, handle.isCorner {
            if halfWidth / halfHeight > aspect {
                halfWidth = halfHeight * aspect
            } else {
                halfHeight = halfWidth / aspect
            }
        }

        return CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    private static func resizeCorner(
        _ rect: CGRect,
        isLeft: Bool,
        isTop: Bool,
        to point: CGPoint,
        aspect: CGFloat?,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let anchorX = isLeft ? rect.maxX : rect.minX
        let anchorY = isTop ? rect.maxY : rect.minY

        var cornerX = isLeft ? min(point.x, anchorX - minWidth) : max(point.x, anchorX + minWidth)
        var cornerY = isTop ? min(point.y, anchorY - minHeight) : max(point.y, anchorY + minHeight)

        if let aspect, aspect > 0 {
            var width = abs(cornerX - anchorX)
            var height = abs(cornerY - anchorY)

            if width / height > aspect {
                width = height * aspect
            } else {
                height = width / aspect
            }

            let maxWidth = isLeft ? anchorX : (1 - anchorX)
            let maxHeight = isTop ? anchorY : (1 - anchorY)
            if width > maxWidth {
                width = maxWidth
                height = width / aspect
            }
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }

            cornerX = isLeft ? anchorX - width : anchorX + width
            cornerY = isTop ? anchorY - height : anchorY + height
        }

        return CGRect(
            x: min(cornerX, anchorX),
            y: min(cornerY, anchorY),
            width: abs(cornerX - anchorX),
            height: abs(cornerY - anchorY)
        )
    }

    private static func clamp(_ value: CGFloat, max upper: CGFloat = 1) -> CGFloat {
        min(max(value, 0), upper)
    }
}
