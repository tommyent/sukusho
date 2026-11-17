import AppKit
import Testing

@MainActor
@Suite
struct NumberedTailTests {
    static func pointer(_ x: Double, _ y: Double) -> PointerInfo {
        PointerInfo(screenPoint: Vec(x, y), pagePoint: Vec(x, y), command: false)
    }

    @Test static func aNumberedCirclePullsOutAShortTailAndDropsItBack() throws {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       imageSize: CGSize(width: 800, height: 600))
        var props = NumberedProps()
        props.diameter = 40
        let shape = AnnoShape(x: 200, y: 200, kind: .numbered(props))
        editor.replaceDocument(shapes: [shape])
        editor.selectedIds = [shape.id]
        func current() throws -> NumberedProps { try #require(editor.document.shape(shape.id)?.numberedProps) }

        // The pull handle sits below the circle; dragging it far away stops 0.84 diameters from
        // the centre, along the drag's direction.
        let pull = try #require(editor.textTailHandlePoint)
        #expect(pull == Vec(220, 240 + AnnoEditor.tailPullHandleOffset) && editor.handle(at: pull) == .textTail)
        editor.pointerDown(pointer(pull.x, pull.y))
        editor.pointerMove(pointer(520, 220))
        editor.pointerUp(pointer(520, 220))
        let tip = try #require(try current().tailPoint)
        #expect(abs(tip.x - 53.6) < 0.0001 && abs(tip.y - 20) < 0.0001)
        #expect(try current().tailPath?.contains(CGPoint(x: 50, y: 20)) == true)
        let handle = try #require(editor.textTailHandlePoint)
        #expect(abs(handle.x - 253.6) < 0.0001 && abs(handle.y - 220) < 0.0001)
        // The tail is part of what a click grabs and of what an export has to fit.
        #expect(editor.hitShape(at: Vec(250, 220))?.id == shape.id)
        #expect((editor.document.renderedPageBounds()?.maxX ?? 0) >= 256)
        editor.undo()
        #expect(try current().tail == nil)
        editor.redo()

        // Dropping the tip back on the circle removes the tail.
        editor.pointerDown(pointer(253.6, 220))
        editor.pointerMove(pointer(222, 221))
        editor.pointerUp(pointer(222, 221))
        #expect(try current().tail == nil && current().tailPath == nil)

        let saved = try JSONEncoder().encode(NumberedProps())
        var old = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        old["tail"] = nil
        #expect(try JSONDecoder().decode(NumberedProps.self, from: JSONSerialization.data(withJSONObject: old)).tail == nil)
    }

    /// The badge and its tail are one outline (mockup 05, A): one closed contour, so the ring
    /// follows it all the way round; the rounded tip ends about 1.8 radii out, and a tip saved
    /// further out by an older build comes in to that reach.
    @Test(arguments: [Vec(1.25, 0), Vec(0, 3), Vec(-0.9, -0.9)])
    static func badgeAndTailAreOneShortRoundedOutline(savedTail: Vec) throws {
        var props = NumberedProps()
        props.diameter = 40
        props.tail = savedTail
        let outline = props.outlinePath
        var contours = 0
        outline.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { contours += 1 }
        }
        #expect(contours == 1)

        let radius = 20.0, direction = Vec.mul(savedTail, 1 / hypot(savedTail.x, savedTail.y))
        func outlineReaches(_ distance: Double) -> Bool {
            outline.contains(CGPoint(x: radius + direction.x * distance, y: radius + direction.y * distance))
        }
        #expect(outlineReaches(1.75 * radius) && !outlineReaches(1.85 * radius))
        // Rounded, not a point: just inside the tip the outline is still about a rounding wide.
        let inside = 1.7 * radius, rounding = radius * NumberedProps.tailRounding * 0.8
        #expect(outline.contains(CGPoint(x: radius + direction.x * inside - direction.y * rounding,
                                         y: radius + direction.y * inside + direction.x * rounding)))
        #expect(outline.boundingBoxOfPath.insetBy(dx: -0.01, dy: -0.01)
            .contains(try #require(props.tailPath).boundingBoxOfPath))
    }

    /// Side handles exist only where they are drawn: on sides long enough to fit one.
    @Test(arguments: [(40.0, true), (20.0, false)])
    static func sideHandlesAreGrabbableOnlyWhereShown(diameter: Double, hasSides: Bool) throws {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       imageSize: CGSize(width: 800, height: 600))
        var props = NumberedProps()
        props.diameter = diameter
        let shape = AnnoShape(x: 200, y: 200, kind: .numbered(props))
        editor.replaceDocument(shapes: [shape])
        editor.selectedIds = [shape.id]
        let bounds = try #require(editor.selectionBounds)
        #expect(editor.resizeHandlePoints(bounds).count == (hasSides ? 8 : 4))
        #expect(editor.handle(at: Vec(200, 200)) == .topLeft)
        #expect(editor.handle(at: Vec(200 + diameter, 200 + diameter / 2)) == (hasSides ? .right : nil))
    }
}
