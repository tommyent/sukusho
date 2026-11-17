import CoreGraphics
import Testing

/// Owner, 2026-11-17: a light app icon (TextEdit's white page) gets a hairline ring on Library cards.
struct IconLightnessTests {
    private func icon(_ fill: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        fill(context)
        return try #require(context.makeImage())
    }

    @Test func aWhitePageIsLightAndAColourfulIconIsNot() throws {
        // A white page with a few grey lines on a transparent margin, like TextEdit's.
        let page = try icon { c in
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 12, y: 4, width: 40, height: 56))
            c.setFillColor(CGColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1))
            for y in stride(from: 14, to: 50, by: 10) { c.fill(CGRect(x: 18, y: y, width: 28, height: 2)) }
        }
        #expect(IconLightness.isLight(page))
        let blue = try icon { c in
            c.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 0.95, alpha: 1)); c.fill(CGRect(x: 4, y: 4, width: 56, height: 56))
        }
        #expect(!IconLightness.isLight(blue))
        let grey = try icon { c in
            c.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        #expect(!IconLightness.isLight(grey))
    }

    @Test func transparencyIsNotLight() throws {
        #expect(!IconLightness.isLight(try icon { _ in }))
        // Half-transparent white still counts as white: opacity weighs the pixels, it doesn't darken them.
        #expect(IconLightness.isLight(premultipliedRGBA: [128, 128, 128, 128, 0, 0, 0, 0]))
    }
}
