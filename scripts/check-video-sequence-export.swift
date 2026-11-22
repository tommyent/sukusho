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

        // Round 3 — Finding 9a: Primary-only movie with shorter video track (2.00 s) than audio (2.98 s).
        // Timed checkerboard + mask + 880 Hz tone ONLY at 0.50..<0.75 s; flat grey + silence elsewhere.
        let shortPrimaryURL = tempDir.appendingPathComponent("r3-short-primary.mov")
        try await writeTimedMovie(
            to: shortPrimaryURL,
            size: CGSize(width: 160, height: 120),
            videoDuration: 2.0,
            audioDuration: 2.98,
            checkerWindow: 0.50..<0.75,
            backgroundColor: (128, 128, 128),
            toneWindow: 0.50..<0.75,
            toneHz: 880
        )
        let shortPrimaryAsset = AVURLAsset(url: shortPrimaryURL)
        let shortPrimaryDuration = try await shortPrimaryAsset.load(.duration).seconds
        let shortPrimaryVideoTrack = try await shortPrimaryAsset.loadTracks(withMediaType: .video).first!
        let shortTimeline = RecordingClipTimeline.full(sourceDuration: shortPrimaryDuration)

        let (shortComp, shortTimeMap) = try RecordingCompositionBuilder.makeVideoCompositionWithTimeMap(
            videoTrack: shortPrimaryVideoTrack,
            timeline: shortTimeline
        )
        let shortPreviewSource = RecordingRedactionPreviewSource()
        shortPreviewSource.update(redactions: [fullMask], clipTimeline: shortTimeline, timeMap: shortTimeMap)
        let shortPreviewVComp = try await shortPreviewSource.composition(asset: shortComp)
        let shortPreviewGen = AVAssetImageGenerator(asset: shortComp)
        shortPreviewGen.videoComposition = shortPreviewVComp
        shortPreviewGen.requestedTimeToleranceBefore = .zero
        shortPreviewGen.requestedTimeToleranceAfter = .zero
        for t in [0.55, 0.75, 0.90] {
            let img = try await shortPreviewGen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let score = detailScore(of: img)
            print(String(format: "r3_primary_short_picture PREVIEW (t=%.2fs) detail=%.2f", t, score))
            precondition(score < 1.0, "r3_primary_short_picture preview leaked detail \(score) at t=\(t)")
        }

        var audioExportSettings = exportSettings
        audioExportSettings.removeAudio = false
        let shortExportConfig = RecordingStudioExporter.Configuration(
            screenURL: shortPrimaryURL,
            cameraURL: nil,
            cameraOffset: 0,
            style: style,
            viewportTimeline: .identity,
            pointerTimeline: nil,
            showsPressEffects: false,
            keystrokeTimeline: nil,
            keystrokePlacement: .bottomCenter,
            subtitleTimeline: nil,
            subtitleStyle: SubtitleBarStyle(),
            canvasSize: CGSize(width: 160, height: 120),
            clipTimeline: shortTimeline,
            exportSettings: audioExportSettings,
            mediaDirectory: tempDir,
            redactions: [fullMask]
        )
        let shortExportedURL = try await RecordingStudioExporter().export(shortExportConfig) { _ in }
        defer { try? FileManager.default.removeItem(at: shortExportedURL) }
        let shortExportedAsset = AVURLAsset(url: shortExportedURL)
        let shortExportGen = AVAssetImageGenerator(asset: shortExportedAsset)
        shortExportGen.requestedTimeToleranceBefore = .zero
        shortExportGen.requestedTimeToleranceAfter = .zero
        for t in [0.55, 0.75, 0.90] {
            let img = try await shortExportGen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let score = detailScore(of: img)
            print(String(format: "r3_primary_short_picture EXPORT  (t=%.2fs) detail=%.2f", t, score))
            precondition(score < 1.0, "r3_primary_short_picture export leaked detail \(score) at t=\(t)")
        }
        let shortExportDuration = try await shortExportedAsset.load(.duration).seconds
        let rmsBefore = try await audioRMS(asset: shortExportedAsset, window: 0.05..<0.40)
        let rmsTone = try await audioRMS(asset: shortExportedAsset, window: 0.55..<0.70)
        let rmsAfter = try await audioRMS(asset: shortExportedAsset, window: 0.85..<2.50)
        print(String(format: "r3_primary_short_picture AUDIO duration=%.3fs rms_before=%.4f rms_tone=%.4f rms_after=%.4f",
                     shortExportDuration, rmsBefore, rmsTone, rmsAfter))
        precondition(shortExportDuration > 2.90, "Expected full ~2.98s exported duration, got \(shortExportDuration)")
        precondition(rmsBefore < 0.01, "Unexpected audio before tone window: \(rmsBefore)")
        precondition(rmsTone > 0.08, "Expected 880Hz tone at 0.55..0.70s, got \(rmsTone)")
        precondition(rmsAfter < 0.01, "Unexpected audio after tone window (drifted/stretched?): \(rmsAfter)")

        // Round 3 — Finding 9b: Multi-source timeline with imported clip whose video (1.00 s) is shorter than its audio (2.00 s).
        let shortPrimaryBaseURL = tempDir.appendingPathComponent("r3-ms-primary.mov")
        let shortImportURL = tempDir.appendingPathComponent("r3-ms-short-import.mov")
        try await writeTimedMovie(
            to: shortPrimaryBaseURL,
            size: CGSize(width: 160, height: 120),
            videoDuration: 1.0,
            audioDuration: 1.0,
            checkerWindow: 0.0..<0.0,
            backgroundColor: (220, 30, 30),
            toneWindow: 0.0..<0.0,
            toneHz: 440
        )
        try await writeTimedMovie(
            to: shortImportURL,
            size: CGSize(width: 160, height: 120),
            videoDuration: 1.0,
            audioDuration: 2.0,
            checkerWindow: 0.25..<0.50,
            backgroundColor: (30, 200, 60),
            toneWindow: 0.25..<0.50,
            toneHz: 880
        )
        let shortImportSource = try await StudioVideoSource.load(url: shortImportURL)
        let msShortTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0),
            RecordingClipSegment(
                sourceStart: 0,
                sourceEnd: shortImportSource.duration,
                mediaFileName: "r3-ms-short-import.mov",
                displayName: "Short Import",
                sourceDuration: shortImportSource.duration
            )
        ])
        let msExportConfig = RecordingStudioExporter.Configuration(
            screenURL: shortPrimaryBaseURL,
            cameraURL: nil,
            cameraOffset: 0,
            style: style,
            viewportTimeline: .identity,
            pointerTimeline: nil,
            showsPressEffects: false,
            keystrokeTimeline: nil,
            keystrokePlacement: .bottomCenter,
            subtitleTimeline: nil,
            subtitleStyle: SubtitleBarStyle(),
            canvasSize: CGSize(width: 160, height: 120),
            clipTimeline: msShortTimeline,
            exportSettings: audioExportSettings,
            mediaDirectory: tempDir,
            redactions: []
        )
        let msExportedURL = try await RecordingStudioExporter().export(msExportConfig) { _ in }
        defer { try? FileManager.default.removeItem(at: msExportedURL) }
        let msExportedAsset = AVURLAsset(url: msExportedURL)
        let msGen = AVAssetImageGenerator(asset: msExportedAsset)
        msGen.requestedTimeToleranceBefore = .zero
        msGen.requestedTimeToleranceAfter = .zero
        let msCheckerDetail = detailScore(of: try await msGen.image(at: CMTime(seconds: 1.35, preferredTimescale: 600)).image)
        let msGreenImg = try await msGen.image(at: CMTime(seconds: 1.75, preferredTimescale: 600)).image
        let msGreenDetail = detailScore(of: msGreenImg)
        let msTailImg = try await msGen.image(at: CMTime(seconds: 2.50, preferredTimescale: 600)).image
        let msTailDetail = detailScore(of: msTailImg)
        let msTailPx = centerRGB(of: msTailImg)
        let msToneRMS = try await audioRMS(asset: msExportedAsset, window: 1.30..<1.45)
        let msTailRMS = try await audioRMS(asset: msExportedAsset, window: 1.65..<2.80)
        print(String(format: "r3_multisource_short_import EXPORT checker@1.35=%.2f green@1.75=%.2f tail@2.50=%.2f tailRGB=(%d,%d,%d) rms_tone=%.4f rms_tail=%.4f",
                     msCheckerDetail, msGreenDetail, msTailDetail, msTailPx.0, msTailPx.1, msTailPx.2, msToneRMS, msTailRMS))
        precondition(msCheckerDetail > 30.0, "Expected unstretched checkerboard at 1.35s, got \(msCheckerDetail)")
        precondition(msGreenDetail < 2.0, "Expected flat green at 1.75s (no stretch), got \(msGreenDetail)")
        precondition(msTailDetail < 2.0 && msTailPx.0 < 20 && msTailPx.1 < 20 && msTailPx.2 < 20, "Expected black tail at 2.50s")
        precondition(msToneRMS > 0.08, "Expected imported 880Hz tone at 1.30..1.45s, got \(msToneRMS)")
        precondition(msTailRMS < 0.01, "Expected silence during imported tail, got \(msTailRMS)")

        print("ALL_EXPORT_AND_PREVIEW_CHECKS_PASSED")
    }

    static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        timeoutSeconds: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? NSError(domain: "CheckR2Export", code: 98)
            }
            if Date() >= deadline {
                throw NSError(
                    domain: "CheckR2Export",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for AVAssetWriterInput(\(input.mediaType.rawValue))"]
                )
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func writeTimedMovie(
        to url: URL,
        size: CGSize,
        videoDuration: TimeInterval,
        audioDuration: TimeInterval,
        checkerWindow: Range<TimeInterval>,
        backgroundColor: (UInt8, UInt8, UInt8),
        toneWindow: Range<TimeInterval>,
        toneHz: Double
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(videoInput)

        let sampleRate: Double = 44100
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc
        )

        let fps = 60
        let totalFrames = max(1, Int((videoDuration * Double(fps)).rounded()))
        let totalSamples = Int((audioDuration * sampleRate).rounded())
        let audioChunkSamples = 4410

        func appendAudioChunk(startSample: Int, count: Int) async throws {
            var pcm = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let sampleIdx = startSample + i
                let t = Double(sampleIdx) / sampleRate
                if toneWindow.contains(t) {
                    pcm[i] = Int16(sin(2.0 * .pi * toneHz * t) * 0.4 * Double(Int16.max))
                }
            }
            let dataSize = pcm.count * MemoryLayout<Int16>.size
            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: dataSize, flags: 0, blockBufferOut: &blockBuffer
            )
            let block = blockBuffer!
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)
                }
            }
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid
            )
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc,
                sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
            )
            try await waitUntilReady(audioInput, writer: writer)
            audioInput.append(sampleBuffer!)
        }

        var f = 0
        var audioCursor = 0
        var videoMarkedFinished = false
        var audioMarkedFinished = false
        let writeDeadline = Date().addingTimeInterval(10)

        while f < totalFrames || audioCursor < totalSamples {
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? NSError(domain: "CheckR2Export", code: 22)
            }
            if Date() >= writeDeadline {
                throw NSError(
                    domain: "CheckR2Export",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out writing timed movie (frame=\(f)/\(totalFrames), audio=\(audioCursor)/\(totalSamples))"]
                )
            }
            if f >= totalFrames && !videoMarkedFinished {
                videoInput.markAsFinished()
                videoMarkedFinished = true
            }
            if audioCursor >= totalSamples && !audioMarkedFinished {
                audioInput.markAsFinished()
                audioMarkedFinished = true
            }

            let videoReady = f < totalFrames && videoInput.isReadyForMoreMediaData
            let audioReady = audioCursor < totalSamples && audioInput.isReadyForMoreMediaData
            guard videoReady || audioReady else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }

            let videoTime = f < totalFrames ? Double(f) / Double(fps) : Double.infinity
            let audioTime = audioCursor < totalSamples ? Double(audioCursor) / sampleRate : Double.infinity

            if audioReady && (!videoReady || audioTime <= videoTime) {
                let count = min(audioChunkSamples, totalSamples - audioCursor)
                try await appendAudioChunk(startSample: audioCursor, count: count)
                audioCursor += count
            } else if videoReady {
                let isChecker = checkerWindow.contains(videoTime)
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
                let buf = pb!
                CVPixelBufferLockBaseAddress(buf, [])
                let base = CVPixelBufferGetBaseAddress(buf)!
                let bpr = CVPixelBufferGetBytesPerRow(buf)
                for y in 0..<Int(size.height) {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<Int(size.width) {
                        if isChecker {
                            let v: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 255 : 0
                            row[x * 4] = v; row[x * 4 + 1] = v; row[x * 4 + 2] = v
                        } else {
                            row[x * 4] = backgroundColor.2; row[x * 4 + 1] = backgroundColor.1; row[x * 4 + 2] = backgroundColor.0
                        }
                        row[x * 4 + 3] = 255
                    }
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
                f += 1
            }
        }
        if !videoMarkedFinished { videoInput.markAsFinished() }
        if !audioMarkedFinished { audioInput.markAsFinished() }
        await writer.finishWriting()
        precondition(writer.status == .completed, "writeTimedMovie failed: \(String(describing: writer.error))")
    }

    static func audioRMS(asset: AVAsset, window: Range<TimeInterval>) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 44100.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        precondition(reader.startReading(), "Audio reader failed to start: \(String(describing: reader.error))")
        var sumSq = 0.0
        var count = 0
        var sampleCursor = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let n = length / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: n)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &floats)
            for f in floats {
                let t = Double(sampleCursor) / sampleRate
                sampleCursor += 1
                if window.contains(t) {
                    sumSq += Double(f) * Double(f)
                    count += 1
                }
            }
        }
        return count > 0 ? sqrt(sumSq / Double(count)) : 0
    }

    static func centerRGB(of image: CGImage) -> (UInt8, UInt8, UInt8) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = ((h / 2) * w + (w / 2)) * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
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
