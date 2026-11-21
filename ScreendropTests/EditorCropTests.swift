import CoreGraphics
import Testing

@MainActor
@Suite
struct EditorCropTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private static let minimumSize = CGSize(width: 24, height: 24)

    // MARK: - Inside-handle hit testing

    @Test static func insideCornerAndEdgeHits() {
        let box = CGRect(x: 100, y: 100, width: 400, height: 300)

        // Corners reach further inside (22 pt) than outside (10 pt).
        #expect(CropHitTest.target(at: CGPoint(x: 118, y: 118), box: box) == .handle(.topLeft))
        #expect(CropHitTest.target(at: CGPoint(x: 482, y: 118), box: box) == .handle(.topRight))
        #expect(CropHitTest.target(at: CGPoint(x: 118, y: 382), box: box) == .handle(.bottomLeft))
        #expect(CropHitTest.target(at: CGPoint(x: 482, y: 382), box: box) == .handle(.bottomRight))

        // Corner still grabs just outside (within 10 pt) and yields to newSelection beyond.
        #expect(CropHitTest.target(at: CGPoint(x: 92, y: 92), box: box) == .handle(.topLeft))
        #expect(CropHitTest.target(at: CGPoint(x: 85, y: 85), box: box) == .newSelection)

        // Edges grab inside the box (within 10 pt) along their middle stretch.
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 108), box: box) == .handle(.top))
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 392), box: box) == .handle(.bottom))
        #expect(CropHitTest.target(at: CGPoint(x: 108, y: 250), box: box) == .handle(.left))
        #expect(CropHitTest.target(at: CGPoint(x: 492, y: 250), box: box) == .handle(.right))

        // Deep interior moves; outside the hit zones starts a new selection.
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 250), box: box) == .move)
        #expect(CropHitTest.target(at: CGPoint(x: 20, y: 20), box: box) == .newSelection)
        #expect(CropHitTest.target(at: CGPoint(x: 520, y: 250), box: box) == .newSelection)
    }

    @Test static func smallBoxShrinksInwardReachSoCenterCanMove() {
        // On a 30x30 box, inward reach shrinks to 10 pt (width / 3), leaving the middle grabbable.
        let small = CGRect(x: 200, y: 200, width: 30, height: 30)
        #expect(CropHitTest.target(at: CGPoint(x: 215, y: 215), box: small) == .move)
        #expect(CropHitTest.target(at: CGPoint(x: 202, y: 202), box: small) == .handle(.topLeft))
    }

    // MARK: - Drag outside starts a new selection

    @Test static func dragOutsideStartsNewSelection() {
        let existing = CGRect(x: 100, y: 100, width: 200, height: 200)
        let anchor = CGPoint(x: 500, y: 400)
        let drag = CropDrag(
            target: .newSelection,
            startRect: existing,
            startPoint: anchor,
            startPointer: anchor,
            pointer: CGPoint(x: 720, y: 560),
            hasTravelled: true
        )

        let forward = drag.rect(
            at: CGPoint(x: 720, y: 560),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: false,
            fromCenter: false
        )
        #expect(forward == CGRect(x: 500, y: 400, width: 220, height: 160))

        // Dragging up-left from the same anchor spans the opposite quadrant.
        let backward = drag.rect(
            at: CGPoint(x: 350, y: 280),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: false,
            fromCenter: false
        )
        #expect(backward == CGRect(x: 350, y: 280, width: 150, height: 120))

        // Shift on a new selection locks to a 1:1 square.
        let square = drag.rect(
            at: CGPoint(x: 700, y: 500),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: true,
            fromCenter: false
        )
        #expect(square.width == square.height)
        #expect(square.minX == 500 && square.minY == 400)

        // Option on a new selection grows symmetrically about the anchor.
        let centered = drag.rect(
            at: CGPoint(x: 600, y: 450),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: false,
            fromCenter: true
        )
        #expect(centered == CGRect(x: 400, y: 350, width: 200, height: 100))
    }

    // MARK: - Shift keeps aspect ratio

    @Test static func shiftHoldsStartingAspectRatio() {
        // Start with a 2:1 selection.
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let cornerDrag = CropDrag(
            target: .handle(.bottomRight),
            startRect: start,
            startPoint: CGPoint(x: 300, y: 200),
            startPointer: .zero,
            pointer: .zero,
            hasTravelled: true
        )
        let cornerResized = cornerDrag.rect(
            at: CGPoint(x: 500, y: 220),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: true,
            fromCenter: false
        )
        #expect(cornerResized.minX == 100 && cornerResized.minY == 100)
        #expect(abs(cornerResized.width / cornerResized.height - 2.0) < 0.02)

        // Shift also keeps the ratio when pulling an edge, centering the cross axis.
        let edgeDrag = CropDrag(
            target: .handle(.right),
            startRect: start,
            startPoint: CGPoint(x: 300, y: 150),
            startPointer: .zero,
            pointer: .zero,
            hasTravelled: true
        )
        let edgeResized = edgeDrag.rect(
            at: CGPoint(x: 500, y: 150),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: true,
            fromCenter: false
        )
        #expect(edgeResized == CGRect(x: 100, y: 50, width: 400, height: 200))
    }

    // MARK: - Option resizes from centre

    @Test static func optionResizesSymmetricallyFromCenter() {
        let start = CGRect(x: 300, y: 200, width: 200, height: 100) // center (400, 250)
        let drag = CropDrag(
            target: .handle(.bottomRight),
            startRect: start,
            startPoint: CGPoint(x: 500, y: 300),
            startPointer: .zero,
            pointer: .zero,
            hasTravelled: true
        )

        let expanded = drag.rect(
            at: CGPoint(x: 550, y: 340),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: false,
            fromCenter: true
        )
        #expect(expanded == CGRect(x: 250, y: 160, width: 300, height: 180))
        #expect(expanded.midX == start.midX && expanded.midY == start.midY)

        // Pulling past the nearer edge clamps symmetrically without drifting the centre.
        let nearLeft = CGRect(x: 40, y: 200, width: 120, height: 100) // center (100, 250), room 200
        let leftDrag = CropDrag(
            target: .handle(.right),
            startRect: nearLeft,
            startPoint: CGPoint(x: 160, y: 250),
            startPointer: .zero,
            pointer: .zero,
            hasTravelled: true
        )
        let clamped = leftDrag.rect(
            at: CGPoint(x: 500, y: 250),
            in: bounds,
            lockedAspect: nil,
            minimumSize: minimumSize,
            holdsAspect: false,
            fromCenter: true
        )
        #expect(clamped == CGRect(x: 0, y: 200, width: 200, height: 100))
        #expect(clamped.midX == nearLeft.midX)
    }

    // MARK: - Nudge and bounds clamping

    @Test static func nudgeMovesByWholePixelsAndStopsAtBounds() {
        let start = CGRect(x: 20, y: 30, width: 200, height: 150)

        let right1 = CropGeometry.snapped(CropGeometry.move(start, by: CGSize(width: 1, height: 0), in: bounds), in: bounds)
        #expect(right1 == CGRect(x: 21, y: 30, width: 200, height: 150))

        let down10 = CropGeometry.snapped(CropGeometry.move(start, by: CGSize(width: 0, height: 10), in: bounds), in: bounds)
        #expect(down10 == CGRect(x: 20, y: 40, width: 200, height: 150))

        // Nudging past top-left stops flush at (0, 0) without shrinking.
        let clampedTopLeft = CropGeometry.snapped(CropGeometry.move(start, by: CGSize(width: -50, height: -50), in: bounds), in: bounds)
        #expect(clampedTopLeft == CGRect(x: 0, y: 0, width: 200, height: 150))

        // Nudging past bottom-right stops flush at (bounds.maxX - width, bounds.maxY - height).
        let clampedBottomRight = CropGeometry.snapped(CropGeometry.move(start, by: CGSize(width: 2000, height: 2000), in: bounds), in: bounds)
        #expect(clampedBottomRight == CGRect(x: 800, y: 650, width: 200, height: 150))
    }

    @Test static func reshapeAndLargestPresetKeepRatioInBounds() {
        let largest16x9 = CropGeometry.snapped(
            CropGeometry.largest(aspect: 16.0 / 9.0, in: bounds),
            in: bounds
        )
        #expect(largest16x9.width == 1000)
        #expect(largest16x9.height == 562 || largest16x9.height == 563)
        #expect(bounds.contains(largest16x9))

        let offCenter = CGRect(x: 750, y: 550, width: 200, height: 200)
        let reshaped = CropGeometry.snapped(
            CropGeometry.reshaped(offCenter, aspect: 16.0 / 9.0, in: bounds),
            in: bounds
        )
        #expect(bounds.contains(reshaped))
        #expect(abs(reshaped.width / reshaped.height - 16.0 / 9.0) < 0.02)
    }
}
