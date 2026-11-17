import CoreGraphics
import Foundation
import ImageIO

/// Whether two encodings of an image show the same picture. An optimiser such as Clop re-encodes a copied image
/// (pngquant's palette and dithering, or a JPEG), which changes the bytes and nudges many pixels a little; other
/// content, even one changed line of text, changes some pixels a lot. Both are drawn at the same reduced size and
/// compared pixel by pixel; anything that can't be read counts as different, so history keeps both copies.
nonisolated enum ClipboardImageMatch {
    /// The longer side both are compared at: enough that one changed character of screen text still differs
    /// strongly in a few pixels, while a re-encode's dithering averages out.
    static let comparedSide = 1024
    /// A pixel differs strongly when a channel moves by more than this (of 255), and only up to
    /// `maxStrongPixels` may. Calibrated on 2026-11-16 at 1024 px:
    /// - Clop's own rewrites of seven screenshots on the owner's Air moved no pixel by more than 58;
    ///   256- and 64-colour dithered palettes and JPEG 70 of screenshots and a photo, none by more than 61;
    /// - edits moved several pixels by more than 64: a caption on a photo 7, one changed digit 32,
    ///   two characters 63, a line of code 506.
    static let strongDifference = 64
    static let maxStrongPixels = 2
    /// The mean difference per channel (of 255) a re-encode may add: a 256-colour palette shifted it by up to 6.4.
    static let maxMeanDifference = 16.0

    struct Difference: Equatable, Sendable {
        /// Pixels with a channel that moved by more than `strongDifference`.
        var strongPixels: Int
        /// Mean absolute difference per channel, 0–255.
        var meanDifference: Double
    }

    static func isSamePicture(_ a: Data, _ b: URL) -> Bool {
        guard let first = image(a), let second = image(at: b) else { return false }
        return isSamePicture(first, second)
    }

    static func isSamePicture(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let difference = difference(a, b) else { return false }
        return difference.strongPixels <= maxStrongPixels && difference.meanDifference <= maxMeanDifference
    }

    /// Nil when the sizes differ or either can't be drawn.
    static func difference(_ a: CGImage, _ b: CGImage) -> Difference? {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else { return nil }
        let scale = min(1, Double(comparedSide) / Double(max(a.width, a.height)))
        let width = max(1, Int((Double(a.width) * scale).rounded()))
        let height = max(1, Int((Double(a.height) * scale).rounded()))
        guard let first = pixels(a, width: width, height: height),
              let second = pixels(b, width: width, height: height) else { return nil }
        var strong = 0
        var total = 0
        for pixel in stride(from: 0, to: first.count, by: 4) {
            var largest = 0
            for channel in 0..<3 {
                let delta = abs(Int(first[pixel + channel]) - Int(second[pixel + channel]))
                total += delta
                largest = max(largest, delta)
            }
            if largest > strongDifference { strong += 1 }
        }
        let count = width * height
        return Difference(strongPixels: strong, meanDifference: Double(total) / Double(count * 3))
    }

    static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func image(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// RGBA, sRGB, over white so transparency compares the same way in both.
    private static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
