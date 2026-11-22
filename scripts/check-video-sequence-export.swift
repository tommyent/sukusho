import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

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

        // Round 4 — Test R4-1: PiP overlay spanning a cut between primary recording and an imported clip.
        let r4PrimaryURL = tempDir.appendingPathComponent("r4-pip-primary.mov")
        let r4ImportURL = tempDir.appendingPathComponent("r4-pip-import.mov")
        let r4PiPURL = tempDir.appendingPathComponent("r4-pip-overlay.mov")
        try await writeTimedMovie(
            to: r4PrimaryURL, size: CGSize(width: 160, height: 120),
            videoDuration: 1.0, audioDuration: 1.0,
            checkerWindow: 0.0..<0.0, backgroundColor: (220, 30, 30),
            toneWindow: 0.0..<0.0, toneHz: 440
        )
        try await writeTimedMovie(
            to: r4ImportURL, size: CGSize(width: 160, height: 120),
            videoDuration: 1.0, audioDuration: 1.0,
            checkerWindow: 0.0..<0.0, backgroundColor: (30, 200, 50),
            toneWindow: 0.0..<0.0, toneHz: 440
        )
        try await writeTimedMovie(
            to: r4PiPURL, size: CGSize(width: 160, height: 120),
            videoDuration: 1.0, audioDuration: 1.0,
            checkerWindow: 0.0..<0.0, backgroundColor: (30, 60, 230),
            toneWindow: 0.0..<1.0, toneHz: 880
        )
        var pipOverlay = RecordingVideoOverlay(
            fileName: "r4-pip-overlay.mov",
            displayName: "Blue PiP",
            start: 0.5,
            fileDuration: 1.0,
            presentation: .pip,
            isLinked: false
        )
        pipOverlay.center = CGPoint(x: 0.75, y: 0.75)
        pipOverlay.width = 0.40
        pipOverlay.aspect = 160.0 / 120.0
        pipOverlay.cornerRadius = 0
        pipOverlay.shadow = 0
        pipOverlay.isMuted = false
        pipOverlay.volume = 1.0

        let r4Timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0),
            RecordingClipSegment(
                sourceStart: 0, sourceEnd: 1.0,
                mediaFileName: "r4-pip-import.mov", displayName: "Green Import", sourceDuration: 1.0
            )
        ])
        let r4Config = RecordingStudioExporter.Configuration(
            screenURL: r4PrimaryURL,
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
            clipTimeline: r4Timeline,
            exportSettings: audioExportSettings,
            mediaDirectory: tempDir,
            videoOverlays: [pipOverlay]
        )
        let r4ExportedURL = try await RecordingStudioExporter().export(r4Config) { _ in }
        defer { try? FileManager.default.removeItem(at: r4ExportedURL) }
        let r4Asset = AVURLAsset(url: r4ExportedURL)
        let r4Gen = AVAssetImageGenerator(asset: r4Asset)
        r4Gen.requestedTimeToleranceBefore = .zero
        r4Gen.requestedTimeToleranceAfter = .zero
        let beforeCutImg = try await r4Gen.image(at: CMTime(seconds: 0.75, preferredTimescale: 600)).image
        let afterCutImg = try await r4Gen.image(at: CMTime(seconds: 1.25, preferredTimescale: 600)).image
        let bgBefore = pixelRGB(of: beforeCutImg, x: 20, y: 20)
        let pipBefore = pixelRGB(of: beforeCutImg, x: 120, y: 90)
        let bgAfter = pixelRGB(of: afterCutImg, x: 20, y: 20)
        let pipAfter = pixelRGB(of: afterCutImg, x: 120, y: 90)
        let pipAudioBefore = try await audioRMS(asset: r4Asset, window: 0.60..<0.90)
        let pipAudioAfter = try await audioRMS(asset: r4Asset, window: 1.10..<1.40)
        print(String(format: "r4_pip_across_cut beforeBG=(%d,%d,%d) beforePiP=(%d,%d,%d) afterBG=(%d,%d,%d) afterPiP=(%d,%d,%d) audioBefore=%.4f audioAfter=%.4f",
                     bgBefore.0, bgBefore.1, bgBefore.2, pipBefore.0, pipBefore.1, pipBefore.2,
                     bgAfter.0, bgAfter.1, bgAfter.2, pipAfter.0, pipAfter.1, pipAfter.2,
                     pipAudioBefore, pipAudioAfter))
        precondition(bgBefore.0 > 150 && bgBefore.2 < 120, "Expected red primary background before cut")
        precondition(pipBefore.2 > 150 && pipBefore.0 < 120, "Expected blue PiP over primary before cut")
        precondition(bgAfter.1 > 150 && bgAfter.0 < 120, "Expected green imported background after cut")
        precondition(pipAfter.2 > 150 && pipAfter.0 < 120, "Expected blue PiP over imported clip after cut")
        precondition(pipAudioBefore > 0.08 && pipAudioAfter > 0.08, "Expected PiP audio across cut")

        // Round 4 — Test R4-2: Close & reopen keeps one file of every media type, deletes orphans.
        let r4CleanupPkg = tempDir.appendingPathComponent("R4Cleanup.sukushorec", isDirectory: true)
        let r4CleanupMedia = r4CleanupPkg.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: r4CleanupMedia, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: r4CleanupPkg.appendingPathComponent("screen.mov"))
        let keptSeqName = "\(UUID().uuidString).mov"
        let keptOverlayName = "\(UUID().uuidString).mov"
        let keptImageName = "\(UUID().uuidString).png"
        let keptAudioName = "\(UUID().uuidString).mov"
        let orphanMovName = "\(UUID().uuidString).mov"
        let orphanPngName = "\(UUID().uuidString).png"
        try FileManager.default.copyItem(at: r4ImportURL, to: r4CleanupMedia.appendingPathComponent(keptSeqName))
        try FileManager.default.copyItem(at: r4PiPURL, to: r4CleanupMedia.appendingPathComponent(keptOverlayName))
        try FileManager.default.copyItem(at: r4PiPURL, to: r4CleanupMedia.appendingPathComponent(keptAudioName))
        try FileManager.default.copyItem(at: r4ImportURL, to: r4CleanupMedia.appendingPathComponent(orphanMovName))
        try writeSmallPNG(to: r4CleanupMedia.appendingPathComponent(keptImageName))
        try writeSmallPNG(to: r4CleanupMedia.appendingPathComponent(orphanPngName))

        let cleanupDoc = RecordingEditDocument(
            style: RecordingStudioStyle(),
            zoomEnabled: false,
            zoomCues: [],
            clipTimeline: RecordingClipTimeline(segments: [
                RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0),
                RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0, mediaFileName: keptSeqName, displayName: "Seq", sourceDuration: 1.0)
            ]),
            audioClips: [RecordingAudioClip(fileName: keptAudioName, displayName: "Audio", start: 0, fileDuration: 1.0)],
            imageOverlays: [RecordingImageOverlay(fileName: keptImageName, displayName: "Img", start: 0, end: 1.0)],
            videoOverlays: [RecordingVideoOverlay(fileName: keptOverlayName, displayName: "Ov", start: 0, fileDuration: 1.0)]
        )
        try RecordingSession(directoryURL: r4CleanupPkg).writeEditDocument(cleanupDoc)

        let cleanupModel1 = await MainActor.run { RecordingStudioModel(url: r4CleanupPkg) }
        await cleanupModel1.load()
        await MainActor.run { cleanupModel1.teardown() }

        for kept in [keptSeqName, keptOverlayName, keptImageName, keptAudioName] {
            precondition(FileManager.default.fileExists(atPath: r4CleanupMedia.appendingPathComponent(kept).path),
                         "Unified cleanup deleted still-referenced media \(kept)")
        }
        precondition(!FileManager.default.fileExists(atPath: r4CleanupMedia.appendingPathComponent(orphanMovName).path),
                     "Unified cleanup missed orphan movie")
        precondition(!FileManager.default.fileExists(atPath: r4CleanupMedia.appendingPathComponent(orphanPngName).path),
                     "Unified cleanup missed orphan image")

        let cleanupModel2 = await MainActor.run { RecordingStudioModel(url: r4CleanupPkg) }
        await cleanupModel2.load()
        let reopenCounts = await MainActor.run {
            (cleanupModel2.clipTimeline.segments.count, cleanupModel2.videoOverlays.count,
             cleanupModel2.imageOverlays.count, cleanupModel2.audioClips.count)
        }
        await MainActor.run { cleanupModel2.teardown() }
        precondition(reopenCounts == (2, 1, 1, 1), "Reopen lost references: \(reopenCounts)")
        print("r4_unified_cleanup_close_reopen PASSED counts=\(reopenCounts)")

        // Round 4 — Test R4-3: Raw recording keeps redactions in BOTH sequence and layered lanes.
        let pkgA = tempDir.appendingPathComponent("R4HostA.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgA, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgA.appendingPathComponent("screen.mov"))

        // B1: full checkerboard + 880 Hz tone, left-half redaction mask saved in edit.json
        let pkgB1 = tempDir.appendingPathComponent("R4RedactedB1.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgB1, withIntermediateDirectories: true)
        try await writeTimedMovie(
            to: pkgB1.appendingPathComponent("screen.mov"),
            size: CGSize(width: 160, height: 120),
            videoDuration: 1.0, audioDuration: 1.0,
            checkerWindow: 0.0..<1.0, backgroundColor: (128, 128, 128),
            toneWindow: 0.2..<0.8, toneHz: 880
        )
        let leftHalfMask = RecordingRedaction(
            start: 0.0, end: 1.0,
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 1.0),
            mode: .pixelate, strength: 1.0
        )
        let b1Doc = RecordingEditDocument(
            style: RecordingStudioStyle(background: .none, padding: 80, cornerRadius: 24, shadow: 1),
            zoomEnabled: true,
            zoomCues: [ZoomCue(start: 0, end: 1, zoom: 2.5)],
            redactions: [leftHalfMask]
        )
        try RecordingSession(directoryURL: pkgB1).writeEditDocument(b1Doc)

        // B2: unredacted recording (must copy screen.mov byte-for-byte)
        let pkgB2 = tempDir.appendingPathComponent("R4PlainB2.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgB2, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4ImportURL, to: pkgB2.appendingPathComponent("screen.mov"))
        let b2OriginalBytes = try Data(contentsOf: pkgB2.appendingPathComponent("screen.mov"))

        // B3: unreadable edit.json (must be refused in both lanes)
        let pkgB3 = tempDir.appendingPathComponent("R4CorruptB3.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgB3, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4ImportURL, to: pkgB3.appendingPathComponent("screen.mov"))
        try Data("{ corrupt json".utf8).write(to: pkgB3.appendingPathComponent("edit.json"))

        let hostModel = await MainActor.run { RecordingStudioModel(url: pkgA) }
        await hostModel.load()

        // Sequence lane — B1 (redacted raw), B2 (byte-identical raw), B3 (refused)
        await MainActor.run {
            hostModel.requestImportVideoClips([pkgB1], insertionIndex: 1)
            precondition(hostModel.pendingRecordingImport != nil, "Expected sequence prompt for B1")
            hostModel.confirmPendingRecordingImport(mode: .rawRecording)
        }
        try await waitUntil(timeoutSeconds: 20) {
            await MainActor.run { !hostModel.isImportingVideoClip && hostModel.clipTimeline.segments.count == 2 }
        }
        let seqB1File = await MainActor.run { hostModel.clipTimeline.segments[1].mediaFileName! }
        let seqB1URL = pkgA.appendingPathComponent("media/\(seqB1File)")
        let seqB1Asset = AVURLAsset(url: seqB1URL)
        let seqB1Gen = AVAssetImageGenerator(asset: seqB1Asset)
        seqB1Gen.requestedTimeToleranceBefore = .zero
        seqB1Gen.requestedTimeToleranceAfter = .zero
        let seqB1Img = try await seqB1Gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let seqLeftDetail = regionDetailScore(of: seqB1Img, xRange: 4..<70, yRange: 4..<116)
        let seqRightDetail = regionDetailScore(of: seqB1Img, xRange: 90..<156, yRange: 4..<116)
        let seqB1Audio = try await audioRMS(asset: seqB1Asset, window: 0.3..<0.7)
        print(String(format: "r4_raw_sequence_B1 leftMasked=%.2f rightUnmasked=%.2f audioRMS=%.4f size=%dx%d",
                     seqLeftDetail, seqRightDetail, seqB1Audio, seqB1Img.width, seqB1Img.height))
        precondition(seqLeftDetail < 1.0, "Sequence Raw leaked masked left half: \(seqLeftDetail)")
        precondition(seqRightDetail > 40.0, "Sequence Raw lost unmasked right half detail: \(seqRightDetail)")
        precondition(seqB1Audio > 0.08, "Sequence Raw dropped original audio: \(seqB1Audio)")
        precondition(seqB1Img.width == 160 && seqB1Img.height == 120, "Sequence Raw changed original size")

        await MainActor.run {
            hostModel.requestImportVideoClips([pkgB2], insertionIndex: 2)
            hostModel.confirmPendingRecordingImport(mode: .rawRecording)
        }
        try await waitUntil(timeoutSeconds: 10) {
            await MainActor.run { !hostModel.isImportingVideoClip && hostModel.clipTimeline.segments.count == 3 }
        }
        let seqB2File = await MainActor.run { hostModel.clipTimeline.segments[2].mediaFileName! }
        let seqB2Bytes = try Data(contentsOf: pkgA.appendingPathComponent("media/\(seqB2File)"))
        precondition(seqB2Bytes == b2OriginalBytes, "Sequence Raw without redactions was not byte-identical")

        await MainActor.run {
            hostModel.requestImportVideoClips([pkgB3], insertionIndex: 3)
            precondition(hostModel.pendingRecordingImport == nil, "Sequence Raw should refuse corrupt B3")
            precondition(hostModel.mediaImportError != nil, "Expected error on corrupt B3 in sequence lane")
        }

        // Layered lane — B1 (redacted raw), B2 (byte-identical raw), B3 (refused)
        await MainActor.run {
            hostModel.importVideoOverlays([pkgB1], atEditorTime: 0)
            precondition(hostModel.pendingRecordingOverlayImport != nil, "Expected layered prompt for B1")
            hostModel.resolvePendingRecordingImport(mode: .raw)
        }
        try await waitUntil(timeoutSeconds: 20) {
            await MainActor.run { hostModel.videoOverlays.count == 1 }
        }
        let layB1File = await MainActor.run { hostModel.videoOverlays[0].fileName }
        let layB1URL = pkgA.appendingPathComponent("media/\(layB1File)")
        let layB1Asset = AVURLAsset(url: layB1URL)
        let layB1Gen = AVAssetImageGenerator(asset: layB1Asset)
        layB1Gen.requestedTimeToleranceBefore = .zero
        layB1Gen.requestedTimeToleranceAfter = .zero
        let layB1Img = try await layB1Gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let layLeftDetail = regionDetailScore(of: layB1Img, xRange: 4..<70, yRange: 4..<116)
        let layRightDetail = regionDetailScore(of: layB1Img, xRange: 90..<156, yRange: 4..<116)
        let layB1Audio = try await audioRMS(asset: layB1Asset, window: 0.3..<0.7)
        print(String(format: "r4_raw_layered_B1  leftMasked=%.2f rightUnmasked=%.2f audioRMS=%.4f size=%dx%d",
                     layLeftDetail, layRightDetail, layB1Audio, layB1Img.width, layB1Img.height))
        precondition(layLeftDetail < 1.0, "Layered Raw leaked masked left half: \(layLeftDetail)")
        precondition(layRightDetail > 40.0, "Layered Raw lost unmasked right half detail: \(layRightDetail)")
        precondition(layB1Audio > 0.08, "Layered Raw dropped original audio: \(layB1Audio)")

        await MainActor.run {
            hostModel.importVideoOverlays([pkgB2], atEditorTime: 1.5)
            hostModel.resolvePendingRecordingImport(mode: .raw)
        }
        try await waitUntil(timeoutSeconds: 10) {
            await MainActor.run { hostModel.videoOverlays.count == 2 }
        }
        let layB2File = await MainActor.run { hostModel.videoOverlays[1].fileName }
        let layB2Bytes = try Data(contentsOf: pkgA.appendingPathComponent("media/\(layB2File)"))
        precondition(layB2Bytes == b2OriginalBytes, "Layered Raw without redactions was not byte-identical")

        await MainActor.run {
            hostModel.importVideoOverlays([pkgB3], atEditorTime: 2.5)
            precondition(hostModel.pendingRecordingOverlayImport == nil, "Layered Raw should refuse corrupt B3")
            precondition(hostModel.mediaImportError != nil, "Expected error on corrupt B3 in layered lane")
            hostModel.teardown()
        }
        print("r4_raw_redactions_both_lanes PASSED")

        // Round 4 — Test R4-4: formatVersion 99 opens read-only, writes nothing, blocks Finished render.
        let pkgFuture = tempDir.appendingPathComponent("R4Future99.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgFuture, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgFuture.appendingPathComponent("screen.mov"))
        var futureDoc = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [])
        futureDoc.formatVersion = 99
        let futureEditURL = pkgFuture.appendingPathComponent("edit.json")
        let futureDraftURL = pkgFuture.appendingPathComponent("edit.draft.json")
        try CaptureManifest.encoder.encode(futureDoc).write(to: futureEditURL)
        let futureBytesBefore = try Data(contentsOf: futureEditURL)

        let futureModel = await MainActor.run { RecordingStudioModel(url: pkgFuture) }
        await futureModel.load()
        await MainActor.run {
            precondition(futureModel.isLoaded, "formatVersion 99 should still open read-only")
            precondition(futureModel.isReadOnlyNewerFormat, "Expected isReadOnlyNewerFormat == true")
            precondition(!futureModel.canImportVideoClip && !futureModel.canImportMedia, "Imports must be off for read-only future project")
            futureModel.zoomEnabled = true
            let saved = futureModel.saveProject(reportingFailure: false)
            precondition(!saved, "saveProject must refuse formatVersion 99")
            futureModel.flushDraft()
            futureModel.autosave()
            futureModel.teardown()
        }
        let futureBytesAfter = try Data(contentsOf: futureEditURL)
        precondition(futureBytesAfter == futureBytesBefore, "formatVersion 99 edit.json was modified!")
        precondition(!FileManager.default.fileExists(atPath: futureDraftURL.path), "formatVersion 99 wrote edit.draft.json!")
        do {
            _ = try await RecordingSessionRenderer.ensureDeliverable(for: RecordingSession(directoryURL: pkgFuture))
            preconditionFailure("Finished render must refuse formatVersion 99")
        } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
            print("r4_format99_readonly_and_render_guard PASSED")
        }

        print("ALL_EXPORT_AND_PREVIEW_CHECKS_PASSED")
    }

    static func waitUntil(timeoutSeconds: TimeInterval, condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !(await condition()) {
            if Date() >= deadline {
                throw NSError(domain: "CheckR2Export", code: 100, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for async condition"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func writeSmallPNG(to url: URL) throws {
        var pixel: [UInt8] = [200, 50, 50, 255]
        let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        precondition(CGImageDestinationFinalize(dest))
    }

    static func pixelRGB(of image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = min(max(x, 0), w - 1)
        let cy = min(max(y, 0), h - 1)
        let o = (cy * w + cx) * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    static func regionDetailScore(of image: CGImage, xRange: Range<Int>, yRange: Range<Int>) -> Double {
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
        for y in max(1, yRange.lowerBound)..<min(h - 1, yRange.upperBound) {
            for x in max(1, xRange.lowerBound)..<min(w - 1, xRange.upperBound) {
                let c = luma(x, y)
                sum += abs(c - luma(x + 1, y)) + abs(c - luma(x, y + 1))
                count += 2
            }
        }
        return sum / Double(max(1, count))
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
