import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

struct StudioTracksTests {
    // MARK: - Redaction Codable round-trip (legacy + new)

    @Test func redactionDecodesLegacySukushoDocumentAndPreservesSharedSafety() throws {
        let id = UUID()
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "start": 1.5,
            "end": 4.25,
            "rect": [[0.1, 0.2], [0.3, 0.4]],
            "mode": "blur",
            "strength": 0.75
        }
        """
        let decoded = try JSONDecoder().decode(RecordingRedaction.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == id)
        #expect(decoded.start == 1.5)
        #expect(decoded.end == 4.25)
        #expect(decoded.rect == CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(decoded.mode == .blur)
        #expect(decoded.strength == 0.75)
        #expect(decoded.cornerRadius == 0)
        #expect(decoded.fadeIn == 0)
        #expect(decoded.fadeOut == 0)
        try decoded.validate(sourceDuration: 10)

        let reencoded = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(RecordingRedaction.self, from: reencoded)
        #expect(restored == decoded)
        #expect(!RecordingRedaction.needsSharedReplacement([decoded], shared: [restored]))

        // New fields round-trip cleanly and flag shared links as needing replacement.
        var rounded = decoded
        rounded.mode = .pixelate
        rounded.cornerRadius = 18
        rounded.fadeIn = 0.25
        rounded.fadeOut = 0.5
        try rounded.validate(sourceDuration: 10)
        let roundTripped = try JSONDecoder().decode(RecordingRedaction.self, from: JSONEncoder().encode(rounded))
        #expect(roundTripped == rounded)
        #expect(RecordingRedaction.needsSharedReplacement([rounded], shared: [decoded]))
    }

    @Test func redactionDecodesUpstreamStyleAndAmountFallbackKeys() throws {
        let upstreamJSON = """
        {
            "start": 0.5,
            "end": 3.5,
            "rect": [[0.2, 0.2], [0.4, 0.3]],
            "style": "pixelate",
            "amount": 0.6,
            "cornerRadius": 12,
            "fadeIn": 0.3,
            "fadeOut": 0.4
        }
        """
        let decoded = try JSONDecoder().decode(RecordingRedaction.self, from: Data(upstreamJSON.utf8))
        #expect(decoded.mode == .pixelate)
        #expect(decoded.strength == 0.6)
        #expect(decoded.cornerRadius == 12)
        #expect(decoded.fadeIn == 0.3)
        #expect(decoded.fadeOut == 0.4)
        try decoded.validate(sourceDuration: 5)
    }

    @Test func redactionValidationRejectsInvalidCornerRadiusAndFades() {
        let base = RecordingRedaction(start: 1, end: 4, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        var badCorner = base; badCorner.cornerRadius = -1
        var hugeCorner = base; hugeCorner.cornerRadius = 120
        var badFadeIn = base; badFadeIn.fadeIn = -0.1
        var badFadeOut = base; badFadeOut.fadeOut = .nan
        for invalid in [badCorner, hugeCorner, badFadeIn, badFadeOut] {
            #expect(throws: RecordingRedactionError.self) { try invalid.validate(sourceDuration: 5) }
        }
    }

    @Test func redactionFadeAndRoundedCornersFilterExpectedPixels() throws {
        let width = 128, height = 128
        let pixels = (0..<(width * height)).flatMap { index -> [UInt8] in
            let v: UInt8 = ((index % width) / 2 + (index / width) / 2) % 2 == 0 ? 255 : 0
            return [v, v, v, 255]
        }
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.data?.copyMemory(from: pixels, byteCount: pixels.count)
        let source = CIImage(cgImage: try #require(bitmap.makeImage()))
        let region = RecordingRedaction(
            start: 1, end: 5,
            rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            mode: .pixelate, strength: 0.8, cornerRadius: 100, fadeIn: 1.0, fadeOut: 1.0
        )
        #expect(abs(region.opacity(atSourceTime: 1.5) - 0.5) < 0.0001)
        #expect(abs(region.opacity(atSourceTime: 3.0) - 1.0) < 0.0001)
        #expect(abs(region.opacity(atSourceTime: 4.5) - 0.5) < 0.0001)

        // At full opacity with large corner radius, the center is redacted while the
        // outer corner of the bounding box remains untouched.
        let filtered = try RecordingRedactionFilter.apply([region], to: source, atSourceTime: 3.0)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let outCG = try #require(context.createCGImage(filtered, from: source.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let outData = try #require(outCG.dataProvider?.data) as Data
        let inData = Data(pixels)

        // Top-left corner of the [32..96, 32..96] box sits outside the rounded corner arc.
        let cornerIndex = 32 * outCG.bytesPerRow + 32 * 4
        #expect(abs(Int(outData[cornerIndex]) - Int(inData[cornerIndex])) <= 2)
    }

    // MARK: - Source-time placement across cuts and speed ramps

    @Test func textAndImageBlocksMapAcrossCutsAndSpeedRamps() {
        // Source 0..10s with 4..6s deleted, and 0..4s playing at 2x (editor 0..2s)
        // followed by 6..10s playing at 1x (editor 2..6s).
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 2),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 10, speed: 1)
        ])

        // Text spanning the deleted cut (source 2..8s):
        // slice 1 = source 2..4 -> editor 1..2
        // slice 2 = source 6..8 -> editor 2..4
        // Touching slices merge into one editor block 1..4s.
        let spanningText = RecordingTextOverlay(start: 2, end: 8)
        let hiddenText = RecordingTextOverlay(start: 4.2, end: 5.8)
        let textBlocks = RecordingOverlayTimelineBlock.blocks(
            for: [spanningText, hiddenText],
            clipTimeline: timeline
        ) { ($0.start, $0.end) }
        #expect(textBlocks.count == 1)
        #expect(textBlocks[0].id == spanningText.id)
        #expect(abs(textBlocks[0].editorStart - 1.0) < 0.0001)
        #expect(abs(textBlocks[0].editorEnd - 4.0) < 0.0001)

        // Image entirely inside the 2x clip (source 1..3s -> editor 0.5..1.5s).
        let fastImage = RecordingImageOverlay(fileName: "a.png", displayName: "a", start: 1, end: 3)
        let cutImage = RecordingImageOverlay(fileName: "b.png", displayName: "b", start: 4.5, end: 5.5)
        let imageBlocks = RecordingOverlayTimelineBlock.blocks(
            for: [fastImage, cutImage],
            clipTimeline: timeline
        ) { ($0.start, $0.end) }
        #expect(imageBlocks.count == 1)
        #expect(imageBlocks[0].id == fastImage.id)
        #expect(abs(imageBlocks[0].editorStart - 0.5) < 0.0001)
        #expect(abs(imageBlocks[0].editorEnd - 1.5) < 0.0001)

        // Moving a 1s editor-length block from the 2x clip onto the 1x clip keeps
        // its 1s editor length (covers 1s of source on the 1x clip).
        let moved = studioMovedSourceRange(clipTimeline: timeline, editorStart: 3.0, editorLength: 1.0)
        #expect(abs(moved.start - 7.0) < 0.0001)
        #expect(abs(moved.end - 8.0) < 0.0001)
    }

    // MARK: - Preview vs Export pixel comparison (including animated GIF + Text)

    @Test func previewAndExportRenderMatchingFramesForTextAndAnimatedGIF() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioTracksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Build a 2-frame animated GIF: frame 0 solid red (0.1s), frame 1 solid blue (0.1s).
        let gifURL = tempDir.appendingPathComponent("anim.gif")
        try writeTwoFrameAnimatedGIF(to: gifURL)
        let decodedGIF = try #require(RecordingOverlayImage(url: gifURL))
        #expect(decodedGIF.isAnimated)
        #expect(decodedGIF.frames.count == 2)
        #expect(abs(decodedGIF.loopDuration - 0.2) < 0.02)

        var imageOverlay = RecordingImageOverlay(fileName: "anim.gif", displayName: "anim", start: 0, end: 5)
        imageOverlay.center = CGPoint(x: 0.5, y: 0.5)
        imageOverlay.width = 0.5
        imageOverlay.aspect = 1
        imageOverlay.cornerRadius = 16
        imageOverlay.rotation = 10
        imageOverlay.fadeIn = 0.2

        var textOverlay = RecordingTextOverlay(start: 0, end: 5)
        textOverlay.text = "Hello\nStudio"
        textOverlay.font = .sans
        textOverlay.fontSize = 0.12
        textOverlay.hasBackground = true
        textOverlay.backgroundColor = RecordingOverlayColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)
        textOverlay.animationIn = RecordingTextAnimation(effect: .fade, duration: 0.4, unit: .words, order: .forward, delay: 0.05, ease: .out)

        let size = CGSize(width: 320, height: 180)

        for sampleTime in [0.05, 0.15, 1.0] {
            // Preview path: top-down canvas coordinates (matching SwiftUI Canvas).
            let previewBytes = try renderPixels(size: size, flipForExport: false) { ctx in
                RecordingImageOverlayRenderer.draw(imageOverlay, image: decodedGIF, atSourceTime: sampleTime, canvasSize: size, in: ctx)
                RecordingTextOverlayRenderer.draw(textOverlay, atSourceTime: sampleTime, canvasSize: size, in: ctx)
            }
            // Exporter path: bottom-up CGContext flipped top-down identically to
            // StudioFrameCompositor.drawImageOverlays / drawTextOverlays.
            let exportBytes = try renderPixels(size: size, flipForExport: true) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                RecordingImageOverlayRenderer.draw(imageOverlay, image: decodedGIF, atSourceTime: sampleTime, canvasSize: size, in: ctx)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                RecordingTextOverlayRenderer.draw(textOverlay, atSourceTime: sampleTime, canvasSize: size, in: ctx)
                ctx.restoreGState()
            }

            #expect(previewBytes == exportBytes, "Preview and exporter frames diverged at t=\(sampleTime)")
            // Verify non-empty drawing occurred.
            #expect(previewBytes.contains { $0 != 0 })
        }

        // Verify the animated GIF actually advances from frame 0 (red) to frame 1 (blue).
        let frame0 = try renderPixels(size: size, flipForExport: false) { ctx in
            RecordingImageOverlayRenderer.draw(imageOverlay, image: decodedGIF, atSourceTime: 0.25, canvasSize: size, in: ctx)
        }
        let frame1 = try renderPixels(size: size, flipForExport: false) { ctx in
            RecordingImageOverlayRenderer.draw(imageOverlay, image: decodedGIF, atSourceTime: 0.35, canvasSize: size, in: ctx)
        }
        #expect(frame0 != frame1)
    }

    // MARK: - Helpers

    private func renderPixels(
        size: CGSize,
        flipForExport: Bool,
        draw: (CGContext) -> Void
    ) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        if !flipForExport {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        draw(context)
        let ptr = try #require(context.data)
        return Data(bytes: ptr, count: bytesPerRow * height)
    }

    private func writeTwoFrameAnimatedGIF(to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let gifProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.1]
        ]
        for color in [(UInt8(240), UInt8(30), UInt8(30)), (UInt8(30), UInt8(60), UInt8(240))] {
            let img = try solidImage(width: 64, height: 64, r: color.0, g: color.1, b: color.2)
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
    }

    private func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
        }
        let ctx = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(ctx.makeImage())
    }
}
