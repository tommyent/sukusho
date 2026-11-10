import AppKit
import Testing

@MainActor
@Suite
struct MagnifierShapeTests {
    @Test static func shapesOutlineRingAndLoupeAlike() throws {
        var props = MagnifierProps()
        props.ringSize = 100; props.loupeSize = 300
        // A corner of the bounding square: inside no rounded shape, and far outside a circle.
        let corner = CGPoint(x: -48, y: -48)
        #expect(!props.path(props.ringRect).contains(corner))
        props.shape = .circle
        #expect(props.ringRect == CGRect(x: -50, y: -50, width: 100, height: 100))
        #expect(!props.path(props.ringRect).contains(CGPoint(x: -40, y: -40)))
        #expect(props.path(props.ringRect).contains(CGPoint(x: -30, y: -30)))

        props.shape = .rectangle; props.aspect = 2
        #expect(props.ringRect == CGRect(x: -50, y: -25, width: 100, height: 50))
        #expect(props.loupeRect.size == CGSize(width: 300, height: 150) && props.zoom == 3 && props.isValid)
        #expect(props.path(props.ringRect).contains(CGPoint(x: -46, y: -21)))

        // Documents saved before shapes have neither key and stay rounded squares.
        let saved = try JSONEncoder().encode(MagnifierProps())
        var stripped = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        stripped["shape"] = nil; stripped["aspect"] = nil
        let decoded = try JSONDecoder().decode(MagnifierProps.self, from: JSONSerialization.data(withJSONObject: stripped))
        #expect(decoded.shape == nil && decoded.heightRatio == 1)
    }

    @Test static func aRectangleTakesTheDragsProportions() throws {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       imageSize: CGSize(width: 800, height: 600))
        editor.tool = .magnifier
        editor.currentMagnifierShape = .rectangle
        func pointer(_ x: Double, _ y: Double) -> PointerInfo {
            PointerInfo(screenPoint: Vec(x, y), pagePoint: Vec(x, y), command: true)
        }
        editor.pointerDown(pointer(100, 100))
        editor.pointerMove(pointer(300, 150))
        editor.pointerUp(pointer(300, 150))
        let props = try #require(editor.shapes.first.flatMap { shape -> MagnifierProps? in
            if case let .magnifier(props) = shape.kind { props } else { nil }
        })
        #expect(props.shape == .rectangle && props.aspect == 4 && props.ringSize == 200)
        #expect(props.ringRect.size == CGSize(width: 200, height: 50) && editor.tool == .magnifier)
    }
}
