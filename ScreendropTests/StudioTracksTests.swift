import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
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
        try decoded.validate(sourceDuration: 10)

        let reencoded = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(RecordingRedaction.self, from: reencoded)
        #expect(restored == decoded)
        #expect(!RecordingRedaction.needsSharedReplacement([decoded], shared: [restored]))

        // Changing redaction mode flags shared links as needing replacement.
        var edited = decoded
        edited.mode = .pixelate
        try edited.validate(sourceDuration: 10)
        let roundTripped = try JSONDecoder().decode(RecordingRedaction.self, from: JSONEncoder().encode(edited))
        #expect(roundTripped == edited)
        #expect(RecordingRedaction.needsSharedReplacement([edited], shared: [decoded]))
    }

    @Test func redactionDecodesUpstreamStyleAndAmountAndIgnoresFadeCornerKeys() throws {
        let upstreamJSON = """
        {
            "start": 0.5,
            "end": 3.5,
            "rect": [[0.2, 0.2], [0.4, 0.3]],
            "style": "pixelate",
            "amount": 0.6,
            "cornerRadius": 80,
            "fadeIn": 1.5,
            "fadeOut": 1.5
        }
        """
        let decoded = try JSONDecoder().decode(RecordingRedaction.self, from: Data(upstreamJSON.utf8))
        #expect(decoded.mode == .pixelate)
        #expect(decoded.strength == 0.6)
        try decoded.validate(sourceDuration: 5)
    }

    @Test(arguments: RecordingRedaction.Mode.allCases)
    func exportedRedactionMasksFullRectangleAndCornersOnFirstAndLastIntersectingFrames(_ mode: RecordingRedaction.Mode) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioRedactionExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let width = 128, height = 128, fps = 30
        let frameInterval = 1.0 / Double(fps)
        let sourceURL = tempDir.appendingPathComponent("source.mov")
        let exportedURL = tempDir.appendingPathComponent("exported.mov")

        // Write a 2-second 30fps movie with a stark black/white 2x2 checkerboard inside [32..96, 32..96]
        // and flat mid-gray outside. Every corner of [32..96, 32..96] has high-contrast alternating tiles.
        try await writeCheckerboardMovie(to: sourceURL, width: width, height: height, fps: fps, frameCount: fps * 2)

        // Redaction spans 0.51...1.49 so frame 15 (0.500..0.533) straddles start
        // and frame 44 (1.467..1.500) straddles end. Even if loaded from a draft
        // carrying fade/corner keys, every intersecting frame and corner must be masked.
        let json = """
        {
            "start": 0.51,
            "end": 1.49,
            "rect": [[0.25, 0.25], [0.5, 0.5]],
            "mode": "\(mode.rawValue)",
            "strength": 0.9,
            "cornerRadius": 100,
            "fadeIn": 1.0,
            "fadeOut": 1.0
        }
        """
        let region = try JSONDecoder().decode(RecordingRedaction.self, from: Data(json.utf8))
        let timeline = RecordingClipTimeline.full(sourceDuration: 2.0)

        // Export through the exact buffer filter + outward covers() check used by RecordingStudioExporter.
        try await exportRedactedMovie(
            from: sourceURL,
            to: exportedURL,
            redactions: [region],
            timeline: timeline,
            width: width,
            height: height,
            fps: fps
        )

        let exportedAsset = AVURLAsset(url: exportedURL)
        let generator = AVAssetImageGenerator(asset: exportedAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Frame 15 (0.500s) is the first intersecting frame; frame 44 (1.467s) is the last.
        // Frame 10 (0.333s) is outside and must remain unredacted (high corner contrast).
        let unredactedFrame = try await generator.image(at: CMTime(value: 10, timescale: CMTimeScale(fps))).image
        let firstIntersecting = try await generator.image(at: CMTime(value: 15, timescale: CMTimeScale(fps))).image
        let lastIntersecting = try await generator.image(at: CMTime(value: 44, timescale: CMTimeScale(fps))).image

        #expect(region.covers(editorTime: 15 * frameInterval, frameDuration: frameInterval, timeline: timeline))
        #expect(region.covers(editorTime: 44 * frameInterval, frameDuration: frameInterval, timeline: timeline))
        #expect(!region.covers(editorTime: 10 * frameInterval, frameDuration: frameInterval, timeline: timeline))

        // Check all 4 corners of the redacted box [32..96, 32..96]:
        // unredacted corner 8x8 patch has max-min luminance > 180; masked patch collapses contrast.
        let corners = [(32, 32), (88, 32), (32, 88), (88, 88)]
        for (cx, cy) in corners {
            let baselineContrast = try patchLuminanceRange(in: unredactedFrame, x: cx, y: cy, size: 8)
            #expect(baselineContrast > 150, "Baseline checkerboard corner (\(cx),\(cy)) must have high contrast")

            let firstContrast = try patchLuminanceRange(in: firstIntersecting, x: cx, y: cy, size: 8)
            let lastContrast = try patchLuminanceRange(in: lastIntersecting, x: cx, y: cy, size: 8)
            #expect(firstContrast < 40, "First intersecting frame leaked corner (\(cx),\(cy)) with contrast \(firstContrast)")
            #expect(lastContrast < 40, "Last intersecting frame leaked corner (\(cx),\(cy)) with contrast \(lastContrast)")
        }
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

    private func writeCheckerboardMovie(
        to url: URL,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var rawBuffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rawBuffer) == kCVReturnSuccess)
            let buffer = try #require(rawBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let inside = x >= width / 4 && x < width * 3 / 4 && y >= height / 4 && y < height * 3 / 4
                        let v: UInt8 = inside ? ((((x / 2) + (y / 2)) % 2 == 0) ? 255 : 0) : 128
                        let offset = y * bpr + x * 4
                        ptr[offset] = v; ptr[offset + 1] = v; ptr[offset + 2] = v; ptr[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func exportRedactedMovie(
        from sourceURL: URL,
        to destinationURL: URL,
        redactions: [RecordingRedaction],
        timeline: RecordingClipTimeline,
        width: Int,
        height: Int,
        fps: Int
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        #expect(reader.startReading())

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        let frameInterval = 1.0 / Double(fps)
        while let sample = output.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let active = redactions.filter {
                $0.covers(editorTime: pts.seconds, frameDuration: frameInterval, timeline: timeline)
            }
            let filtered = try RecordingRedactionFilter.buffer(from: sourceBuffer, redactions: active, context: ciContext)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(adaptor.append(filtered, withPresentationTime: pts))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func patchLuminanceRange(in image: CGImage, x: Int, y: Int, size: Int) throws -> Int {
        let width = image.width, height = image.height
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        let ctx = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minV = 255, maxV = 0
        for py in y..<min(y + size, height) {
            for px in x..<min(x + size, width) {
                let v = Int(bytes[py * bpr + px * 4])
                if v < minV { minV = v }
                if v > maxV { maxV = v }
            }
        }
        return maxV - minV
    }
}
