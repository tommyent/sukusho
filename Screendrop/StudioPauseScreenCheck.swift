//
//  StudioPauseScreenCheck.swift
//  Screendrop
//

import AVFoundation
import CoreGraphics

/// Reads a pause's frames from the screen movie, small and grey, and says
/// whether the screen stays still through it (`PausePlanner.isStill`). The
/// input log can't see everything: plain typing is never recorded, and a
/// page can load or a video play with no input at all.
nonisolated enum StudioPauseScreenCheck {
    /// False when anything changes, and when a frame can't be read, so a
    /// pause is kept rather than cut on a guess.
    @concurrent
    static func isStill(asset: AVURLAsset, gap: ClosedRange<TimeInterval>) async -> Bool {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let side = CGFloat(PausePlanner.frameWidth * 2)
        generator.maximumSize = CGSize(width: side, height: side)
        let tolerance = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var first: [UInt8]?
        for time in PausePlanner.frameTimes(in: gap) {
            // The movie's very last instant may have no frame to read.
            let readable = min(time, max(gap.lowerBound, gap.upperBound - 0.05))
            guard !Task.isCancelled,
                  let image = try? await generator.image(at: CMTime(seconds: readable, preferredTimescale: 600)).image,
                  let frame = grey(image) else { return false }
            guard let first else {
                first = frame
                continue
            }
            if !PausePlanner.isStill([first, frame]) { return false }
        }
        return first != nil
    }

    /// The frame at `PausePlanner.frameWidth` wide, one byte of grey a pixel.
    static func grey(_ image: CGImage) -> [UInt8]? {
        let width = PausePlanner.frameWidth
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(image.width, 1))).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
