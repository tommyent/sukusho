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

        // The pull handle sits below the circle; dragging it far away stops three quarters of a
        // diameter past the edge, along the drag's direction.
        let pull = try #require(editor.textTailHandlePoint)
        #expect(pull == Vec(220, 240 + AnnoEditor.tailPullHandleOffset) && editor.handle(at: pull) == .textTail)
        editor.pointerDown(pointer(pull.x, pull.y))
        editor.pointerMove(pointer(520, 220))
        editor.pointerUp(pointer(520, 220))
        let tip = try #require(try current().tailPoint)
        #expect(abs(tip.x - 70) < 0.0001 && abs(tip.y - 20) < 0.0001)
        #expect(try current().tailPath?.contains(CGPoint(x: 60, y: 20)) == true)
        #expect(editor.textTailHandlePoint == Vec(270, 220))
        // The tail is part of what a click grabs and of what an export has to fit.
        #expect(editor.hitShape(at: Vec(262, 220))?.id == shape.id)
        #expect((editor.document.renderedPageBounds()?.maxX ?? 0) >= 270)
        editor.undo()
        #expect(try current().tail == nil)
        editor.redo()

        // Dropping the tip back on the circle removes the tail.
        editor.pointerDown(pointer(270, 220))
        editor.pointerMove(pointer(222, 221))
        editor.pointerUp(pointer(222, 221))
        #expect(try current().tail == nil && current().tailPath == nil)

        let saved = try JSONEncoder().encode(NumberedProps())
        var old = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        old["tail"] = nil
        #expect(try JSONDecoder().decode(NumberedProps.self, from: JSONSerialization.data(withJSONObject: old)).tail == nil)
    }
}
