import AppKit
import Testing

@MainActor
@Suite
struct TransparentBackgroundTests {
    @Test static func aTransparentBackgroundKeepsPaddingAndShadowOverSeeThroughPixels() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let image = try #require(source.makeImage())

        var settings = AnnotationBackgroundSettings()
        settings.style = .solid(.transparent)
        #expect(settings.isEnabled)
        let composed = try AnnotationBackgroundRenderer.compose(annotatedImage: image, settings: settings, colorSpace: space)
        #expect(composed.width > 200 && composed.height > 120, "the padding is still there")

        let width = composed.width, height = composed.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(composed, in: CGRect(x: 0, y: 0, width: width, height: height))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
        // The shadow may reach a corner, but nothing fills it: no shadow, nothing at all.
        #expect(alpha(0, 0) < 128 && alpha(width - 1, height - 1) < 128, "corners \(alpha(0, 0)) \(alpha(width - 1, height - 1)) \(alpha(0, height - 1)) \(alpha(width - 1, 0))")
        var bare = settings
        bare.shadow = 0
        let flat = try AnnotationBackgroundRenderer.compose(annotatedImage: image, settings: bare, colorSpace: space)
        var flatPixels = [UInt8](repeating: 0, count: flat.width * flat.height * 4)
        let flatContext = try #require(CGContext(data: &flatPixels, width: flat.width, height: flat.height,
                                                 bitsPerComponent: 8, bytesPerRow: flat.width * 4, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        flatContext.draw(flat, in: CGRect(x: 0, y: 0, width: flat.width, height: flat.height))
        #expect(flatPixels[3] == 0 && flatPixels[flatPixels.count - 1] == 0, "without a shadow the corners are fully see-through")
        #expect(alpha(width / 2, height / 2) == 255, "the screenshot is opaque")
        if settings.shadow > 0 {
            let partial = pixels.indices.filter { $0 % 4 == 3 }.contains { (1...254).contains(pixels[$0]) }
            #expect(partial, "the shadow lays partly see-through pixels around the screenshot")
        }
    }
}
