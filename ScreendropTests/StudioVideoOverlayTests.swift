import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing

struct StudioVideoOverlayTests {
    // MARK: - Model defaults, Codable & presentation switch

    @Test func defaultsPiPAudibleCutawayMutedAndSwitchPreservesPiPLayout() throws {
        var pip = RecordingVideoOverlay(
            fileName: "clip.mov",
            displayName: "Demo",
            start: 2,
            fileDuration: 5,
            presentation: .pip
        )
        #expect(!pip.isMuted)
        #expect(pip.volume == 1)
        #expect(pip.audibleVolume == 1)

        pip.center = CGPoint(x: 0.22, y: 0.31)
        pip.width = 0.42
        pip.rotation = -8
        pip.cornerRadius = 28
        pip.shadow = 0.7

        let cutaway = pip.switchingPresentation(to: .cutaway)
        #expect(cutaway.presentation == .cutaway)
        #expect(cutaway.isMuted)
        #expect(cutaway.audibleVolume == 0)
        #expect(cutaway.fadeIn > 0 && cutaway.fadeOut > 0)
        // PiP layout fields stay preserved while in Cutaway mode.
        #expect(cutaway.center == CGPoint(x: 0.22, y: 0.31))
        #expect(cutaway.width == 0.42)
        #expect(cutaway.rotation == -8)
        #expect(cutaway.cornerRadius == 28)
        #expect(cutaway.shadow == 0.7)

        let backToPiP = cutaway.switchingPresentation(to: .pip)
        #expect(backToPiP.presentation == .pip)
        #expect(!backToPiP.isMuted)
        #expect(backToPiP.audibleVolume == 1)
        #expect(backToPiP.center == CGPoint(x: 0.22, y: 0.31))
        #expect(backToPiP.width == 0.42)

        // Direct Cutaway initializer defaults muted with crossfade.
        let directCutaway = RecordingVideoOverlay(
            fileName: "broll.mov",
            displayName: "B-Roll",
            start: 1,
            fileDuration: 4,
            presentation: .cutaway
        )
        #expect(directCutaway.isMuted)
        #expect(directCutaway.audibleVolume == 0)
        #expect(abs(directCutaway.fadeIn - RecordingVideoOverlay.defaultCutawayFade) < 0.001)

        // Codable round-trip preserves every field.
        let encoded = try JSONEncoder().encode(cutaway)
        let decoded = try JSONDecoder().decode(RecordingVideoOverlay.self, from: encoded)
        #expect(decoded == cutaway)
    }

    @Test func legacyOverlayJSONDecodesWithDefaultsAndSanitizesOutOfBounds() throws {
        let minimalJSON = """
        {
            "fileName": "clip.mov",
            "start": 1.5,
            "trimEnd": 4.0,
            "width": 99.0,
            "opacity": -2.0,
            "speed": 0.01
        }
        """
        let decoded = try JSONDecoder().decode(RecordingVideoOverlay.self, from: Data(minimalJSON.utf8)).sanitized()
        #expect(decoded.fileName == "clip.mov")
        #expect(decoded.displayName == "clip.mov")
        #expect(decoded.presentation == .pip)
        #expect(!decoded.isMuted)
        #expect(decoded.width == RecordingVideoOverlay.widthRange.upperBound)
        #expect(decoded.opacity == 0)
        #expect(decoded.speed == RecordingVideoOverlay.speedRange.lowerBound)
        #expect(decoded.fileDuration >= decoded.trimEnd)
    }

    // MARK: - Timing, fades, geometry, snapping

    @Test func mediaTimeFadesAndCutawayCoverageComputeAccurately() {
        var overlay = RecordingVideoOverlay(
            fileName: "clip.mov",
            displayName: "Cutaway",
            start: 2,
            fileDuration: 10,
            presentation: .cutaway
        )
        overlay.trimStart = 1
        overlay.trimEnd = 5
        overlay.speed = 2 // 4s file span -> 2s edited duration (2...4)
        overlay.fadeIn = 0.5
        overlay.fadeOut = 0.5
        overlay.opacity = 1

        #expect(abs(overlay.duration - 2) < 0.0001)
        #expect(abs(overlay.end - 4) < 0.0001)
        #expect(!overlay.isActive(atEditorTime: 1.99))
        #expect(overlay.isActive(atEditorTime: 2.0))
        #expect(!overlay.isActive(atEditorTime: 4.0))

        #expect(abs(overlay.mediaTime(atEditorTime: 2.0) - 1.0) < 0.0001)
        #expect(abs(overlay.mediaTime(atEditorTime: 3.0) - 3.0) < 0.0001)
        #expect(abs(overlay.mediaTime(atEditorTime: 4.0) - 5.0) < 0.0001)

        #expect(abs(overlay.fade(atEditorTime: 2.25) - 0.5) < 0.001)
        #expect(abs(overlay.fade(atEditorTime: 3.0) - 1.0) < 0.001)
        #expect(abs(overlay.fade(atEditorTime: 3.75) - 0.5) < 0.001)
        #expect(overlay.fade(atEditorTime: 4.0) == 0)

        #expect(abs(StudioVideoOverlayLane.cutawayCoverage(in: [overlay], atEditorTime: 2.25) - 0.5) < 0.001)
        #expect(abs(StudioVideoOverlayLane.cutawayCoverage(in: [overlay], atEditorTime: 3.0) - 1.0) < 0.001)
        #expect(StudioVideoOverlayLane.cutawayCoverage(in: [overlay], atEditorTime: 1.0) == 0)

        // PiP never reports cutaway coverage.
        let asPiP = overlay.switchingPresentation(to: .pip)
        #expect(StudioVideoOverlayLane.cutawayCoverage(in: [asPiP], atEditorTime: 3.0) == 0)

        // Overlapping fadeIn + fadeOut squeeze cleanly into half the clip each.
        overlay.fadeIn = 2.0
        overlay.fadeOut = 2.0
        #expect(abs(overlay.fade(atEditorTime: 2.5) - 0.5) < 0.001)
        #expect(abs(overlay.fade(atEditorTime: 3.0) - 1.0) < 0.001)
        #expect(abs(overlay.fade(atEditorTime: 3.5) - 0.5) < 0.001)
    }

    @Test func pipAndCutawayGeometryAndSnapGuides() {
        var overlay = RecordingVideoOverlay(fileName: "a.mov", displayName: "A", start: 0, fileDuration: 4)
        overlay.center = CGPoint(x: 0.5, y: 0.5)
        overlay.width = 0.25
        overlay.aspect = 2.0 // 2:1

        let canvas = CGSize(width: 1000, height: 500)
        let pipRect = overlay.pipRect(canvasSize: canvas)
        #expect(abs(pipRect.width - 250) < 0.01)
        #expect(abs(pipRect.height - 125) < 0.01)
        #expect(abs(pipRect.midX - 500) < 0.01)
        #expect(abs(pipRect.midY - 250) < 0.01)

        // Cutaway Fill vs Fit for a portrait 1:2 clip inside a 16:9 card (800 x 450).
        let card = CGRect(x: 100, y: 25, width: 800, height: 450)
        overlay.cutawayContentMode = .fill
        let fillRect = overlay.cutawayDrawRect(cardRect: card, sourceAspect: 0.5)
        #expect(abs(fillRect.width - 800) < 0.01)
        #expect(abs(fillRect.height - 1600) < 0.01)
        #expect(abs(fillRect.midX - card.midX) < 0.01)
        #expect(abs(fillRect.midY - card.midY) < 0.01)

        overlay.cutawayContentMode = .fit
        let fitRect = overlay.cutawayDrawRect(cardRect: card, sourceAspect: 0.5)
        #expect(abs(fitRect.height - 450) < 0.01)
        #expect(abs(fitRect.width - 225) < 0.01)
        #expect(abs(fitRect.midX - card.midX) < 0.01)
        #expect(abs(fitRect.midY - card.midY) < 0.01)

        // PiP snapping near center line snaps and returns guide coordinates.
        let snapped = RecordingVideoOverlay.snapPiPCenter(
            CGPoint(x: 503, y: 247),
            size: pipRect.size,
            canvas: canvas,
            margin: 20
        )
        #expect(abs(snapped.center.x - 500) < 0.01)
        #expect(abs(snapped.center.y - 250) < 0.01)
        #expect(snapped.guideX == 500)
        #expect(snapped.guideY == 250)
    }

    // MARK: - Single-lane non-overlapping occupancy

    @Test func singleLaneEnforcesNoOverlapsAcrossPlacementMoveTrimSpeedAndConform() {
        let a = RecordingVideoOverlay(fileName: "a.mov", displayName: "A", start: 1, fileDuration: 2) // 1...3
        let b = RecordingVideoOverlay(fileName: "b.mov", displayName: "B", start: 5, fileDuration: 2) // 5...7
        let existing = [a, b]

        // Placing inside `a` advances to `a.end` (3) and trims to fit before `b.start` (5).
        let incoming = RecordingVideoOverlay(fileName: "c.mov", displayName: "C", start: 0, fileDuration: 6)
        let placed = StudioVideoOverlayLane.place(incoming, at: 1.5, timelineDuration: 10, among: existing)
        #expect(placed != nil)
        #expect(abs((placed?.start ?? -1) - 3) < 0.001)
        #expect(abs((placed?.end ?? -1) - 5) < 0.001)

        // When the lane is full from 0...10, placement returns nil.
        let full = RecordingVideoOverlay(fileName: "full.mov", displayName: "Full", start: 0, fileDuration: 10)
        #expect(StudioVideoOverlayLane.place(incoming, at: 2, timelineDuration: 10, among: [full]) == nil)

        // Moving `a` right stops at `b.start` (5 - duration 2 = 3).
        let movedA = StudioVideoOverlayLane.moved(a, by: 10, among: existing, timelineDuration: 10)
        #expect(abs(movedA.start - 3) < 0.001)
        #expect(abs(movedA.end - 5) < 0.001)

        // Trimming trailing of `a` cannot exceed its fileDuration (2s -> end 3) or neighbor `b.start`.
        var trimmedSource = RecordingVideoOverlay(fileName: "t.mov", displayName: "T", start: 1, fileDuration: 10)
        trimmedSource.trimStart = 2
        trimmedSource.trimEnd = 4 // editor 1...3
        let list = [trimmedSource, b]
        let extendedTrailing = StudioVideoOverlayLane.trimmedTrailing(trimmedSource, by: 10, among: list)
        #expect(abs(extendedTrailing.end - 5) < 0.001) // stopped by `b.start`

        // Trimming leading cannot pass `trimStart == 0` or `start == 0`.
        let extendedLeading = StudioVideoOverlayLane.trimmedLeading(trimmedSource, by: -10, among: list)
        #expect(abs(extendedLeading.start - 0) < 0.001)
        #expect(abs(extendedLeading.trimStart - 1) < 0.001)
        #expect(abs(extendedLeading.end - 3) < 0.001)

        // Slowing `a` (1...3) to 0.5x would normally become 4s (1...5), which fits exactly before `b` (5...7).
        // Slowing to 0.25x would become 8s (1...9), so `trimEnd` clamps so `end <= 5`.
        let slowed = StudioVideoOverlayLane.withSpeed(a, speed: 0.25, among: existing)
        #expect(abs(slowed.speed - 0.25) < 0.001)
        #expect(slowed.end <= b.start + 0.001)

        // Conforming across a cut shifts overlays and resolves any collision without overlapping.
        let oldTimeline = RecordingClipTimeline.full(sourceDuration: 10)
        let cutTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 2),
            RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        ])
        let conformed = StudioVideoOverlayLane.conform(existing, from: oldTimeline, to: cutTimeline)
        #expect(conformed.count == 2)
        #expect(conformed[0].end <= conformed[1].start + 0.000_5)
    }

    // MARK: - Recycled AVPlayer playback state machine

    @Test func playbackPlanLoadsNearSpanPlaysInSyncAndClearsOutside() {
        var overlay = RecordingVideoOverlay(fileName: "pip.mov", displayName: "PiP", start: 4, fileDuration: 6)
        overlay.trimStart = 1
        overlay.trimEnd = 4 // 3s at 1x -> 4...7
        overlay.speed = 1.5 // 2s edited duration -> 4...6

        // Paused outside span -> cleared (zero player item retained).
        #expect(StudioVideoOverlayPlaybackPlan.resolve(at: 3.5, isPlaying: false, shuttleRate: 1, overlays: [overlay]) == .clear)
        #expect(StudioVideoOverlayPlaybackPlan.resolve(at: 6.1, isPlaying: false, shuttleRate: 1, overlays: [overlay]) == .clear)

        // Paused inside span -> active with nil rate at exact media time.
        let pausedInside = StudioVideoOverlayPlaybackPlan.resolve(at: 5.0, isPlaying: false, shuttleRate: 1, overlays: [overlay])
        #expect(pausedInside == .active(overlay: overlay, mediaTime: 2.5, targetRate: nil))

        // Playing far before span -> cleared.
        #expect(StudioVideoOverlayPlaybackPlan.resolve(at: 1.0, isPlaying: true, shuttleRate: 1, overlays: [overlay]) == .clear)

        // Playing within 1.5s lead before span -> preload at trimStart.
        let preloadForward = StudioVideoOverlayPlaybackPlan.resolve(at: 3.0, isPlaying: true, shuttleRate: 1, overlays: [overlay])
        #expect(preloadForward == .preload(overlay: overlay, mediaTime: 1.0))

        // Playing inside span at 2x shuttle -> active at speed * shuttleRate (1.5 * 2 = 3.0).
        let playingInside = StudioVideoOverlayPlaybackPlan.resolve(at: 5.0, isPlaying: true, shuttleRate: 2, overlays: [overlay])
        #expect(playingInside == .active(overlay: overlay, mediaTime: 2.5, targetRate: 3.0))

        // Playing after leaving span -> cleared immediately.
        #expect(StudioVideoOverlayPlaybackPlan.resolve(at: 6.05, isPlaying: true, shuttleRate: 1, overlays: [overlay]) == .clear)

        // Reverse shuttling approaching trailing edge -> preload at trimEnd.
        let preloadReverse = StudioVideoOverlayPlaybackPlan.resolve(at: 6.5, isPlaying: true, shuttleRate: -1, overlays: [overlay])
        #expect(preloadReverse == .preload(overlay: overlay, mediaTime: 4.0))
    }

    // MARK: - Audio mix integration

    @Test func videoOverlayAudioJoinsSharedMixAndMutedCutawayStaysSilent() async throws {
        let dir = try makeTempDir("StudioVideoOverlayAudio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let screenURL = try await makeToneMovie(in: dir, name: "screen.mov", frequency: 0, amplitude: 0, duration: 4)
        let pipFileName = "\(UUID().uuidString).mov"
        let pipURL = try await makeToneMovie(in: mediaDir, name: pipFileName, frequency: 440, amplitude: 0.5, duration: 2)
        let probed = try #require(await RecordingVideoOverlayMedia.probe(url: pipURL))
        #expect(probed.hasAudio)

        let timeline = RecordingClipTimeline.full(sourceDuration: 4)
        let pip = RecordingVideoOverlay(
            fileName: pipFileName,
            displayName: "Talking PiP",
            start: 1,
            fileDuration: 2,
            presentation: .pip
        )
        let mutedCutaway = pip.switchingPresentation(to: .cutaway)

        // Audible PiP contributes audio inside [1, 3] and stays silent outside.
        let preparedPiP = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: nil,
            replacementSync: nil,
            clips: [],
            videoOverlays: [pip],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: nil
        )
        let pipSamples = try await renderMonoSamples(asset: preparedPiP.composition, mix: preparedPiP.mix, duration: 4)
        #expect(peakAmplitude(in: pipSamples, from: 0.2, to: 0.8) < 0.02)
        #expect(peakAmplitude(in: pipSamples, from: 1.3, to: 2.7) > 0.3)
        #expect(peakAmplitude(in: pipSamples, from: 3.2, to: 3.8) < 0.02)
        withExtendedLifetime(preparedPiP) {}

        // Muted Cutaway produces zero audio across the entire timeline.
        let preparedCutaway = try await StudioAudioComposer.prepareExport(
            screenAsset: AVURLAsset(url: screenURL),
            screenURL: screenURL,
            timeline: timeline,
            replacementURL: nil,
            replacementSync: nil,
            clips: [],
            videoOverlays: [mutedCutaway],
            mediaDirectory: mediaDir,
            volume: 1,
            microphoneTrackID: nil,
            isolatedMicrophoneURL: nil,
            backgroundMusic: nil
        )
        let cutawaySamples = try await renderMonoSamples(asset: preparedCutaway.composition, mix: preparedCutaway.mix, duration: 4)
        #expect(peakAmplitude(in: cutawaySamples, from: 0.1, to: 3.9) < 0.01)
        withExtendedLifetime(preparedCutaway) {}

        // Visual-only and volume-only edits keep `StudioAudioPlan.placement` identical.
        var movedVisual = pip
        movedVisual.center = CGPoint(x: 0.2, y: 0.2)
        movedVisual.cornerRadius = 40
        movedVisual.volume = 0.5
        movedVisual.isMuted = true
        let planA = StudioAudioPlan(timeline: timeline, sync: nil, clips: [], volume: 1, videoOverlays: [pip])
        let planB = StudioAudioPlan(timeline: timeline, sync: nil, clips: [], volume: 1, videoOverlays: [movedVisual])
        #expect(planA.placement == planB.placement)
    }

    // MARK: - On-demand sequential VideoOverlayFrameFeed, orientation & rendering

    @Test func frameFeedOpensLazilyReleasesBetweenOverlaysAndHonorsTransformAndRendering() async throws {
        let dir = try makeTempDir("StudioVideoOverlayFeed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let redName = "\(UUID().uuidString).mov"
        let blueName = "\(UUID().uuidString).mov"
        let redURL = mediaDir.appendingPathComponent(redName)
        let blueURL = mediaDir.appendingPathComponent(blueName)
        try await writeSolidMovie(to: redURL, width: 64, height: 36, r: 230, g: 30, b: 30, durationSeconds: 1.0)
        try await writeSolidMovie(to: blueURL, width: 64, height: 36, r: 30, g: 60, b: 230, durationSeconds: 1.0)

        let probe = try #require(await RecordingVideoOverlayMedia.probe(url: redURL))
        #expect(abs(probe.duration - 1.0) < 0.15)
        #expect(abs(probe.aspect - (64.0 / 36.0)) < 0.05)
        #expect(!probe.hasAudio)

        let overlay1 = RecordingVideoOverlay(fileName: redName, displayName: "Red", start: 0.5, fileDuration: 1.0, presentation: .pip)
        var overlay2 = RecordingVideoOverlay(fileName: blueName, displayName: "Blue", start: 2.0, fileDuration: 1.0, presentation: .cutaway)
        overlay2.fadeIn = 0.4
        overlay2.fadeOut = 0.4

        let feed = VideoOverlayFrameFeed(overlays: [overlay1, overlay2], mediaDirectory: mediaDir)
        defer { feed.cancel() }

        // Before overlay 1: no reader open.
        #expect(try await feed.frame(at: 0.1) == nil)
        #expect(feed.activeOverlayID == nil)

        // Inside overlay 1: red reader opens.
        let frame1 = try #require(try await feed.frame(at: 0.7))
        #expect(feed.activeOverlayID == overlay1.id)

        // Gap between overlays: reader immediately released.
        #expect(try await feed.frame(at: 1.7) == nil)
        #expect(feed.activeOverlayID == nil)

        // Inside overlay 2: blue reader opens.
        let frame2 = try #require(try await feed.frame(at: 2.2)) // mid-crossfade (fade = 0.5)
        #expect(feed.activeOverlayID == overlay2.id)

        // Verify mid-crossfade cutaway compositing over a green card on a white background:
        // card interior blends 50% green + 50% blue, background outside card stays white!
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let blueImage = try #require(RecordingVideoOverlayRenderer.makeOrientedImage(
            from: frame2.pixelBuffer,
            preferredTransform: frame2.preferredTransform,
            colorSpace: colorSpace
        ))
        let canvasSize = CGSize(width: 200, height: 120)
        let cardRect = CGRect(x: 20, y: 20, width: 160, height: 80)
        let rendered = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            // White background
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            // Green main video card
            ctx.setFillColor(CGColor(red: 0, green: 0.8, blue: 0, alpha: 1))
            ctx.fill(cardRect)
            // Cutaway at mid-crossfade (t = 2.2 -> fade = 0.5)
            RecordingVideoOverlayRenderer.draw(
                overlay2,
                frame: blueImage,
                atEditorTime: 2.2,
                canvasSize: canvasSize,
                cardRect: cardRect,
                cardCornerRadius: 0,
                in: ctx
            )
        }
        // Background outside card remains white.
        let bgPixel = pixelRGB(in: rendered, x: 5, y: 5)
        #expect(bgPixel.r > 240 && bgPixel.g > 240 && bgPixel.b > 240)
        // Center of card shows blended green + blue (~100 green, ~115 blue).
        let midPixel = pixelRGB(in: rendered, x: 100, y: 60)
        #expect(midPixel.g > 70 && midPixel.g < 150)
        #expect(midPixel.b > 70 && midPixel.b < 160)

        // After overlay 2 ends: reader released again.
        #expect(try await feed.frame(at: 3.1) == nil)
        #expect(feed.activeOverlayID == nil)

        // Verify PiP rendering on top of card leaves background and untouched card pixels intact.
        let redImage = try #require(RecordingVideoOverlayRenderer.makeOrientedImage(
            from: frame1.pixelBuffer,
            preferredTransform: frame1.preferredTransform,
            colorSpace: colorSpace
        ))
        var pipCentered = overlay1
        pipCentered.center = CGPoint(x: 0.5, y: 0.5)
        pipCentered.width = 0.4
        pipCentered.aspect = 2.0
        pipCentered.cornerRadius = 0
        pipCentered.shadow = 0
        let pipCanvas = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0.8, blue: 0, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            RecordingVideoOverlayRenderer.draw(
                pipCentered,
                frame: redImage,
                atEditorTime: 0.7,
                canvasSize: canvasSize,
                cardRect: cardRect,
                cardCornerRadius: 0,
                in: ctx
            )
        }
        let pipCenter = pixelRGB(in: pipCanvas, x: 100, y: 60)
        #expect(pipCenter.r > 180 && pipCenter.g < 80)
        let pipOutside = pixelRGB(in: pipCanvas, x: 10, y: 10)
        #expect(pipOutside.g > 180 && pipOutside.r < 40)
    }

    @Test func rotatedPortraitVideoHonorsPreferredTransformInProbeAndExportImage() async throws {
        let dir = try makeTempDir("StudioVideoOverlayTransform")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movieURL = dir.appendingPathComponent("rotated.mov")
        // Encoded 64x32 (left half red, right half blue) with 90° clockwise transform -> display 32x64 (top red, bottom blue).
        let rotate90CW = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        try await writeSplitColorMovie(to: movieURL, width: 64, height: 32, transform: rotate90CW)

        let probe = try #require(await RecordingVideoOverlayMedia.probe(url: movieURL))
        #expect(abs(probe.aspect - 0.5) < 0.05)

        let overlay = RecordingVideoOverlay(fileName: "rotated.mov", displayName: "Portrait", start: 0, fileDuration: 0.5)
        let feed = VideoOverlayFrameFeed(overlays: [overlay], mediaDirectory: dir)
        defer { feed.cancel() }
        let frame = try #require(try await feed.frame(at: 0.1))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let oriented = try #require(RecordingVideoOverlayRenderer.makeOrientedImage(
            from: frame.pixelBuffer,
            preferredTransform: frame.preferredTransform,
            colorSpace: colorSpace
        ))
        #expect(oriented.width == 32)
        #expect(oriented.height == 64)
        // Top half (y = 10 in top-down) is red; bottom half (y = 54) is blue.
        let topPixel = pixelRGB(in: oriented, x: 16, y: 10)
        let bottomPixel = pixelRGB(in: oriented, x: 16, y: 54)
        #expect(topPixel.r > 180 && topPixel.b < 80)
        #expect(bottomPixel.b > 180 && bottomPixel.r < 80)
    }

    @Test func mediaValidationRejectsSymlinksAndCleanupOnlyRemovesUnreferencedOwnedVideos() async throws {
        let dir = try makeTempDir("StudioVideoOverlaySecurity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let outside = dir.appendingPathComponent("outside.mov")
        try await writeSolidMovie(to: outside, width: 32, height: 32, r: 100, g: 100, b: 100, durationSeconds: 0.3)
        let symName = "\(UUID().uuidString).mov"
        try FileManager.default.createSymbolicLink(at: mediaDir.appendingPathComponent(symName), withDestinationURL: outside)

        let symOverlay = RecordingVideoOverlay(fileName: symName, displayName: "Escaped", start: 0, fileDuration: 0.3)
        #expect(throws: RecordingVideoOverlayMedia.ResolutionError.missingOrInvalid("Escaped")) {
            try RecordingVideoOverlayMedia.validateOverlays([symOverlay], in: mediaDir, duration: 2)
        }

        let keptName = try #require(RecordingOverlayMedia.copyRegularFile(from: outside, into: mediaDir))
        let orphanName = try #require(RecordingOverlayMedia.copyRegularFile(from: outside, into: mediaDir))
        let nonOwned = mediaDir.appendingPathComponent("custom.mov")
        try FileManager.default.copyItem(at: outside, to: nonOwned)

        RecordingVideoOverlayMedia.cleanupUnreferencedVideos(in: mediaDir, referenced: [keptName])
        #expect(FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(keptName).path))
        #expect(!FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(orphanName).path))
        #expect(FileManager.default.fileExists(atPath: nonOwned.path))
    }

    // MARK: - Round 2 regressions (self-import, fades/shadow, conform/linking, package validation)

    @Test func selfImportDetectionCatchesDirectStandardizedAndSymlinkedPaths() throws {
        let dir = try makeTempDir("StudioVideoOverlaySelfImport")
        defer { try? FileManager.default.removeItem(at: dir) }

        let openPackage = dir.appendingPathComponent("Open.sukushorec", isDirectory: true)
        let otherPackage = dir.appendingPathComponent("Other.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: openPackage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherPackage, withIntermediateDirectories: true)

        let unstandardized = openPackage.appendingPathComponent("../Open.sukushorec", isDirectory: true)
        let symlinkAlias = dir.appendingPathComponent("Alias.sukushorec", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkAlias, withDestinationURL: openPackage)

        #expect(RecordingVideoOverlayMedia.isSelfRecording(openPackage, openSessionURL: openPackage))
        #expect(RecordingVideoOverlayMedia.isSelfRecording(unstandardized, openSessionURL: openPackage))
        #expect(RecordingVideoOverlayMedia.isSelfRecording(symlinkAlias, openSessionURL: openPackage))
        #expect(!RecordingVideoOverlayMedia.isSelfRecording(otherPackage, openSessionURL: openPackage))
    }

    @Test func cutawayFadeMatchesSingleDissolveAndPiPShadowDoesNotDarkenInterior() throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let canvasSize = CGSize(width: 200, height: 120)
        let cardRect = CGRect(x: 20, y: 20, width: 160, height: 80)

        let solidRed = CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])!
        let solidBlue = CGColor(colorSpace: colorSpace, components: [0, 0, 1, 1])!
        let solidBlack = CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!

        // Pure blue source images: 2:1 landscape (for Fill & PiP) and 1:2 portrait (for Fit letterbox).
        let blueLandscape = try renderCanvas(size: CGSize(width: 80, height: 40), colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidBlue)
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let bluePortrait = try renderCanvas(size: CGSize(width: 40, height: 80), colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidBlue)
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }

        // Single-layer reference: 50% blue over red, and 50% black over red.
        let refBlueOverRedImage = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidRed)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            ctx.setAlpha(0.5)
            ctx.setFillColor(solidBlue)
            ctx.fill(cardRect)
        }
        let refBlueOverRed = pixelRGB(in: refBlueOverRedImage, x: 100, y: 60)

        let refBlackOverRedImage = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidRed)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            ctx.setAlpha(0.5)
            ctx.setFillColor(solidBlack)
            ctx.fill(cardRect)
        }
        let refBlackOverRed = pixelRGB(in: refBlackOverRedImage, x: 100, y: 60)

        // 1. Cutaway Fill at 50% crossfade matches single-layer dissolve (no double-fade darkening).
        var fillCutaway = RecordingVideoOverlay(
            fileName: "b.mov",
            displayName: "Blue",
            start: 0,
            fileDuration: 4,
            presentation: .cutaway
        )
        fillCutaway.fadeIn = 2.0
        fillCutaway.fadeOut = 0
        fillCutaway.cutawayContentMode = .fill
        let fillRendered = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidRed)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            RecordingVideoOverlayRenderer.draw(
                fillCutaway,
                frame: blueLandscape,
                atEditorTime: 1.0,
                canvasSize: canvasSize,
                cardRect: cardRect,
                cardCornerRadius: 0,
                in: ctx
            )
        }
        let fillMid = pixelRGB(in: fillRendered, x: 100, y: 60)
        #expect(abs(Int(fillMid.r) - Int(refBlueOverRed.r)) <= 2)
        #expect(abs(Int(fillMid.g) - Int(refBlueOverRed.g)) <= 2)
        #expect(abs(Int(fillMid.b) - Int(refBlueOverRed.b)) <= 2)

        // 2. Cutaway Fit at 50% crossfade: video center matches single dissolve blue/red,
        // and letterbox pillar matches single dissolve black/red.
        var fitCutaway = fillCutaway
        fitCutaway.cutawayContentMode = .fit
        let fitRendered = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidRed)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            RecordingVideoOverlayRenderer.draw(
                fitCutaway,
                frame: bluePortrait,
                atEditorTime: 1.0,
                canvasSize: canvasSize,
                cardRect: cardRect,
                cardCornerRadius: 0,
                in: ctx
            )
        }
        let fitVideoCenter = pixelRGB(in: fitRendered, x: 100, y: 60)
        #expect(abs(Int(fitVideoCenter.r) - Int(refBlueOverRed.r)) <= 2)
        #expect(abs(Int(fitVideoCenter.g) - Int(refBlueOverRed.g)) <= 2)
        #expect(abs(Int(fitVideoCenter.b) - Int(refBlueOverRed.b)) <= 2)
        let fitLetterbox = pixelRGB(in: fitRendered, x: 35, y: 60)
        #expect(abs(Int(fitLetterbox.r) - Int(refBlackOverRed.r)) <= 2)
        #expect(abs(Int(fitLetterbox.g) - Int(refBlackOverRed.g)) <= 2)
        #expect(abs(Int(fitLetterbox.b) - Int(refBlackOverRed.b)) <= 2)

        // 3. Rounded PiP with strong drop shadow at 50% opacity: interior matches single dissolve
        // (zero darkening from shadow) while exterior below PiP receives the shadow.
        var pip = RecordingVideoOverlay(
            fileName: "p.mov",
            displayName: "PiP",
            start: 0,
            fileDuration: 4,
            presentation: .pip
        )
        pip.center = CGPoint(x: 0.5, y: 0.45)
        pip.width = 0.4 // 80 x 40 centered at (100, 54) -> y in [34, 74]
        pip.aspect = 2.0
        pip.opacity = 0.5
        pip.cornerRadius = 40
        pip.shadow = 0.9
        let pipRendered = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidRed)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            RecordingVideoOverlayRenderer.draw(
                pip,
                frame: blueLandscape,
                atEditorTime: 2.0,
                canvasSize: canvasSize,
                cardRect: cardRect,
                cardCornerRadius: 0,
                in: ctx
            )
        }
        let pipInterior = pixelRGB(in: pipRendered, x: 100, y: 54)
        #expect(abs(Int(pipInterior.r) - Int(refBlueOverRed.r)) <= 2)
        #expect(abs(Int(pipInterior.g) - Int(refBlueOverRed.g)) <= 2)
        #expect(abs(Int(pipInterior.b) - Int(refBlueOverRed.b)) <= 2)
        let pipShadowOutside = pixelRGB(in: pipRendered, x: 100, y: 75)
        #expect(pipShadowOutside.r < 245) // shadow darkened exterior red right below PiP bottom edge

        // 4. Switching a 30%-opacity PiP to Cutaway yields a 100% opaque cutaway mid-span,
        // while keeping the saved PiP opacity intact for switching back.
        pip.opacity = 0.3
        let switched = pip.switchingPresentation(to: .cutaway)
        #expect(abs(switched.opacity - 0.3) < 0.001)
        #expect(abs(switched.effectiveOpacity(atEditorTime: 2.0) - 1.0) < 0.001)
        #expect(abs(StudioVideoOverlayLane.cutawayCoverage(in: [switched], atEditorTime: 2.0) - 1.0) < 0.001)
        let opaqueCutaway = try renderCanvas(size: canvasSize, colorSpace: colorSpace) { ctx in
            ctx.setFillColor(solidRed)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            RecordingVideoOverlayRenderer.draw(
                switched,
                frame: blueLandscape,
                atEditorTime: 2.0,
                canvasSize: canvasSize,
                cardRect: cardRect,
                cardCornerRadius: 0,
                in: ctx
            )
        }
        let opaqueMid = pixelRGB(in: opaqueCutaway, x: 100, y: 60)
        #expect(opaqueMid.r <= 2 && opaqueMid.b >= 253)
        let backToPiP = switched.switchingPresentation(to: .pip)
        #expect(abs(backToPiP.effectiveOpacity(atEditorTime: 2.0) - 0.3) < 0.001)
    }

    @Test func conformBoundsToTimelineEndPreservesTieOrderAndSupportsLinkedVsUnlinked() throws {
        // Default isLinked is true; legacy JSON without isLinked decodes linked; false round-trips.
        let defaultOverlay = RecordingVideoOverlay(fileName: "a.mov", displayName: "A", start: 0, fileDuration: 2)
        #expect(defaultOverlay.isLinked)
        let legacyJSON = #"{"fileName":"a.mov","start":0,"trimEnd":2}"#
        let legacyDecoded = try JSONDecoder().decode(RecordingVideoOverlay.self, from: Data(legacyJSON.utf8))
        #expect(legacyDecoded.isLinked)
        var unlinked = defaultOverlay
        unlinked.isLinked = false
        let unlinkedDecoded = try JSONDecoder().decode(RecordingVideoOverlay.self, from: try JSONEncoder().encode(unlinked))
        #expect(!unlinkedDecoded.isLinked)

        // Shortening 10s -> 5s drops overlays pushed past the end (never stranding them at 5...7).
        let old10 = RecordingClipTimeline.full(sourceDuration: 10)
        let short5 = RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: 5)])
        var unlinkedPastEnd = RecordingVideoOverlay(fileName: "u.mov", displayName: "U", start: 6, fileDuration: 2, isLinked: false)
        unlinkedPastEnd.trimEnd = 2
        let linkedPastEnd = RecordingVideoOverlay(fileName: "l.mov", displayName: "L", start: 6, fileDuration: 2, isLinked: true)
        #expect(StudioVideoOverlayLane.conform([unlinkedPastEnd], from: old10, to: short5).isEmpty)
        #expect(StudioVideoOverlayLane.conform([linkedPastEnd], from: old10, to: short5).isEmpty)

        // An overlay straddling the shortened tail (4...6 -> 4...5) clamps cleanly to timeline end.
        let straddling = RecordingVideoOverlay(fileName: "s.mov", displayName: "S", start: 4, fileDuration: 2, isLinked: false)
        let clampedTail = StudioVideoOverlayLane.conform([straddling], from: old10, to: short5)
        #expect(clampedTail.count == 1)
        #expect(abs(clampedTail[0].start - 4) < 0.001)
        #expect(abs(clampedTail[0].end - 5) < 0.001)

        // Lane edits (trimmedTrailing and withSpeed) bound to timelineDuration (5s).
        var atTail = RecordingVideoOverlay(fileName: "t.mov", displayName: "T", start: 3, fileDuration: 8)
        atTail.trimEnd = 5 // 3...5 (2s)
        let extended = StudioVideoOverlayLane.trimmedTrailing(atTail, by: 3, among: [atTail], timelineDuration: 5)
        #expect(extended.end <= 5.0 + 0.001)
        let slowed = StudioVideoOverlayLane.withSpeed(atTail, speed: 0.5, among: [atTail], timelineDuration: 5)
        #expect(slowed.end <= 5.0 + 0.001)

        // Tie-order preservation: two unlinked overlays whose starts map to the same point keep original order
        // even when the earlier one has a lexicographically larger UUID.
        var first = RecordingVideoOverlay(fileName: "first.mov", displayName: "First", start: 2.5, fileDuration: 1, isLinked: false)
        first.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        var second = RecordingVideoOverlay(fileName: "second.mov", displayName: "Second", start: 3.5, fileDuration: 1, isLinked: false)
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let cutMiddle = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 2),
            RecordingClipSegment(sourceStart: 4, sourceEnd: 10)
        ])
        let tied = StudioVideoOverlayLane.conform([first, second], from: old10, to: cutMiddle)
        #expect(tied.count == 2)
        #expect(tied[0].displayName == "First")
        #expect(tied[1].displayName == "Second")
        #expect(abs(tied[0].start - 2) < 0.001)
        #expect(abs(tied[1].start - 3) < 0.001)

        // Linked overlay cuts and speeds with the main video; unlinked stays whole.
        var linkedSpan = RecordingVideoOverlay(fileName: "span.mov", displayName: "Span", start: 1, fileDuration: 6, isLinked: true)
        linkedSpan.fadeIn = 0.5
        linkedSpan.fadeOut = 0.5
        let cut3To5 = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 3),
            RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        ])
        let splitLinked = StudioVideoOverlayLane.conform([linkedSpan], from: old10, to: cut3To5)
        #expect(splitLinked.count == 2)
        #expect(abs(splitLinked[0].start - 1) < 0.001 && abs(splitLinked[0].end - 3) < 0.001)
        #expect(abs(splitLinked[1].start - 3) < 0.001 && abs(splitLinked[1].end - 5) < 0.001)
        #expect(splitLinked[0].fadeIn == 0.5 && splitLinked[0].fadeOut == 0)
        #expect(splitLinked[1].fadeIn == 0 && splitLinked[1].fadeOut == 0.5)

        var unlinkedSpan = linkedSpan
        unlinkedSpan.isLinked = false
        let wholeUnlinked = StudioVideoOverlayLane.conform([unlinkedSpan], from: old10, to: cut3To5)
        #expect(wholeUnlinked.count == 1)
        #expect(abs(wholeUnlinked[0].start - 1) < 0.001 && abs(wholeUnlinked[0].end - 7) < 0.001)

        // Speeding up the main video 2x speeds a linked overlay to 2x as well.
        let fastTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 10, speed: 2)
        ])
        let fastLinked = StudioVideoOverlayLane.conform([linkedSpan], from: old10, to: fastTimeline)
        #expect(fastLinked.count == 1)
        #expect(abs(fastLinked[0].speed - 2.0) < 0.001)
        #expect(abs(fastLinked[0].start - 0.5) < 0.001)
        #expect(abs(fastLinked[0].duration - 3.0) < 0.001)
    }

    @Test func validateRecordingPackageRejectsSymlinkedMastersMediaAndReferences() throws {
        let dir = try makeTempDir("StudioVideoOverlayPackageValidation")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outsideFile = dir.appendingPathComponent("secret.mov")
        try Data("secret".utf8).write(to: outsideFile)

        func makeValidPackage(_ name: String) throws -> URL {
            let pkg = dir.appendingPathComponent(name, isDirectory: true)
            let media = pkg.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try Data("screen".utf8).write(to: pkg.appendingPathComponent("screen.mov"))
            try Data("camera".utf8).write(to: pkg.appendingPathComponent("camera.mov"))
            try Data("audio".utf8).write(to: pkg.appendingPathComponent("replacement.m4a"))
            try Data("music".utf8).write(to: pkg.appendingPathComponent("background-music.m4a"))
            try Data("overlay".utf8).write(to: media.appendingPathComponent("11111111-1111-1111-1111-111111111111.mov"))
            let editJSON = """
            {
                "replacementAudioFileName": "replacement.m4a",
                "backgroundMusic": { "fileName": "background-music.m4a" },
                "videoOverlays": [{ "fileName": "11111111-1111-1111-1111-111111111111.mov" }]
            }
            """
            try Data(editJSON.utf8).write(to: pkg.appendingPathComponent("edit.json"))
            return pkg
        }

        let valid = try makeValidPackage("Valid.sukushorec")
        let resolved = try RecordingPackageMedia.validateRenderInputs(in: valid)
        #expect(resolved.screenURL.lastPathComponent == "screen.mov")
        #expect(resolved.cameraURL?.lastPathComponent == "camera.mov")
        #expect(resolved.replacementAudioURL?.lastPathComponent == "replacement.m4a")
        #expect(resolved.backgroundMusicURL?.lastPathComponent == "background-music.m4a")
        #expect(RecordingVideoOverlayMedia.validateRecordingPackage(at: valid))

        // Symlinked package directory rejected.
        let symPkg = dir.appendingPathComponent("SymPkg.sukushorec")
        try FileManager.default.createSymbolicLink(at: symPkg, withDestinationURL: valid)
        #expect(throws: RecordingPackageMedia.ValidationError.invalidPackage("SymPkg.sukushorec")) {
            try RecordingPackageMedia.validateRenderInputs(in: symPkg)
        }

        // Symlinked screen.mov rejected.
        let symScreen = try makeValidPackage("SymScreen.sukushorec")
        try FileManager.default.removeItem(at: symScreen.appendingPathComponent("screen.mov"))
        try FileManager.default.createSymbolicLink(at: symScreen.appendingPathComponent("screen.mov"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("screen.mov")) {
            try RecordingPackageMedia.validateRenderInputs(in: symScreen)
        }

        // Normal screen.mov + symlinked camera.mov rejected (exact Finished-render repro).
        let symCam = try makeValidPackage("SymCam.sukushorec")
        try FileManager.default.removeItem(at: symCam.appendingPathComponent("camera.mov"))
        try FileManager.default.createSymbolicLink(at: symCam.appendingPathComponent("camera.mov"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("camera.mov")) {
            try RecordingPackageMedia.validateRenderInputs(in: symCam)
        }
        #expect(!RecordingVideoOverlayMedia.validateRecordingPackage(at: symCam))

        // Symlinked edit.draft.json and edit.json sidecars rejected.
        let symDraft = try makeValidPackage("SymDraft.sukushorec")
        try FileManager.default.createSymbolicLink(at: symDraft.appendingPathComponent("edit.draft.json"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("edit.draft.json")) {
            try RecordingPackageMedia.validateRenderInputs(in: symDraft)
        }

        let symEdit = try makeValidPackage("SymEdit.sukushorec")
        try FileManager.default.removeItem(at: symEdit.appendingPathComponent("edit.json"))
        try FileManager.default.createSymbolicLink(at: symEdit.appendingPathComponent("edit.json"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("edit.json")) {
            try RecordingPackageMedia.validateRenderInputs(in: symEdit)
        }

        // Symlinked render-cache stamp (`render.json`) and cached deliverable (`<name>.mov`) rejected.
        let symStamp = try makeValidPackage("SymStamp.sukushorec")
        try FileManager.default.createSymbolicLink(at: symStamp.appendingPathComponent("render.json"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("render.json")) {
            try RecordingPackageMedia.validateRenderInputs(in: symStamp)
        }

        let symCached = try makeValidPackage("SymCached.sukushorec")
        try FileManager.default.createSymbolicLink(at: symCached.appendingPathComponent("SymCached.mov"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("SymCached.mov")) {
            try RecordingPackageMedia.validateRenderInputs(in: symCached)
        }

        // Symlinked isolated microphone audio rejected.
        let symIsolated = try makeValidPackage("SymIsolated.sukushorec")
        try FileManager.default.createSymbolicLink(at: symIsolated.appendingPathComponent("mic-isolated-v2.m4a"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("mic-isolated-v2.m4a")) {
            try RecordingPackageMedia.validateRenderInputs(in: symIsolated)
        }

        // `..` traversal in replacementAudioFileName and backgroundMusic.fileName rejected.
        let traverseAudio = try makeValidPackage("TraverseAudio.sukushorec")
        try Data(#"{"replacementAudioFileName":"../secret.mov"}"#.utf8)
            .write(to: traverseAudio.appendingPathComponent("edit.json"))
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("../secret.mov")) {
            try RecordingPackageMedia.validateRenderInputs(in: traverseAudio)
        }

        let traverseMusic = try makeValidPackage("TraverseMusic.sukushorec")
        try Data(#"{"backgroundMusic":{"fileName":"../secret.mov"}}"#.utf8)
            .write(to: traverseMusic.appendingPathComponent("edit.json"))
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("../secret.mov")) {
            try RecordingPackageMedia.validateRenderInputs(in: traverseMusic)
        }

        // Symlinked replacement audio rejected.
        let symAudio = try makeValidPackage("SymAudio.sukushorec")
        try FileManager.default.removeItem(at: symAudio.appendingPathComponent("replacement.m4a"))
        try FileManager.default.createSymbolicLink(at: symAudio.appendingPathComponent("replacement.m4a"), withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("replacement.m4a")) {
            try RecordingPackageMedia.validateRenderInputs(in: symAudio)
        }

        // Symlinked media directory rejected.
        let symMedia = try makeValidPackage("SymMedia.sukushorec")
        let outsideDir = dir.appendingPathComponent("outside-media", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: symMedia.appendingPathComponent("media"))
        try FileManager.default.createSymbolicLink(at: symMedia.appendingPathComponent("media"), withDestinationURL: outsideDir)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("media")) {
            try RecordingPackageMedia.validateRenderInputs(in: symMedia)
        }

        // Symlinked referenced overlay inside media rejected.
        let symOverlay = try makeValidPackage("SymOverlay.sukushorec")
        let overlayPath = symOverlay.appendingPathComponent("media/11111111-1111-1111-1111-111111111111.mov")
        try FileManager.default.removeItem(at: overlayPath)
        try FileManager.default.createSymbolicLink(at: overlayPath, withDestinationURL: outsideFile)
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile("11111111-1111-1111-1111-111111111111.mov")) {
            try RecordingPackageMedia.validateRenderInputs(in: symOverlay)
        }
    }

    // MARK: - Helpers

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSolidMovie(
        to url: URL,
        width: Int,
        height: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        durationSeconds: Double
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        let count = max(2, Int((durationSeconds * Double(fps)).rounded()))
        for frame in 0..<count {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try #require(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bpr + x * 4
                        base[offset] = b
                        base[offset + 1] = g
                        base[offset + 2] = r
                        base[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: durationSeconds, preferredTimescale: 600))
        await withCheckedContinuation { cont in writer.finishWriting { cont.resume() } }
        #expect(writer.status == .completed)
    }

    private func writeSplitColorMovie(to url: URL, width: Int, height: Int, transform: CGAffineTransform) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<5 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try #require(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bpr + x * 4
                        let isLeft = x < width / 2
                        base[offset] = isLeft ? 20 : 230
                        base[offset + 1] = 20
                        base[offset + 2] = isLeft ? 230 : 20
                        base[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 5, timescale: 10))
        await withCheckedContinuation { cont in writer.finishWriting { cont.resume() } }
        #expect(writer.status == .completed)
    }

    private func makeToneMovie(
        in dir: URL,
        name: String,
        frequency: Double,
        amplitude: Double,
        duration: TimeInterval
    ) async throws -> URL {
        // Write a real .mov with a video track and a 48 kHz mono tone audio track.
        let wavURL = dir.appendingPathComponent("tmp-\(UUID().uuidString).wav")
        let silentVideoURL = dir.appendingPathComponent("tmp-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: silentVideoURL)
        }
        try await writeSolidMovie(to: silentVideoURL, width: 32, height: 32, r: 80, g: 140, b: 220, durationSeconds: duration)

        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                channel[i] = Float(amplitude * sin(2 * .pi * frequency * t))
            }
        }
        let wavFile = try AVAudioFile(forWriting: wavURL, settings: format.settings)
        try wavFile.write(from: buffer)
        wavFile.close()

        let composition = AVMutableComposition()
        let vAsset = AVURLAsset(url: silentVideoURL)
        let aAsset = AVURLAsset(url: wavURL)
        let vDuration = try await vAsset.load(.duration)
        let aDuration = try await aAsset.load(.duration)
        if let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
           let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compV.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: vTrack, at: .zero)
        }
        if let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first,
           let compA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compA.insertTimeRange(CMTimeRange(start: .zero, duration: aDuration), of: aTrack, at: .zero)
        }
        let outURL = dir.appendingPathComponent(name)
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: outURL, as: .mov)
        return outURL
    }

    private func renderMonoSamples(asset: AVAsset, mix: AVAudioMix?, duration: TimeInterval) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output)
        #expect(reader.startReading())
        var result: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
               let pointer {
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                    result.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / 4))
                }
            }
        }
        return result
    }

    private func peakAmplitude(in samples: [Float], from start: TimeInterval, to end: TimeInterval) -> Float {
        let sampleRate = 48_000.0
        let i0 = max(0, Int(start * sampleRate))
        let i1 = min(samples.count, Int(end * sampleRate))
        guard i0 < i1 else { return 0 }
        var peak: Float = 0
        for i in i0..<i1 { peak = max(peak, abs(samples[i])) }
        return peak
    }

    private func renderCanvas(
        size: CGSize,
        colorSpace: CGColorSpace,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        // Flip into top-down canvas space matching RecordingVideoOverlayRenderer.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        return try #require(ctx.makeImage())
    }

    private func pixelRGB(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        if let ctx = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) {
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (bytes[0], bytes[1], bytes[2])
    }
}
