import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

@main
struct CheckR2Export {
    static func main() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckR2Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("primary-checker.mov")
        let importURL = tempDir.appendingPathComponent("flat-import.mov")

        try await writeCheckerboardMovie(to: primaryURL, size: CGSize(width: 160, height: 120), duration: 2.0)
        try await writeFlatMovie(to: importURL, size: CGSize(width: 160, height: 120), duration: 1.0, color: (30, 110, 220))

        let primarySource = try await StudioVideoSource.load(url: primaryURL)
        let importSource = try await StudioVideoSource.load(url: importURL)

        let rawGen = AVAssetImageGenerator(asset: primarySource.asset)
        rawGen.requestedTimeToleranceBefore = .zero
        rawGen.requestedTimeToleranceAfter = .zero
        let rawImg = try await rawGen.image(at: CMTime(seconds: 0.55, preferredTimescale: 600)).image
        let rawDetail = detailScore(of: rawImg)
        print(String(format: "RAW_PRIMARY_DETAIL=%.2f", rawDetail))
        precondition(rawDetail > 50, "Expected high checkerboard detail")

        let fullMask = RecordingRedaction(
            start: 0.50,
            end: 0.75,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            mode: .pixelate,
            strength: 1.0
        )

        func makeImport(_ duration: TimeInterval) -> RecordingClipSegment {
            RecordingClipSegment(
                sourceStart: 0,
                sourceEnd: duration,
                mediaFileName: "flat-import.mov",
                displayName: "Flat",
                sourceDuration: 1.0
            )
        }

        let fixture1 = RecordingClipTimeline(segments: [
            makeImport(0.2505),
            makeImport(0.2505),
            makeImport(0.2505),
            makeImport(0.25),
            RecordingClipSegment(sourceStart: 0.50, sourceEnd: 0.75),
            makeImport(0.25)
        ])

        let fixture2 = RecordingClipTimeline(
            segments: (0..<16).map { _ in makeImport(0.2511) } + [
                RecordingClipSegment(sourceStart: 0.50, sourceEnd: 0.75),
                makeImport(0.25)
            ]
        )

        let baseTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0.50, sourceEnd: 0.75),
            makeImport(0.7515),
            makeImport(0.25)
        ])
        let split1 = baseTimeline.split(at: 0.25 + 0.2505)!.timeline
        let split2 = split1.split(at: 0.25 + 0.5010)!.timeline
        let fixture3 = split2.moving(segmentID: split2.segments[0].id, to: 4)!

        let cases: [(String, RecordingClipTimeline)] = [
            ("fixture1_4x0.2505", fixture1),
            ("fixture2_16x0.2511", fixture2),
            ("fixture3_split_reorder", fixture3)
        ]

        var exportSettings = VideoCompressionSettings()
        exportSettings.codec = .h264
        exportSettings.resolution = .original
        exportSettings.frameRate = .fps60
        exportSettings.quality = .high
        exportSettings.removeAudio = true

        var style = RecordingStudioStyle()
        style.background = .none
        style.padding = 0
        style.cornerRadius = 0
        style.shadow = 0

        for (name, timeline) in cases {
            let redactionSource = RecordingRedactionPreviewSource()
            redactionSource.update(redactions: [fullMask], clipTimeline: timeline)

            let (comp, vComp, timeMap) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
                primarySource: primarySource,
                importedSources: ["flat-import.mov": importSource],
                timeline: timeline,
                renderSize: primarySource.displaySize,
                redactionSource: redactionSource
            )
            let primaryEntry = timeMap.entries.first { $0.isPrimaryRecording }!
            let cutStart = primaryEntry.editorRange.start
            let cutEnd = primaryEntry.editorRange.end
            let step = CMTime(value: 1, timescale: 60)

            let checkOffsets: [(String, CMTime)] = [
                ("cut_start", cutStart),
                ("cut_start+1f", cutStart + step),
                ("cut_mid", cutStart + CMTime(seconds: primaryEntry.editorRange.duration.seconds / 2, preferredTimescale: 600)),
                ("cut_end-1f", cutEnd - step)
            ]

            // 1. Preview compositor check
            let previewGen = AVAssetImageGenerator(asset: comp)
            previewGen.videoComposition = vComp
            previewGen.requestedTimeToleranceBefore = .zero
            previewGen.requestedTimeToleranceAfter = .zero
            for (label, t) in checkOffsets {
                let img = try await previewGen.image(at: t).image
                let score = detailScore(of: img)
                print(String(format: "%@ PREVIEW %@ (t=%.4fs) detail=%.2f", name, label, t.seconds, score))
                precondition(score < 1.0, "Preview leaked detail \(score) on \(name) \(label)")
            }

            // 2. Real RecordingStudioExporter check
            let viewport = ViewportTimeline.identity
            let config = RecordingStudioExporter.Configuration(
                screenURL: primaryURL,
                cameraURL: nil,
                cameraOffset: 0,
                style: style,
                viewportTimeline: viewport,
                pointerTimeline: nil,
                showsPressEffects: false,
                keystrokeTimeline: nil,
                keystrokePlacement: .bottomCenter,
                subtitleTimeline: nil,
                subtitleStyle: SubtitleBarStyle(),
                canvasSize: primarySource.displaySize,
                clipTimeline: timeline,
                exportSettings: exportSettings,
                mediaDirectory: tempDir,
                redactions: [fullMask]
            )
            let exportedURL = try await RecordingStudioExporter().export(config) { _ in }
            defer { try? FileManager.default.removeItem(at: exportedURL) }

            let exportedAsset = AVURLAsset(url: exportedURL)
            let exportGen = AVAssetImageGenerator(asset: exportedAsset)
            exportGen.requestedTimeToleranceBefore = .zero
            exportGen.requestedTimeToleranceAfter = .zero
            for (label, t) in checkOffsets {
                let img = try await exportGen.image(at: t).image
                let score = detailScore(of: img)
                print(String(format: "%@ EXPORT  %@ (t=%.4fs) detail=%.2f", name, label, t.seconds, score))
                precondition(score < 1.0, "Export leaked detail \(score) on \(name) \(label)")
            }
        }
        print("ALL_EXPORT_AND_PREVIEW_CHECKS_PASSED")
    }

    static func writeCheckerboardMovie(to url: URL, size: CGSize, duration: TimeInterval) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 60
        let total = Int((duration * Double(fps)).rounded())
        for f in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<Int(size.height) {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<Int(size.width) {
                    let v: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 255 : 0
                    row[x * 4] = v; row[x * 4 + 1] = v; row[x * 4 + 2] = v; row[x * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    static func writeFlatMovie(to url: URL, size: CGSize, duration: TimeInterval, color: (UInt8, UInt8, UInt8)) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 60
        let total = Int((duration * Double(fps)).rounded())
        for f in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<Int(size.height) {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<Int(size.width) {
                    row[x * 4] = color.2; row[x * 4 + 1] = color.1; row[x * 4 + 2] = color.0; row[x * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    static func detailScore(of image: CGImage) -> Double {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func luma(_ x: Int, _ y: Int) -> Double {
            let o = (y * w + x) * 4
            return 0.299 * Double(bytes[o]) + 0.587 * Double(bytes[o + 1]) + 0.114 * Double(bytes[o + 2])
        }
        var sum = 0.0
        var count = 0
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) {
                let c = luma(x, y)
                sum += abs(c - luma(x + 1, y)) + abs(c - luma(x, y + 1))
                count += 2
            }
        }
        return sum / Double(max(1, count))
    }
}
