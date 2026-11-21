//
//  AnnotationImageCropper.swift
//  Screendrop
//
//  Crops a source image at its native pixel resolution and writes the result
//  to a temporary PNG. Cropping happens on the full-resolution `CGImage`, so no
//  quality is lost. The returned `normalizedRect` reflects the exact (integral)
//  pixel rect that was used, so callers can remap annotations to match it
//  precisely.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AnnotationImageCropper {
    struct Result {
        let url: URL
        let pixelSize: CGSize
        /// The exact integral pixel rectangle cropped from the upright source.
        let pixelRect: CGRect
        /// The normalized rect (relative to the original image) derived from
        /// `pixelRect`, so callers can map overlays or animations precisely.
        let normalizedRect: CGRect
    }

    /// Crop `image` directly to `pixelRect` (image pixels, top-left origin),
    /// clamping to the image bounds without a normalized round-trip.
    nonisolated static func crop(_ image: CGImage, pixelRect requested: CGRect) -> (image: CGImage, pixelRect: CGRect)? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let clipped = requested.standardized.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let minX = clipped.minX.rounded()
        let minY = clipped.minY.rounded()
        let maxX = clipped.maxX.rounded()
        let maxY = clipped.maxY.rounded()
        let pixelRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(bounds)

        guard pixelRect.width >= 1,
              pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect) else {
            return nil
        }
        return (cropped, pixelRect)
    }

    /// Crop the image at `url` to `pixelRect` (image pixels, top-left origin).
    static func crop(url: URL, pixelRect requested: CGRect) -> Result? {
        guard let image = ScreenshotImageLoader.uprightImage(at: url),
              let (cropped, pixelRect) = crop(image, pixelRect: requested) else {
            return nil
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(SukushoFileNames.prefix)_Crop_\(UUID().uuidString.prefix(8)).png")

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            return nil
        }

        let usedRect = CGRect(
            x: pixelRect.minX / width,
            y: pixelRect.minY / height,
            width: pixelRect.width / width,
            height: pixelRect.height / height
        )

        return Result(
            url: destinationURL,
            pixelSize: CGSize(width: pixelRect.width, height: pixelRect.height),
            pixelRect: pixelRect,
            normalizedRect: usedRect
        )
    }
}
