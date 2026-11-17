//
//  IconLightness.swift
//  Screendrop
//

import CoreGraphics

/// Whether an app icon is light enough to vanish on a light card, so its caption ring is drawn (owner, 2026-11-17:
/// TextEdit's white page all but disappeared). Light means the mean luminance of the icon's painted pixels, each
/// counted by its opacity, is at least `threshold`; transparent margins don't count.
nonisolated enum IconLightness {
    static let threshold = 0.8
    /// The size the icon is drawn at to be measured: enough for its overall tone, cheap enough to do once per app.
    static let side = 16

    static func isLight(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn && isLight(premultipliedRGBA: pixels)
    }

    /// Premultiplied 8-bit RGBA, as `isLight(_:)` draws it.
    static func isLight(premultipliedRGBA pixels: [UInt8]) -> Bool {
        var weight = 0.0, luminance = 0.0
        for i in stride(from: 0, to: pixels.count - 3, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0 else { continue }
            // Premultiplied channels divided by alpha are the colour; times alpha again is the weight.
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
            weight += alpha
        }
        return weight > 0 && luminance / weight >= threshold
    }
}
