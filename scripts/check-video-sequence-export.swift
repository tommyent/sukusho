import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
#if HARNESS_LINKED_MODULE
@testable import Screendrop
#endif

@main
struct CheckR2Export {
    static func main() async throws {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        precondition(
            homePath.hasPrefix("/private/tmp/") || homePath.hasPrefix("/tmp/"),
            "Harness must run in an isolated temp HOME under /tmp/ or /private/tmp/, got \(homePath)"
        )
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

        // Round 5 — R5-1 (Finding 11): 90°-rotated asymmetric screen.mov redaction
        // in BOTH Raw import AND normal single-source RecordingStudioExporter, plus
        // unmasked-side control and fail-closed unsupported 30° transform.
        let rotatedURL = tempDir.appendingPathComponent("r5-rotated-90-asym.mov")
        // Coded 384x216 rotated +90° clockwise => displayed 216x384.
        // Coded bottom half (cy >= 108) maps to display LEFT half (x' in 0..<108).
        // Coded top half (cy < 108) maps to display RIGHT half (x' in 108..<216).
        try await writeRotatedAsymmetricMovie(
            to: rotatedURL,
            codedSize: CGSize(width: 384, height: 216),
            duration: 1.0,
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2),
            checkerInBottomCodedHalf: true
        )
        // Self-verify raw oriented frame before masking: 216x384, checkerboard ONLY on display left.
        let rotatedRawGen = AVAssetImageGenerator(asset: AVURLAsset(url: rotatedURL))
        rotatedRawGen.appliesPreferredTrackTransform = true
        rotatedRawGen.requestedTimeToleranceBefore = .zero
        rotatedRawGen.requestedTimeToleranceAfter = .zero
        let rotatedRawImg = try await rotatedRawGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let rawRotLeft = regionDetailScore(of: rotatedRawImg, xRange: 8..<100, yRange: 8..<376)
        let rawRotRight = regionDetailScore(of: rotatedRawImg, xRange: 116..<208, yRange: 8..<376)
        print(String(format: "r5_rotated_raw size=%dx%d leftDetail=%.2f rightDetail=%.2f",
                     rotatedRawImg.width, rotatedRawImg.height, rawRotLeft, rawRotRight))
        precondition(rotatedRawImg.width == 216 && rotatedRawImg.height == 384,
                     "Expected 216x384 oriented frame, got \(rotatedRawImg.width)x\(rotatedRawImg.height)")
        precondition(rawRotLeft > 50.0, "Expected high checkerboard on display left, got \(rawRotLeft)")
        precondition(rawRotRight < 1.0, "Expected flat grey on display right, got \(rawRotRight)")

        // R5-1a: Raw import of rotated screen.mov with left-half mask (protects checkerboard).
        let pkgRotRaw = tempDir.appendingPathComponent("R5RotatedRaw.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgRotRaw, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rotatedURL, to: pkgRotRaw.appendingPathComponent("screen.mov"))
        let rotLeftMask = RecordingRedaction(
            start: 0.0, end: 1.0,
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 1.0),
            mode: .pixelate, strength: 1.0
        )
        try RecordingSession(directoryURL: pkgRotRaw).writeEditDocument(
            RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], redactions: [rotLeftMask])
        )
        let preparedRotRaw = try await RecordingSessionRenderer.prepareRawImport(for: pkgRotRaw)
        defer { if preparedRotRaw.isTemporary { try? FileManager.default.removeItem(at: preparedRotRaw.url) } }
        let rotRawGen = AVAssetImageGenerator(asset: AVURLAsset(url: preparedRotRaw.url))
        rotRawGen.appliesPreferredTrackTransform = true
        rotRawGen.requestedTimeToleranceBefore = .zero
        rotRawGen.requestedTimeToleranceAfter = .zero
        let rotRawImg = try await rotRawGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let rotRawLeft = regionDetailScore(of: rotRawImg, xRange: 8..<100, yRange: 8..<376)
        let rotRawRight = regionDetailScore(of: rotRawImg, xRange: 116..<208, yRange: 8..<376)
        print(String(format: "r5_rotated_raw_import size=%dx%d leftDetail=%.2f rightDetail=%.2f",
                     rotRawImg.width, rotRawImg.height, rotRawLeft, rotRawRight))
        precondition(rotRawImg.width == 216 && rotRawImg.height == 384,
                     "Expected 216x384 Raw import output, got \(rotRawImg.width)x\(rotRawImg.height)")
        precondition(rotRawLeft < 1.0 && rotRawRight < 1.0,
                     "Rotated Raw import leaked protected pixels (left=\(rotRawLeft), right=\(rotRawRight))")

        // R5-1b: Normal single-source RecordingStudioExporter on the same rotated screen.mov.
        let rotSingleConfig = RecordingStudioExporter.Configuration(
            screenURL: rotatedURL,
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
            canvasSize: CGSize(width: 216, height: 384),
            clipTimeline: .full(sourceDuration: 1.0),
            exportSettings: exportSettings,
            redactions: [rotLeftMask]
        )
        let rotSingleURL = try await RecordingStudioExporter().export(rotSingleConfig) { _ in }
        defer { try? FileManager.default.removeItem(at: rotSingleURL) }
        let rotSingleGen = AVAssetImageGenerator(asset: AVURLAsset(url: rotSingleURL))
        rotSingleGen.appliesPreferredTrackTransform = true
        rotSingleGen.requestedTimeToleranceBefore = .zero
        rotSingleGen.requestedTimeToleranceAfter = .zero
        let rotSingleImg = try await rotSingleGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let rotSingleLeft = regionDetailScore(of: rotSingleImg, xRange: 8..<100, yRange: 8..<376)
        let rotSingleRight = regionDetailScore(of: rotSingleImg, xRange: 116..<208, yRange: 8..<376)
        print(String(format: "r5_rotated_normal_export size=%dx%d leftDetail=%.2f rightDetail=%.2f",
                     rotSingleImg.width, rotSingleImg.height, rotSingleLeft, rotSingleRight))
        precondition(rotSingleImg.width == 216 && rotSingleImg.height == 384,
                     "Expected 216x384 normal export output, got \(rotSingleImg.width)x\(rotSingleImg.height)")
        precondition(rotSingleLeft < 1.0 && rotSingleRight < 1.0,
                     "Rotated normal single-source export leaked protected pixels (left=\(rotSingleLeft), right=\(rotSingleRight))")

        // R5-1c: Control — mask ONLY the right half so the left checkerboard MUST survive.
        let rotRightMask = RecordingRedaction(
            start: 0.0, end: 1.0,
            rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0),
            mode: .pixelate, strength: 1.0
        )
        let rotControlConfig = RecordingStudioExporter.Configuration(
            screenURL: rotatedURL,
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
            canvasSize: CGSize(width: 216, height: 384),
            clipTimeline: .full(sourceDuration: 1.0),
            exportSettings: exportSettings,
            redactions: [rotRightMask]
        )
        let rotControlURL = try await RecordingStudioExporter().export(rotControlConfig) { _ in }
        defer { try? FileManager.default.removeItem(at: rotControlURL) }
        let rotControlGen = AVAssetImageGenerator(asset: AVURLAsset(url: rotControlURL))
        rotControlGen.appliesPreferredTrackTransform = true
        rotControlGen.requestedTimeToleranceBefore = .zero
        rotControlGen.requestedTimeToleranceAfter = .zero
        let rotControlImg = try await rotControlGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let rotControlLeft = regionDetailScore(of: rotControlImg, xRange: 8..<100, yRange: 8..<376)
        precondition(rotControlLeft > 40.0,
                     "Rotated right-mask control unexpectedly masked unmasked left half (\(rotControlLeft))")

        // R5-1d: Unsupported oblique transform (30°) must fail closed in both Raw import & normal export.
        let obliqueURL = tempDir.appendingPathComponent("r5-oblique-30.mov")
        try await writeRotatedAsymmetricMovie(
            to: obliqueURL,
            codedSize: CGSize(width: 160, height: 120),
            duration: 0.5,
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 6),
            checkerInBottomCodedHalf: true
        )
        let pkgOblique = tempDir.appendingPathComponent("R5Oblique.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgOblique, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: obliqueURL, to: pkgOblique.appendingPathComponent("screen.mov"))
        try RecordingSession(directoryURL: pkgOblique).writeEditDocument(
            RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], redactions: [rotLeftMask])
        )
        var rawObliqueFailed = false
        do {
            let bad = try await RecordingSessionRenderer.prepareRawImport(for: pkgOblique)
            if bad.isTemporary { try? FileManager.default.removeItem(at: bad.url) }
        } catch {
            rawObliqueFailed = true
        }
        precondition(rawObliqueFailed, "Raw import must fail closed on unsupported 30° transform")

        var exportObliqueFailed = false
        let obliqueConfig = RecordingStudioExporter.Configuration(
            screenURL: obliqueURL,
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
            canvasSize: CGSize(width: 216, height: 384),
            clipTimeline: .full(sourceDuration: 0.5),
            exportSettings: exportSettings,
            redactions: [rotLeftMask]
        )
        do {
            let bad = try await RecordingStudioExporter().export(obliqueConfig) { _ in }
            try? FileManager.default.removeItem(at: bad)
        } catch {
            exportObliqueFailed = true
        }
        precondition(exportObliqueFailed, "Normal exporter must fail closed on unsupported 30° transform")
        print("r5_rotated_redactions_and_fail_closed PASSED")

        // Round 5 — R5-2 (Finding 12): Future-format guard (version-only header, zero metadata
        // rewrite, zero Discard on newer draft with unknown enum case, direct export blocked).
        let pkgFutureMeta = tempDir.appendingPathComponent("R5FutureMeta.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgFutureMeta, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgFutureMeta.appendingPathComponent("screen.mov"))
        let futureMetaJSON = Data(#"{"customName":"Keep Title","futureMeta":"preserve-me"}"#.utf8)
        let futureMetaURL = pkgFutureMeta.appendingPathComponent("project.json")
        try futureMetaJSON.write(to: futureMetaURL)
        try CaptureManifest.encoder.encode(futureDoc).write(to: pkgFutureMeta.appendingPathComponent("edit.json"))
        let futureMetaEditBefore = try Data(contentsOf: pkgFutureMeta.appendingPathComponent("edit.json"))

        let futureMetaModel = await MainActor.run { RecordingStudioModel(url: pkgFutureMeta) }
        await futureMetaModel.load()
        await MainActor.run {
            precondition(futureMetaModel.isLoaded, "Compatible format-99 project should open read-only")
            precondition(futureMetaModel.isReadOnlyNewerFormat, "Expected isReadOnlyNewerFormat == true")
            precondition(!futureMetaModel.hasUnreadableDraft, "Expected hasUnreadableDraft == false")
            futureMetaModel.rename(to: "ShouldNotOverwrite")
            futureMetaModel.setSummary("ShouldNotWriteSummary")
            futureMetaModel.addChapterAtPlayhead()
            precondition(!futureMetaModel.saveProject(reportingFailure: false), "saveProject must fail for read-only future project")
            futureMetaModel.flushDraft()
            futureMetaModel.export()
            futureMetaModel.exportAudio()
            futureMetaModel.exportGuide()
            futureMetaModel.exportAgentPrompt()
            do {
                _ = try futureMetaModel.makeExportConfiguration()
                preconditionFailure("makeExportConfiguration must throw unsupportedFormatVersion for read-only future project")
            } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
                // Expected
            } catch {
                preconditionFailure("Unexpected error from makeExportConfiguration: \(error)")
            }
            futureMetaModel.teardown()
        }
        let futureMetaAfter = try Data(contentsOf: futureMetaURL)
        let futureMetaEditAfter = try Data(contentsOf: pkgFutureMeta.appendingPathComponent("edit.json"))
        precondition(futureMetaAfter == futureMetaJSON,
                     "Opening read-only format-99 project modified project.json or dropped unknown keys!")
        precondition(futureMetaEditAfter == futureMetaEditBefore,
                     "Opening read-only format-99 project modified edit.json!")
        precondition(!FileManager.default.fileExists(atPath: pkgFutureMeta.appendingPathComponent("edit.draft.json").path),
                     "Opening read-only format-99 project wrote edit.draft.json!")

        // R5-2b: Newer format-99 draft with an unknown enum case over a valid format-7 saved edit.
        let pkgNewerDraft = tempDir.appendingPathComponent("R5NewerDraftUnknownEnum.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgNewerDraft, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgNewerDraft.appendingPathComponent("screen.mov"))
        let savedV7Doc = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [])
        try RecordingSession(directoryURL: pkgNewerDraft).writeEditDocument(savedV7Doc)
        let savedV7BytesBefore = try Data(contentsOf: pkgNewerDraft.appendingPathComponent("edit.json"))
        let unknownEnumDraft = Data("""
        {
          "formatVersion": 99,
          "redactions": [{ "mode": "mosaic_v2", "start": 0.0, "end": 1.0, "rect": [[0, 0], [1, 1]] }]
        }
        """.utf8)
        let unknownEnumDraftURL = pkgNewerDraft.appendingPathComponent("edit.draft.json")
        try unknownEnumDraft.write(to: unknownEnumDraftURL)
        try futureMetaJSON.write(to: pkgNewerDraft.appendingPathComponent("project.json"))

        let newerDraftModel = await MainActor.run { RecordingStudioModel(url: pkgNewerDraft) }
        await newerDraftModel.load()
        await MainActor.run {
            precondition(newerDraftModel.isLoaded, "Project with format-99 unknown-enum draft should open read-only")
            precondition(newerDraftModel.isReadOnlyNewerFormat, "Expected isReadOnlyNewerFormat == true for newer draft")
            precondition(!newerDraftModel.hasUnreadableDraft, "Newer draft must NOT trigger hasUnreadableDraft / Discard")
            newerDraftModel.discardUnreadableDraft()
            do {
                _ = try newerDraftModel.makeExportConfiguration()
                preconditionFailure("makeExportConfiguration must throw unsupportedFormatVersion(99) for newer draft")
            } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
                // Expected
            } catch {
                preconditionFailure("Unexpected error: \(error)")
            }
            newerDraftModel.teardown()
        }
        let unknownDraftAfter = try Data(contentsOf: unknownEnumDraftURL)
        let savedV7BytesAfter = try Data(contentsOf: pkgNewerDraft.appendingPathComponent("edit.json"))
        let newerDraftMetaAfter = try Data(contentsOf: pkgNewerDraft.appendingPathComponent("project.json"))
        precondition(unknownDraftAfter == unknownEnumDraft,
                     "Newer format-99 draft was modified or discarded!")
        precondition(savedV7BytesAfter == savedV7BytesBefore,
                     "Saved edit.json was modified under newer draft!")
        precondition(newerDraftMetaAfter == futureMetaJSON,
                     "project.json was modified under newer draft!")
        print("r5_future_format_header_and_zero_writes PASSED")

        // Round 5 — R5-3 (Finding 13): Writable format-7 project with a format-99 snapshot
        // referencing media in unknown fields — cleanup must NOT delete either media/ or
        // package-root files, and snapshot restore must refuse format-99.
        let pkgFutureSnap = tempDir.appendingPathComponent("R5FutureSnapshot.sukushorec", isDirectory: true)
        let snapMediaDir = pkgFutureSnap.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: snapMediaDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgFutureSnap.appendingPathComponent("screen.mov"))
        let snapReferencedMov = "\(UUID().uuidString).mov"
        let snapReferencedAudio = "\(RecordingSession.replacementAudioBaseName).\(UUID().uuidString).m4a"
        try FileManager.default.copyItem(at: r4ImportURL, to: snapMediaDir.appendingPathComponent(snapReferencedMov))
        try Data("stub-audio".utf8).write(to: pkgFutureSnap.appendingPathComponent(snapReferencedAudio))
        let snapSession = RecordingSession(directoryURL: pkgFutureSnap)
        try snapSession.writeEditDocument(savedV7Doc)
        let futureSnapJSON = Data("""
        {
          "formatVersion": 99,
          "futureClip": "\(snapReferencedMov)",
          "futureAudio": "\(snapReferencedAudio)"
        }
        """.utf8)
        _ = try CaptureSessionSnapshots(directory: snapSession.sessionSnapshotsURL).keep(
            document: futureSnapJSON,
            openedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let snapModel = await MainActor.run { RecordingStudioModel(url: pkgFutureSnap) }
        await snapModel.load()
        await MainActor.run {
            precondition(snapModel.isLoaded && !snapModel.isReadOnlyNewerFormat,
                         "Format-7 project with format-99 snapshot should open writable")
            do {
                _ = try RecordingSession.decodeRestorableSnapshot(futureSnapJSON)
                preconditionFailure("decodeRestorableSnapshot must refuse format-99 snapshot")
            } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
                // Expected
            } catch {
                preconditionFailure("Unexpected error from decodeRestorableSnapshot: \(error)")
            }
            snapModel.teardown()
        }
        precondition(FileManager.default.fileExists(atPath: snapMediaDir.appendingPathComponent(snapReferencedMov).path),
                     "Cleanup deleted media/ file owned by format-99 snapshot!")
        precondition(FileManager.default.fileExists(atPath: pkgFutureSnap.appendingPathComponent(snapReferencedAudio).path),
                     "Cleanup deleted package-root replacement audio owned by format-99 snapshot!")
        print("r5_future_snapshot_cleanup_and_revert_guard PASSED")

        // Round 5 — R5-4 (Finding 14): Raw import with redactions preserves multiple separate
        // original audio tracks without remixing or re-encoding.
        let pkgMultiAudio = tempDir.appendingPathComponent("R5MultiAudioRaw.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgMultiAudio, withIntermediateDirectories: true)
        let multiAudioScreenURL = pkgMultiAudio.appendingPathComponent("screen.mov")
        try await writeMultiAudioCheckerboardMovie(
            to: multiAudioScreenURL,
            size: CGSize(width: 160, height: 120),
            duration: 1.0,
            track1ToneHz: 440,
            track2ToneHz: 880
        )
        let srcAudioTracks = try await AVURLAsset(url: multiAudioScreenURL).loadTracks(withMediaType: .audio)
        precondition(srcAudioTracks.count == 2, "Expected 2 source audio tracks, got \(srcAudioTracks.count)")
        try RecordingSession(directoryURL: pkgMultiAudio).writeEditDocument(
            RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], redactions: [leftHalfMask])
        )
        let preparedMultiAudio = try await RecordingSessionRenderer.prepareRawImport(for: pkgMultiAudio)
        defer { if preparedMultiAudio.isTemporary { try? FileManager.default.removeItem(at: preparedMultiAudio.url) } }
        let outMultiAsset = AVURLAsset(url: preparedMultiAudio.url)
        let outAudioTracks = try await outMultiAsset.loadTracks(withMediaType: .audio)
        precondition(outAudioTracks.count == 2, "Raw import with redactions flattened audio tracks: expected 2, got \(outAudioTracks.count)")
        let outTrack1RMS = try await audioRMS(asset: outMultiAsset, track: outAudioTracks[0], window: 0.2..<0.8)
        let outTrack2RMS = try await audioRMS(asset: outMultiAsset, track: outAudioTracks[1], window: 0.2..<0.8)
        let outMultiGen = AVAssetImageGenerator(asset: outMultiAsset)
        outMultiGen.requestedTimeToleranceBefore = .zero
        outMultiGen.requestedTimeToleranceAfter = .zero
        let outMultiImg = try await outMultiGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let outMultiLeft = regionDetailScore(of: outMultiImg, xRange: 4..<70, yRange: 4..<116)
        let outMultiRight = regionDetailScore(of: outMultiImg, xRange: 90..<156, yRange: 4..<116)
        print(String(format: "r5_raw_multiaudio tracks=%d track1RMS=%.4f track2RMS=%.4f leftMasked=%.2f rightUnmasked=%.2f",
                     outAudioTracks.count, outTrack1RMS, outTrack2RMS, outMultiLeft, outMultiRight))
        precondition(outTrack1RMS > 0.08 && outTrack2RMS > 0.08,
                     "Expected both preserved audio tracks to be audible (t1=\(outTrack1RMS), t2=\(outTrack2RMS))")
        precondition(outMultiLeft < 1.0 && outMultiRight > 40.0,
                     "Multi-audio Raw import redaction mismatch (left=\(outMultiLeft), right=\(outMultiRight))")
        print("r5_raw_multiaudio_preservation PASSED")

        // Round 6 — R6-1 (Finding 17): Newer-format draft that cannot decode must withhold
        // playback, posters, and filmstrip rather than ever loading the unredacted master.
        let pkgWithheld = tempDir.appendingPathComponent("R6WithheldPreview.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgWithheld, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: primaryURL, to: pkgWithheld.appendingPathComponent("screen.mov"))
        let fullBlurMask = RecordingRedaction(
            start: 0.0, end: 2.0,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            mode: .blur, strength: 1.0
        )
        try RecordingSession(directoryURL: pkgWithheld).writeEditDocument(
            RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], redactions: [fullBlurMask])
        )
        let undecodableFutureDraft = Data("""
        {
          "formatVersion": 99,
          "redactions": [{ "mode": "mosaic_v2", "start": 0.0, "end": 2.0, "rect": [[0, 0], [1, 1]] }]
        }
        """.utf8)
        try undecodableFutureDraft.write(to: pkgWithheld.appendingPathComponent("edit.draft.json"))

        let withheldModel = await MainActor.run { RecordingStudioModel(url: pkgWithheld) }
        await withheldModel.load()
        await MainActor.run {
            precondition(withheldModel.isLoaded, "Undecodable newer-format draft should open with read-only notice")
            precondition(withheldModel.isReadOnlyNewerFormat, "Expected isReadOnlyNewerFormat == true")
            precondition(withheldModel.withholdsNewerFormatPreview, "Expected withholdsNewerFormatPreview == true")
            precondition(!withheldModel.hasUnreadableDraft, "Newer-format draft must not trigger Discard")
            precondition(withheldModel.screenPlayer.currentItem == nil,
                         "Raw master reached screenPlayer.currentItem under undecodable newer draft!")
            precondition(withheldModel.cameraPlayer.currentItem == nil,
                         "cameraPlayer.currentItem must be withheld under undecodable newer draft")
            precondition(withheldModel.stylePoster == nil,
                         "stylePoster must be withheld under undecodable newer draft")
            precondition(withheldModel.redactionPreviewError == RecordingEditDocument.newerFormatNotice,
                         "Expected newerFormatNotice on redactionPreviewError")
            withheldModel.play()
            precondition(!withheldModel.isPlaying && withheldModel.screenPlayer.currentItem == nil,
                         "Playback must remain withheld under undecodable newer draft")
            withheldModel.teardown()
        }
        print("r6_newer_draft_withholds_raw_preview PASSED")

        // Round 6 — R6-2 (Finding 18): Format-99 saved edit underneath a format-7 draft must
        // refuse Finished render and Raw import, writing no deliverable or render stamp.
        let pkgMixed = tempDir.appendingPathComponent("R6MixedVersion.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgMixed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgMixed.appendingPathComponent("screen.mov"))
        try CaptureManifest.encoder.encode(futureDoc).write(to: pkgMixed.appendingPathComponent("edit.json"))
        try CaptureManifest.encoder.encode(savedV7Doc).write(to: pkgMixed.appendingPathComponent("edit.draft.json"))
        let mixedSession = RecordingSession(directoryURL: pkgMixed)
        do {
            _ = try await RecordingSessionRenderer.ensureDeliverable(for: mixedSession)
            preconditionFailure("Finished render must refuse format-99 edit.json under format-7 edit.draft.json")
        } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
            // Expected
        }
        precondition(mixedSession.existingFinalURL == nil, "Mixed-version package must not write a deliverable")
        precondition(!FileManager.default.fileExists(atPath: pkgMixed.appendingPathComponent("render.json").path),
                     "Mixed-version package must not write render.json")
        do {
            let bad = try await RecordingSessionRenderer.prepareRawImport(for: pkgMixed)
            if bad.isTemporary { try? FileManager.default.removeItem(at: bad.url) }
            preconditionFailure("Raw import must refuse format-99 edit.json under format-7 edit.draft.json")
        } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
            // Expected
        }
        print("r6_mixed_version_blocks_finished_and_raw PASSED")

        // Round 6 — R6-3 (Finding 19): Compatible format-99 project with isolateVoice == true
        // and a real microphone track must NOT write mic-isolated-v2.m4a on read-only open.
        let pkgReadOnlyVoice = tempDir.appendingPathComponent("R6ReadOnlyVoice.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgReadOnlyVoice, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PiPURL, to: pkgReadOnlyVoice.appendingPathComponent("screen.mov"))
        let micManifest = CaptureManifest(
            createdAt: Date(),
            pixelWidth: 160,
            pixelHeight: 120,
            pixelScale: 1,
            includesSystemAudio: false,
            includesMicrophone: true
        )
        try CaptureManifest.encoder.encode(micManifest).write(to: pkgReadOnlyVoice.appendingPathComponent("capture.json"))
        var futureVoiceDoc = RecordingEditDocument(style: style, zoomEnabled: false, zoomCues: [], isolateVoice: true)
        futureVoiceDoc.formatVersion = 99
        try CaptureManifest.encoder.encode(futureVoiceDoc).write(to: pkgReadOnlyVoice.appendingPathComponent("edit.json"))
        let isolatedCacheURL = pkgReadOnlyVoice.appendingPathComponent(RecordingVoiceIsolation.fileName)
        precondition(!FileManager.default.fileExists(atPath: isolatedCacheURL.path))

        let voiceModel = await MainActor.run { RecordingStudioModel(url: pkgReadOnlyVoice) }
        await voiceModel.load()
        await MainActor.run {
            precondition(voiceModel.isLoaded && voiceModel.isReadOnlyNewerFormat,
                         "Expected compatible format-99 voice project to open read-only")
            voiceModel.teardown()
        }
        precondition(!FileManager.default.fileExists(atPath: isolatedCacheURL.path),
                     "Read-only newer project wrote mic-isolated-v2.m4a into the package!")
        print("r6_readonly_newer_skips_voice_isolation_write PASSED")

        // Round 6 — R6-4 (Finding 21): Mixed drop of a movie + image onto a non-video lane
        // imports the image AND preserves the movie wrong-lane warning.
        let pkgMixedDrop = tempDir.appendingPathComponent("R6MixedDrop.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgMixedDrop, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r4PrimaryURL, to: pkgMixedDrop.appendingPathComponent("screen.mov"))
        let dropImageURL = tempDir.appendingPathComponent("r6-drop-sticker.png")
        try writeSmallPNG(to: dropImageURL)

        let dropModel = await MainActor.run { RecordingStudioModel(url: pkgMixedDrop) }
        await dropModel.load()
        await MainActor.run {
            dropModel.handleTimelineMediaDrop(
                urls: [r4ImportURL, dropImageURL],
                atEditorTime: 0,
                audioLane: 0,
                insertionIndex: 1,
                targetLane: .other
            )
        }
        try await waitUntil(timeoutSeconds: 10) {
            await MainActor.run { dropModel.imageOverlays.count == 1 }
        }
        await MainActor.run {
            precondition(dropModel.clipTimeline.segments.count == 1 && dropModel.videoOverlays.isEmpty,
                         "Movie dropped onto non-video lane must not be added to clips or video overlays")
            precondition(dropModel.mediaImportError?.contains("Drop videos onto the Clips lane") == true,
                         "Mixed movie+image drop lost the movie wrong-lane warning: \(String(describing: dropModel.mediaImportError))")
            dropModel.teardown()
        }
        print("r6_mixed_drop_preserves_wrong_lane_warning PASSED")

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
        return try await audioRMS(asset: asset, track: track, window: window)
    }

    static func audioRMS(asset: AVAsset, track: AVAssetTrack, window: Range<TimeInterval>) async throws -> Double {
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

    /// Writes a video whose coded pixels put a 4x4 checkerboard on only one
    /// half (`cy >= height/2` when `checkerInBottomCodedHalf`, else `cy < height/2`)
    /// and flat grey on the other half, tagged with `preferredTransform`.
    static func writeRotatedAsymmetricMovie(
        to url: URL,
        codedSize: CGSize,
        duration: TimeInterval,
        preferredTransform: CGAffineTransform,
        checkerInBottomCodedHalf: Bool
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(codedSize.width),
            AVVideoHeightKey: Int(codedSize.height)
        ])
        input.transform = preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(codedSize.width),
                kCVPixelBufferHeightKey as String: Int(codedSize.height)
            ]
        )
        writer.add(input)
        precondition(writer.startWriting(), "writeRotatedAsymmetricMovie start failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        let total = max(1, Int((duration * Double(fps)).rounded()))
        let w = Int(codedSize.width)
        let h = Int(codedSize.height)
        for f in 0..<total {
            try await waitUntilReady(input, writer: writer)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                let inCheckerHalf = checkerInBottomCodedHalf ? (y >= h / 2) : (y < h / 2)
                for x in 0..<w {
                    let v: UInt8 = inCheckerHalf ? ((((x / 4) + (y / 4)) % 2 == 0) ? 255 : 0) : 128
                    row[x * 4] = v; row[x * 4 + 1] = v; row[x * 4 + 2] = v; row[x * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "writeRotatedAsymmetricMovie failed: \(String(describing: writer.error))")
    }

    /// Writes a checkerboard movie with TWO separate audio tracks (simulating
    /// mic + system audio masters) using bounded interleaved readiness polling.
    static func writeMultiAudioCheckerboardMovie(
        to url: URL,
        size: CGSize,
        duration: TimeInterval,
        track1ToneHz: Double,
        track2ToneHz: Double
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

        let sampleRate = 44100.0
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioInput1 = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        let audioInput2 = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        writer.add(audioInput1)
        writer.add(audioInput2)

        precondition(writer.startWriting(), "writeMultiAudioCheckerboardMovie start failed: \(String(describing: writer.error))")
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

        func makeAudioSample(startSample: Int, count: Int, toneHz: Double) -> CMSampleBuffer {
            var pcm = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(startSample + i) / sampleRate
                pcm[i] = Int16(sin(2.0 * .pi * toneHz * t) * 0.35 * Double(Int16.max))
            }
            let dataSize = count * MemoryLayout<Int16>.size
            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: dataSize, flags: 0, blockBufferOut: &blockBuffer
            )
            let block = blockBuffer!
            _ = pcm.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)
            }
            var sb: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid
            )
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc,
                sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb
            )
            return sb!
        }

        let fps = 30
        let totalFrames = max(1, Int((duration * Double(fps)).rounded()))
        let totalSamples = Int((duration * sampleRate).rounded())
        let chunkSamples = 4410
        var f = 0, a1 = 0, a2 = 0
        var vDone = false, a1Done = false, a2Done = false
        let deadline = Date().addingTimeInterval(10)

        while f < totalFrames || a1 < totalSamples || a2 < totalSamples {
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? NSError(domain: "CheckR2Export", code: 30)
            }
            if Date() >= deadline {
                throw NSError(domain: "CheckR2Export", code: 31, userInfo: [NSLocalizedDescriptionKey: "Timed out writing multi-audio movie"])
            }
            if f >= totalFrames && !vDone { videoInput.markAsFinished(); vDone = true }
            if a1 >= totalSamples && !a1Done { audioInput1.markAsFinished(); a1Done = true }
            if a2 >= totalSamples && !a2Done { audioInput2.markAsFinished(); a2Done = true }

            let vReady = f < totalFrames && videoInput.isReadyForMoreMediaData
            let a1Ready = a1 < totalSamples && audioInput1.isReadyForMoreMediaData
            let a2Ready = a2 < totalSamples && audioInput2.isReadyForMoreMediaData
            guard vReady || a1Ready || a2Ready else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            if a1Ready {
                let n = min(chunkSamples, totalSamples - a1)
                audioInput1.append(makeAudioSample(startSample: a1, count: n, toneHz: track1ToneHz))
                a1 += n
            } else if a2Ready {
                let n = min(chunkSamples, totalSamples - a2)
                audioInput2.append(makeAudioSample(startSample: a2, count: n, toneHz: track2ToneHz))
                a2 += n
            } else if vReady {
                let w = Int(size.width), h = Int(size.height)
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
                let buf = pb!
                CVPixelBufferLockBaseAddress(buf, [])
                let base = CVPixelBufferGetBaseAddress(buf)!
                let bpr = CVPixelBufferGetBytesPerRow(buf)
                for y in 0..<h {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w {
                        let v: UInt8 = (((x / 4) + (y / 4)) % 2 == 0) ? 255 : 0
                        row[x * 4] = v; row[x * 4 + 1] = v; row[x * 4 + 2] = v; row[x * 4 + 3] = 255
                    }
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
                f += 1
            }
        }
        if !vDone { videoInput.markAsFinished() }
        if !a1Done { audioInput1.markAsFinished() }
        if !a2Done { audioInput2.markAsFinished() }
        await writer.finishWriting()
        precondition(writer.status == .completed, "writeMultiAudioCheckerboardMovie failed: \(String(describing: writer.error))")
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
