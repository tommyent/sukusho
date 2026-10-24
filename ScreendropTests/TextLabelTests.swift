import AppKit
import Testing

/// Boxed text labels: text centred in its box (sd-eqj7) and a speech-bubble tail (sd-cxui).
@MainActor
struct TextLabelTests {
    static func boxed(_ text: String, fontSize: Double = 48) -> TextProps {
        var props = TextProps(text: text, fontSize: fontSize)
        props.boxStyle = .box
        return props
    }

    /// An RGBA bitmap whose first row is the page's top.
    struct Bitmap {
        var data: Data
        var bytesPerRow: Int
        var width: Int
        var height: Int
        /// Pixels per page unit.
        var scale: Int

        func rgba(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * bytesPerRow + x * 4
            return Array(data[offset..<offset + 4])
        }

        /// The first and one-past-last rows, in page units, where `matches` holds for any pixel.
        func rows(_ matches: ([UInt8]) -> Bool) -> (top: Double, bottom: Double)? {
            let hits = (0..<height).filter { y in (0..<width).contains { x in matches(rgba(x, y)) } }
            guard let first = hits.first, let last = hits.last else { return nil }
            return (Double(first) / Double(scale), Double(last + 1) / Double(scale))
        }
    }

    /// Draws `shapes` on black into a `width` x `height` page at `scale` pixels per page unit,
    /// either as the flipped canvas does or as the y-up export does.
    static func drawn(_ shapes: [AnnoShape], width: Int, height: Int, scale: Int = 4, flippedCanvas: Bool) -> Bitmap {
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(shapes: shapes, bindings: []))
        let (w, h) = (width * scale, height * scale)
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let s = CGFloat(scale)
        var target = AnnoShapeDrawing.Target(transform: .identity, pageSize: CGSize(width: width, height: height),
                                             sample: { _ in nil }, spotlightClip: nil, isFlippedContext: flippedCanvas)
        if flippedCanvas {
            context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
            target.transform = CGAffineTransform(scaleX: s, y: s)
        } else {
            target.transform = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: CGFloat(h))
        }
        AnnoShapeDrawing.draw(document, in: context, target: target)
        return Bitmap(data: Data(bytes: context.data!, count: h * w * 4), bytesPerRow: w * 4,
                      width: w, height: h, scale: scale)
    }

    /// White ink at half coverage or more over the red box (red's green channel is about 36).
    static func isInk(_ p: [UInt8]) -> Bool { p[1] > 145 }

    // MARK: - sd-eqj7

    /// The user's label: white on red, as much room above the ink as below it, on the canvas and
    /// in the export. On main the gaps were 26 and 14.
    @Test(arguments: [true, false])
    func exportedTextIsCentredInItsBox(flippedCanvas: Bool) throws {
        let props = Self.boxed("both I named")
        let outer = TextMeasure.outerRect(props)
        let shape = AnnoShape(x: 20, y: 10, kind: .text(props))
        let bitmap = Self.drawn([shape], width: Int(outer.width) + 40, height: Int(outer.height) + 20,
                                flippedCanvas: flippedCanvas)
        let ink = try #require(bitmap.rows(Self.isInk))
        let boxTop = 10 + outer.minY, boxBottom = 10 + outer.maxY
        let top = ink.top - boxTop, bottom = boxBottom - ink.bottom
        #expect(abs(top - bottom) <= 1, "gaps above and below the text: \(top), \(bottom)")
    }

    /// The cap band sits centred in every line, on one line and three, at small, default and
    /// huge sizes. An H's ink is its cap band in the SF faces; TextKit rounds the baseline by up
    /// to half a unit. Marker Felt's H hangs below its baseline, so it's covered by the next test.
    @Test(arguments: [12.0, 48.0, 200.0])
    func capBandIsCentredInEachLine(fontSize: Double) {
        for family in AnnoFontFamily.allCases {
            for lines in [1, 3] {
                var props = Self.boxed(Array(repeating: "H", count: lines).joined(separator: "\n"), fontSize: fontSize)
                props.fontFamily = family
                let ink = TextMeasure.glyphPath(props).boundingBoxOfPath
                let line = Double(TextMeasure.lineHeight(props))
                #expect(abs(ink.midY - Double(lines) * line / 2) <= 0.6, "\(family) \(fontSize) pt, \(lines) lines")
            }
        }
    }

    /// Only a box raises the glyphs, and only vertically; plain text stays where it always was.
    @Test func onlyBoxedGlyphsMove() {
        for face in [nil, AnnoFontFace.markerFelt] {
            for family in AnnoFontFamily.allCases {
                var plain = TextProps(text: "both I named\ngypsy")
                plain.fontFamily = family; plain.fontFace = face
                var boxed = plain
                boxed.boxStyle = .box
                #expect(TextMeasure.glyphLift(plain) == 0)
                let lift = Double(TextMeasure.glyphLift(boxed))
                #expect(lift > 0)
                let a = TextMeasure.glyphPath(plain).boundingBoxOfPath
                let b = TextMeasure.glyphPath(boxed).boundingBoxOfPath
                #expect(abs(b.minX - a.minX) < 1e-6 && abs(b.width - a.width) < 1e-6)
                #expect(abs(b.minY - (a.minY - lift)) < 1e-6 && abs(b.height - a.height) < 1e-6)
            }
        }
    }

    /// The editing text view draws its text where the canvas does, at 1x and 2x.
    @Test(arguments: [1.0, 2.0])
    func editingOverlayMatchesTheCanvas(zoom: Double) throws {
        let props = Self.boxed("both I named")
        let (overlay, _) = Self.overlay(props, zoom: zoom)
        let rep = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        let pixelsPerPage = Double(rep.pixelsHigh) / Double(overlay.bounds.height) * zoom
        var top = Int.max, bottom = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5, color.greenComponent > 0.57 else { continue }
                top = min(top, y); bottom = max(bottom, y + 1)
            }
        }
        try #require(top < bottom, "the overlay drew its text")
        // The view's top is the box's top, the shape's outer rect.
        let outer = TextMeasure.outerRect(props)
        let glyphs = TextMeasure.glyphPath(props).boundingBoxOfPath
        let tolerance = 1 / zoom
        #expect(abs(Double(top) / pixelsPerPage - (glyphs.minY - outer.minY)) <= tolerance)
        #expect(abs(Double(bottom) / pixelsPerPage - (glyphs.maxY - outer.minY)) <= tolerance)
    }

    /// Clicks are mapped through the raised lines, so they land where the glyphs are drawn. The
    /// points are 2 pt either side of the raised boundary between the lines: within the lift, so
    /// an unraised layout would put the lower one in line 1.
    @Test func clicksFollowTheRaisedLines() {
        let props = Self.boxed("HE\nHE")
        let (overlay, _) = Self.overlay(props, zoom: 1)
        overlay.layoutManager?.ensureLayout(for: overlay.textContainer!)
        let inset = TextMeasure.boxInsets(props)
        let boundary = inset.y - Double(TextMeasure.glyphLift(props)) + Double(TextMeasure.lineHeight(props))
        let below = overlay.characterIndexForInsertion(at: NSPoint(x: inset.x + 5, y: boundary + 2))
        let above = overlay.characterIndexForInsertion(at: NSPoint(x: inset.x + 5, y: boundary - 2))
        #expect(below >= 3, "2 pt below the raised boundary is line 2: \(below)")
        #expect(above < 3, "2 pt above it is line 1: \(above)")
    }

    // MARK: - sd-cxui: model, geometry, drawing

    static func tailed(_ tip: Vec?, text: String = "Like this") -> TextProps {
        var props = boxed(text)
        props.tail = tip
        return props
    }

    /// The points a path is built from, in order.
    static func points(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count = switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            default: 0
            }
            points += (0..<count).map { element.pointee.points[$0] }
        }
        return points
    }

    @Test func tailDecodesAndRoundTrips() throws {
        let old = try JSONEncoder().encode(Self.boxed("An old label"))
        #expect(!String(decoding: old, as: UTF8.self).contains("tail"))
        #expect(try JSONDecoder().decode(TextProps.self, from: old).tail == nil)
        let props = Self.tailed(Vec(400, 200))
        #expect(try JSONDecoder().decode(TextProps.self, from: JSONEncoder().encode(props)) == props)
    }

    @Test func noTailWithoutABoxATipOrRoom() {
        let box = TextMeasure.outerRect(Self.boxed("Like this"))
        let reach = 48 * TextMeasure.tailMinLength
        #expect(TextMeasure.tailPath(Self.tailed(nil)) == nil)
        var plain = Self.tailed(Vec(box.midX, box.maxY + 100))
        plain.boxStyle = .plain
        #expect(TextMeasure.tailPath(plain) == nil, "box off: no tail drawn, the tip kept")
        #expect(TextMeasure.tailPath(Self.tailed(Vec(box.midX, box.midY))) == nil, "tip inside the box")
        #expect(TextMeasure.tailPath(Self.tailed(Vec(box.midX, box.maxY + reach - 1))) == nil, "too short")
        #expect(TextMeasure.tailPath(Self.tailed(Vec(box.midX, box.maxY + reach + 1))) != nil)
    }

    /// The base sits on the side the ray from the box's centre to the tip crosses, tucked half a
    /// corner radius inside the box, and the tip is exactly the stored point.
    @Test func tailHangsFromTheSideFacingItsTip() throws {
        let props = Self.boxed("Like this")
        let box = TextMeasure.outerRect(props)
        let tuck = TextMeasure.boxCornerRadius(props) / 2
        let cases: [(tip: Vec, side: String)] = [
            (Vec(box.midX + 60, box.maxY + 200), "bottom"),
            (Vec(box.midX - 60, box.minY - 200), "top"),
            (Vec(box.maxX + 200, box.midY + 10), "right"),
            (Vec(box.minX - 200, box.midY - 10), "left"),
            // Far past the right end but further down: the bottom, as in Shottr's sample.
            (Vec(box.maxX + 88, box.maxY + 112), "bottom"),
        ]
        for (tip, side) in cases {
            let path = try #require(TextMeasure.tailPath(Self.tailed(tip)))
            let bounds = path.boundingBoxOfPath
            #expect(Self.points(path).contains(tip.cgPoint), "\(side): the tip is the stored point")
            switch side {
            case "bottom": #expect(abs(bounds.minY - (box.maxY - tuck)) < 1e-9)
            case "top": #expect(abs(bounds.maxY - (box.minY + tuck)) < 1e-9)
            case "right": #expect(abs(bounds.minX - (box.maxX - tuck)) < 1e-9)
            default: #expect(abs(bounds.maxX - (box.minX + tuck)) < 1e-9)
            }
        }
    }

    @Test func baseWidensWithLengthUpToTheStraightRun() throws {
        let props = Self.boxed("Like this")
        let box = TextMeasure.outerRect(props)
        let span = box.width - TextMeasure.boxCornerRadius(props) * 2
        func base(_ length: Double) throws -> Double {
            try #require(TextMeasure.tailPath(Self.tailed(Vec(box.midX, box.maxY + length)))).boundingBoxOfPath.width
        }
        #expect(abs(try base(20) - 48 * TextMeasure.tailMinLength) < 1e-9, "the narrowest base")
        #expect(abs(try base(100) - 100 * TextMeasure.tailBasePerLength) < 1e-9)
        #expect(abs(try base(5000) - span) < 1e-9, "no wider than the straight run")
    }

    /// The tail draws in the box's colour, on the canvas and in the export, with no darker seam
    /// where it meets the box, even on a translucent box.
    @Test(arguments: [(true, 1.0), (false, 1.0), (true, 0.5), (false, 0.5)])
    func tailDrawsAsOneShapeWithItsBox(flippedCanvas: Bool, alpha: Double) {
        var props = Self.tailed(nil)
        props.swatch = props.swatch.withAlpha(alpha)
        let box = TextMeasure.outerRect(props)
        props.tail = Vec(box.midX, box.maxY + 150)
        let origin = Vec(20, 10)
        let bitmap = Self.drawn([AnnoShape(x: origin.x, y: origin.y, kind: .text(props))],
                                width: Int(box.width) + 40, height: Int(box.maxY) + 180, flippedCanvas: flippedCanvas)
        func pixel(_ x: Double, _ y: Double) -> [Int] {
            bitmap.rgba(Int((origin.x + x) * 4), Int((origin.y + y) * 4)).prefix(3).map(Int.init)
        }
        let boxColour = pixel(box.midX + 80, box.maxY - 2)
        #expect(boxColour[0] > 100 && boxColour[1] < 80, "the box is red: \(boxColour)")
        for (name, colour) in [("the tail", pixel(box.midX, box.maxY + 30)),
                               ("where the tail meets the box", pixel(box.midX, box.maxY - 2))] {
            #expect(zip(colour, boxColour).allSatisfy { abs($0 - $1) <= 2 }, "\(name): \(colour) vs \(boxColour)")
        }
        #expect(pixel(box.midX + 60, box.maxY + 30) == [0, 0, 0], "nothing beside the tail")
    }

    /// A tip dragged past the screenshot's edge grows the canvas with it.
    @Test func tailCountsTowardTheDrawnBounds() throws {
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(
            shapes: [AnnoShape(x: 100, y: 100, kind: .text(Self.tailed(Vec(50, 900))))], bindings: []))
        let bounds = try #require(document.renderedPageBounds())
        #expect(abs(bounds.maxY - 1000) < 0.01 && bounds.minX < 150)
    }

    /// An overlay synced to one boxed label at `zoom`, with no window.
    static func overlay(_ props: TextProps, zoom: Double) -> (AnnoTextEditorOverlay, AnnoEditor) {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(imageFrame: CGRect(x: 0, y: 0, width: 800 * zoom, height: 600 * zoom),
                                       imageSize: CGSize(width: 800, height: 600))
        let shape = AnnoShape(x: 0, y: 0, kind: .text(props))
        editor.replaceDocument(shapes: [shape])
        let overlay = AnnoTextEditorOverlay(editor: editor, shapeId: shape.id)
        overlay.string = props.text
        overlay.sync()
        return (overlay, editor)
    }
}
