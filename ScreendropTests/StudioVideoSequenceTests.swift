import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

struct StudioVideoSequenceTests {
    // MARK: - Codable & Backward Compatibility

    @Test func legacyClipMarkerAndChapterDecodeCleanlyWithoutMediaFileName() throws {
        // Legacy v6 payloads omit mediaFileName, displayName, sourceDuration, contentMode.
        let clipJSON = Data(#"{"id":"11111111-1111-1111-1111-111111111111","sourceStart":1.0,"sourceEnd":5.0,"speed":2.0}"#.utf8)
        let clip = try JSONDecoder().decode(RecordingClipSegment.self, from: clipJSON)
        #expect(clip.isPrimaryRecording)
        #expect(clip.mediaFileName == nil)
        #expect(clip.displayName == nil)
        #expect(clip.sourceDuration == nil)
        #expect(clip.contentMode == nil)
        #expect(clip.effectiveContentMode == .fit)
        #expect(clip.sourceKey == "")

        let markerJSON = Data(#"{"id":"22222222-2222-2222-2222-222222222222","sourceTime":3.5,"note":"Check"}"#.utf8)
        let marker = try JSONDecoder().decode(RecordingMarker.self, from: markerJSON)
        #expect(marker.mediaFileName == nil)
        #expect(abs(marker.sourceTime - 3.5) < 0.0001)
        #expect(marker.note == "Check")

        let chapterJSON = Data(#"{"id":"33333333-3333-3333-3333-333333333333","title":"Intro","start":0.5}"#.utf8)
        let chapter = try JSONDecoder().decode(RecordingChapter.self, from: chapterJSON)
        #expect(chapter.mediaFileName == nil)
        #expect(chapter.title == "Intro")

        // Round-trip imported clip keeps all optional metadata cleanly.
        let imported = RecordingClipSegment(
            sourceStart: 0.5,
            sourceEnd: 4.5,
            speed: 1.5,
            mediaFileName: "clip-1.mov",
            displayName: "Phone Demo",
            sourceDuration: 6.0,
            contentMode: .fill
        )
        let encoded = try JSONEncoder().encode(imported)
        let decoded = try JSONDecoder().decode(RecordingClipSegment.self, from: encoded)
        #expect(decoded == imported)
        #expect(!decoded.isPrimaryRecording)
        #expect(decoded.sourceKey == "clip-1.mov")
        #expect(decoded.effectiveContentMode == .fill)
    }

    // MARK: - Timeline Normalization, Repetition & Hard Cuts

    @Test func multiSourceNormalizationAllowsRepeatedImportedClipsAndMarksHardCuts() {
        let primary = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let phone1 = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 4,
            mediaFileName: "phone.mov",
            displayName: "Phone",
            sourceDuration: 4
        )
        // Repeating the same imported file twice in the same sequence is allowed.
        let phone2 = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 3,
            mediaFileName: "phone.mov",
            displayName: "Phone",
            sourceDuration: 4
        )
        let primaryTail = RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        let raw = RecordingClipTimeline(segments: [primary, phone1, phone2, primaryTail])

        let normalized = raw.normalized(to: 10)
        #expect(normalized.segments.count == 4)
        #expect(normalized.hasImportedClips)
        #expect(!normalized.isUnedited(sourceDuration: 10))
        #expect(!normalized.isInRecordingOrder)
        #expect(abs(normalized.duration - 17) < 0.0001)

        // Every source change is a hard cut: primary->phone1 (5s), phone1->phone2 (9s, 4->0 backward), phone2->primaryTail (12s).
        #expect(normalized.hardCuts.count == 3)
        #expect(abs(normalized.hardCuts[0] - 5) < 0.0001)
        #expect(abs(normalized.hardCuts[1] - 9) < 0.0001)
        #expect(abs(normalized.hardCuts[2] - 12) < 0.0001)

        // Single imported clip covering 0..10 is never considered "unedited" primary.
        let importedOnly = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 10, mediaFileName: "other.mov", sourceDuration: 10)
        ])
        #expect(!importedOnly.isUnedited(sourceDuration: 10))
        #expect(importedOnly.isPrimaryRecording(at: 2) == false)
    }

    // MARK: - Primary-Only Gating (Zoom, Pointer, Viewport, Redactions)

    @Test func primaryOnlyEffectsStayDisabledOnImportedClipSpans() {
        let primaryA = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let imported = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 4,
            mediaFileName: "broll.mov",
            displayName: "B-Roll",
            sourceDuration: 4
        )
        let primaryB = RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        let timeline = RecordingClipTimeline(segments: [primaryA, imported, primaryB])

        // Timeline queries for primary source events ignore the imported span (editor 5..9).
        #expect(timeline.isPrimaryRecording(at: 2.5))
        #expect(!timeline.isPrimaryRecording(at: 7.0))
        #expect(timeline.isPrimaryRecording(at: 11.0))

        let eventEditorTime = timeline.editorTime(forSourceEventTime: 6.0)
        #expect(eventEditorTime != nil && abs(eventEditorTime! - 10.0) < 0.0001)

        // Zoom lane treats imported clip spans as non-zoomable occupied barriers.
        let occupied = studioOccupiedLaneSpans(cues: [], clipTimeline: timeline)
        #expect(occupied.contains { abs($0.editorStart - 5) < 0.001 && abs($0.editorEnd - 9) < 0.001 })

        // Redactions never cover imported clips.
        let redaction = RecordingRedaction(
            start: 0,
            end: 10,
            rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            mode: .pixelate
        )
        #expect(redaction.covers(editorTime: 2.5, frameDuration: 1.0 / 30.0, timeline: timeline))
        #expect(!redaction.covers(editorTime: 7.0, frameDuration: 1.0 / 30.0, timeline: timeline))
        #expect(redaction.covers(editorTime: 11.0, frameDuration: 1.0 / 30.0, timeline: timeline))

        let redactionSource = RecordingRedactionPreviewSource()
        redactionSource.update(redactions: [redaction], clipTimeline: timeline)
        #expect(!redactionSource.activeRedactions(atEditorTime: 2.5, frameDuration: 1.0 / 30.0).isEmpty)
        #expect(redactionSource.activeRedactions(atEditorTime: 7.0, frameDuration: 1.0 / 30.0).isEmpty)
        #expect(!redactionSource.activeRedactions(atEditorTime: 11.0, frameDuration: 1.0 / 30.0).isEmpty)
    }

    // MARK: - Markers, Chapters, Trim Bounds & Insertion Index

    @Test func markersAndChaptersFollowImportedClipsAcrossReordersAndSplits() throws {
        let primary = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let imported = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 6,
            mediaFileName: "demo.mov",
            displayName: "Demo",
            sourceDuration: 6
        )
        let timeline = RecordingClipTimeline(segments: [primary, imported])

        // Anchor a marker at editor time 8.0 (3.0s into demo.mov).
        let anchor = StudioEditing.markerAnchor(at: 8.0, in: timeline)
        #expect(anchor.mediaFileName == "demo.mov")
        #expect(abs(anchor.sourceTime - 3.0) < 0.0001)

        let primaryMarker = RecordingMarker(sourceTime: 2.0)
        let importedMarker = RecordingMarker(sourceTime: anchor.sourceTime, mediaFileName: anchor.mediaFileName)
        let beforeReorder = StudioEditing.markerEditorTimes([primaryMarker, importedMarker], in: timeline)
        #expect(beforeReorder.count == 2)
        #expect(abs(beforeReorder[0].time - 2.0) < 0.0001)
        #expect(abs(beforeReorder[1].time - 8.0) < 0.0001)

        // Move imported clip before primary: imported marker moves to 3.0, primary marker moves to 8.0.
        let reordered = RecordingClipTimeline(segments: [imported, primary])
        let afterReorder = StudioEditing.markerEditorTimes([primaryMarker, importedMarker], in: reordered)
        #expect(afterReorder.count == 2)
        #expect(abs(afterReorder[0].time - 3.0) < 0.0001)
        #expect(abs(afterReorder[1].time - 8.0) < 0.0001)

        // Chapters on imported clips also follow reorder cleanly.
        let chapters = [
            RecordingChapter(title: "Desktop", start: 1.0, mediaFileName: nil),
            RecordingChapter(title: "Phone", start: 2.0, mediaFileName: "demo.mov")
        ]
        let mapped = RecordingChapterPlanner.mapped(chapters, through: reordered)
        #expect(mapped.count == 2)
        #expect(mapped[0].title == "Phone")
        #expect(abs(mapped[0].start - 2.0) < 0.0001)
        #expect(mapped[1].title == "Desktop")
        #expect(abs(mapped[1].start - 7.0) < 0.0001)
    }

    @Test func trimBoundsAndInsertionIndexRespectMultiSourceBoundaries() throws {
        let p1 = RecordingClipSegment(sourceStart: 0, sourceEnd: 4)
        let imp = RecordingClipSegment(
            sourceStart: 1,
            sourceEnd: 5,
            mediaFileName: "clip.mov",
            displayName: "Clip",
            sourceDuration: 8
        )
        let p2 = RecordingClipSegment(sourceStart: 6, sourceEnd: 10)
        let timeline = RecordingClipTimeline(segments: [p1, imp, p2])

        // Primary clip p1's next primary neighbor is p2 (starting at 6), not imp!
        let p1Bounds = try #require(StudioEditing.trimBounds(forClipID: p1.id, in: timeline, sourceDuration: 10))
        #expect(abs(p1Bounds.previousEnd - 0) < 0.0001)
        #expect(abs(p1Bounds.nextStart - 6) < 0.0001)

        // Imported clip trims independently within its own 0..8 source duration.
        let impBounds = try #require(StudioEditing.trimBounds(forClipID: imp.id, in: timeline, sourceDuration: 10))
        #expect(abs(impBounds.previousEnd - 0) < 0.0001)
        #expect(abs(impBounds.nextStart - 8) < 0.0001)

        // Insertion index: after selected clip if selected; nearest boundary inside multi-clip cut; else end.
        #expect(StudioEditing.videoClipInsertionIndex(selectedClipID: p1.id, playheadTime: 0, in: timeline) == 1)
        #expect(StudioEditing.videoClipInsertionIndex(selectedClipID: nil, playheadTime: 4.0, in: timeline) == 1)
        #expect(StudioEditing.videoClipInsertionIndex(selectedClipID: nil, playheadTime: 6.0, in: timeline) == 2)
        #expect(StudioEditing.videoClipInsertionIndex(selectedClipID: nil, playheadTime: 0.0, in: timeline) == 3)
        #expect(StudioEditing.videoClipInsertionIndex(selectedClipID: nil, playheadTime: 12.0, in: timeline) == 3)
    }

    // MARK: - Orientation, Target Rect & Fit/Fill Transform Math

    @Test func displaySizeAndPlacementTransformHandleAllFourRotationsFitAndFill() {
        let rawSize = CGSize(width: 1920, height: 1080)
        let renderRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // 90° CW portrait iPhone video: natural 1920x1080 rotated 90° -> display 1080x1920.
        let rot90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let disp90 = RecordingCompositionBuilder.displaySize(naturalSize: rawSize, preferredTransform: rot90)
        #expect(abs(disp90.width - 1080) < 0.5)
        #expect(abs(disp90.height - 1920) < 0.5)

        // Fit inside 1920x1080: scale = 1080/1920 = 0.5625, display width = 607.5, centered x = 656.25.
        let fit90 = RecordingCompositionBuilder.placementTransform(
            naturalSize: rawSize,
            preferredTransform: rot90,
            in: renderRect,
            contentMode: .fit
        )
        let fitBox = CGRect(origin: .zero, size: rawSize).applying(fit90)
        #expect(abs(fitBox.width - 607.5) < 0.5)
        #expect(abs(fitBox.height - 1080) < 0.5)
        #expect(abs(fitBox.midX - 960) < 0.5)
        #expect(abs(fitBox.midY - 540) < 0.5)

        // Fill inside 1920x1080: scale = 1920/1080 = 1.7778, display height = 3413.33, centered.
        let fill90 = RecordingCompositionBuilder.placementTransform(
            naturalSize: rawSize,
            preferredTransform: rot90,
            in: renderRect,
            contentMode: .fill
        )
        let fillBox = CGRect(origin: .zero, size: rawSize).applying(fill90)
        #expect(abs(fillBox.width - 1920) < 0.5)
        #expect(abs(fillBox.height - 3413.333) < 1.0)
        #expect(abs(fillBox.midX - 960) < 0.5)
        #expect(abs(fillBox.midY - 540) < 0.5)

        // 180° and 270° rotations with zero/negative translations still normalize to exact centered bounds.
        let rot180 = CGAffineTransform(rotationAngle: .pi)
        let rot270 = CGAffineTransform(rotationAngle: -.pi / 2)
        for transform in [CGAffineTransform.identity, rot90, rot180, rot270] {
            let placed = RecordingCompositionBuilder.placementTransform(
                naturalSize: rawSize,
                preferredTransform: transform,
                in: renderRect,
                contentMode: .fit
            )
            let box = CGRect(origin: .zero, size: rawSize).applying(placed)
            #expect(abs(box.midX - renderRect.midX) < 0.5)
            #expect(abs(box.midY - renderRect.midY) < 0.5)
            #expect(box.minX >= renderRect.minX - 0.5)
            #expect(box.minY >= renderRect.minY - 0.5)
            #expect(box.maxX <= renderRect.maxX + 0.5)
            #expect(box.maxY <= renderRect.maxY + 0.5)
        }

        // Visible card rect inside renderSize when reframe/Fill crops horizontally (e.g. 9:16 card from 16:9 render).
        let visible = RecordingCompositionBuilder.visibleCardRect(
            renderSize: CGSize(width: 1920, height: 1080),
            cardSize: CGSize(width: 607.5, height: 1080),
            contentFillSize: CGSize(width: 1920, height: 1080)
        )
        #expect(abs(visible.width - 607.5) < 0.5)
        #expect(abs(visible.height - 1080) < 0.5)
        #expect(abs(visible.midX - 960) < 0.5)
    }

    // MARK: - Audio Conform & Composition

    @Test func audioConformAndDetachHandleImportedClipsAndRepeatedClips() throws {
        let primary = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let importedA = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 6,
            mediaFileName: "phone.mov",
            displayName: "Phone",
            sourceDuration: 6
        )
        let importedB = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 4,
            mediaFileName: "phone.mov",
            displayName: "Phone",
            sourceDuration: 6
        )
        let old = RecordingClipTimeline(segments: [primary, importedA, importedB])

        // Detach audio from importedA (editor 5..11).
        let detached = try #require(StudioAudioComposer.detachedClips(
            for: importedA,
            editorStart: 5,
            editorEnd: 11,
            projectVolume: 1.0,
            sync: nil,
            replacementFileName: nil,
            replacementDisplayName: nil,
            replacementDuration: 0,
            recordingDisplayName: "Recording audio",
            sourceDuration: 5,
            hasRecording: true,
            hasImportedAudio: true,
            lane: 0
        ))
        #expect(detached.count == 1)
        #expect(detached[0].source == .file)
        #expect(detached[0].fileName == "phone.mov")
        #expect(detached[0].isLinked)
        #expect(abs(detached[0].start - 5) < 0.001)
        #expect(abs(detached[0].duration - 6) < 0.001)

        // Delete middle 2..4 of importedA (editor 7..9); importedB is untouched and must NOT steal detached audio.
        let cut = try #require(old.removingEditorRange(7...9))
        let conformed = StudioAudioConform.conform(detached, from: old, to: cut)
        #expect(conformed.count == 2)
        #expect(abs(conformed[0].start - 5) < 0.001)
        #expect(abs(conformed[0].duration - 2) < 0.001)
        #expect(abs(conformed[1].start - 7) < 0.001)
        #expect(abs(conformed[1].duration - 2) < 0.001)
        #expect(abs(conformed[1].trimStart - 4) < 0.001)

        // RecordingAudioSync.flat only maps primary segments, never imported segments.
        let sync = RecordingAudioSync.flat(over: old)
        #expect(sync.spans.count == 1)
        #expect(abs(sync.spans[0].sourceStart - 0) < 0.001)
        #expect(abs(sync.spans[0].sourceEnd - 5) < 0.001)
    }

    // MARK: - Thumbnail Store Budget & Eviction

    @Test func thumbnailStoreKeysBySourceEnforcesByteBudgetAndEvictsDeletedSources() {
        let store = RecordingTimelineThumbnailStore(byteLimit: 1024 * 64)
        let primaryURL = URL(fileURLWithPath: "/tmp/nonexistent-primary.mov")
        let importedURL = URL(fileURLWithPath: "/tmp/nonexistent-imported.mov")
        store.prepare(url: primaryURL, duration: 10)
        store.registerSource(key: "phone.mov", url: importedURL, duration: 4)

        let primaryGrid = store.grid(forTargetSpan: 1.0, sourceKey: "")
        let importedGrid = store.grid(forTargetSpan: 1.0, sourceKey: "phone.mov")
        #expect(primaryGrid.spacing > 0)
        #expect(importedGrid.spacing > 0)

        // Evicting deleted imported source removes its metadata cleanly without touching primary.
        store.syncImportedSources(keeping: [])
        #expect(store.grid(forTargetSpan: 1.0, sourceKey: "phone.mov").spacing == 0)
        #expect(store.grid(forTargetSpan: 1.0, sourceKey: "").spacing > 0)

        // releaseResources clears everything.
        store.releaseResources()
        #expect(store.cachedBytes == 0)
        #expect(store.grid(forTargetSpan: 1.0, sourceKey: "").spacing == 0)
    }

    // MARK: - Real Synthetic Multi-Source Composition & Pixel Verification

    @Test func syntheticLandscapePlusRotatedPortraitCompositionRendersUprightFitAndFillWithAudio() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVideoSequenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("primary.mov")
        let portraitURL = tempDir.appendingPathComponent("phone-portrait.mov")

        // 1. Write 1.0s landscape primary clip (320x180, solid blue) + 440 Hz tone.
        try await Self.writeSyntheticMovie(
            to: primaryURL,
            size: CGSize(width: 320, height: 180),
            duration: 1.0,
            color: (r: 30, g: 90, b: 220),
            preferredTransform: .identity,
            toneHz: 440
        )

        // 2. Write 1.0s phone clip stored 320x180 with 90° CW preferredTransform (display 180x320 portrait, solid green) + 880 Hz tone.
        let rot90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        try await Self.writeSyntheticMovie(
            to: portraitURL,
            size: CGSize(width: 320, height: 180),
            duration: 1.0,
            color: (r: 30, g: 210, b: 80),
            preferredTransform: rot90,
            toneHz: 880
        )

        let primarySource = try await StudioVideoSource.load(url: primaryURL)
        let portraitSource = try await StudioVideoSource.load(url: portraitURL)
        #expect(abs(primarySource.displaySize.width - 320) < 1)
        #expect(abs(primarySource.displaySize.height - 180) < 1)
        #expect(abs(portraitSource.displaySize.width - 180) < 1)
        #expect(abs(portraitSource.displaySize.height - 320) < 1)

        // Build FIT composition: primary (0..1s) + portrait Fit (1..2s).
        let primarySeg = RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0)
        let portraitFitSeg = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 1.0,
            mediaFileName: "phone-portrait.mov",
            displayName: "Phone",
            sourceDuration: 1.0,
            contentMode: .fit
        )
        let fitTimeline = RecordingClipTimeline(segments: [primarySeg, portraitFitSeg])
        let (fitComposition, fitVideoComp) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
            primarySource: primarySource,
            importedSources: ["phone-portrait.mov": portraitSource],
            timeline: fitTimeline,
            renderSize: primarySource.displaySize
        )
        #expect(abs(fitVideoComp.renderSize.width - 320) < 1)
        #expect(abs(fitVideoComp.renderSize.height - 180) < 1)

        // Render frame at t=0.5s (primary blue) and t=1.5s (portrait green letterboxed).
        let fitGen = AVAssetImageGenerator(asset: fitComposition)
        fitGen.videoComposition = fitVideoComp
        fitGen.requestedTimeToleranceBefore = .zero
        fitGen.requestedTimeToleranceAfter = .zero

        let primaryImg = try await fitGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let primaryCenter = Self.rgbPixel(in: primaryImg, x: primaryImg.width / 2, y: primaryImg.height / 2)
        #expect(primaryCenter.b > 150 && primaryCenter.g < 140)

        let fitImg = try await fitGen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        // Left pillarbox (x=10) must be black; center (x=width/2) must be green.
        let fitLeft = Self.rgbPixel(in: fitImg, x: 10, y: fitImg.height / 2)
        let fitCenter = Self.rgbPixel(in: fitImg, x: fitImg.width / 2, y: fitImg.height / 2)
        #expect(fitLeft.r < 20 && fitLeft.g < 20 && fitLeft.b < 20)
        #expect(fitCenter.g > 150 && fitCenter.r < 90)

        // Build FILL composition: portrait Fill fills the entire 320x180 frame (no black bars).
        var portraitFillSeg = portraitFitSeg
        portraitFillSeg.contentMode = .fill
        let fillTimeline = RecordingClipTimeline(segments: [primarySeg, portraitFillSeg])
        let (fillComposition, fillVideoComp) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
            primarySource: primarySource,
            importedSources: ["phone-portrait.mov": portraitSource],
            timeline: fillTimeline,
            renderSize: primarySource.displaySize
        )
        let fillGen = AVAssetImageGenerator(asset: fillComposition)
        fillGen.videoComposition = fillVideoComp
        fillGen.requestedTimeToleranceBefore = .zero
        fillGen.requestedTimeToleranceAfter = .zero

        let fillImg = try await fillGen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        let fillLeft = Self.rgbPixel(in: fillImg, x: 10, y: fillImg.height / 2)
        let fillCenter = Self.rgbPixel(in: fillImg, x: fillImg.width / 2, y: fillImg.height / 2)
        #expect(fillLeft.g > 150 && fillLeft.r < 90)
        #expect(fillCenter.g > 150 && fillCenter.r < 90)

        // Verify audio composition mixes both primary and imported audio cleanly without replacing imported clip's audio.
        let sources = try await StudioAudioSources.load(
            screenAsset: primarySource.asset,
            replacementURL: nil,
            clips: [],
            mediaDirectory: tempDir,
            timeline: fitTimeline
        )
        #expect(!sources.recording.isEmpty)
        #expect(sources.files["phone-portrait.mov"]?.isEmpty == false)

        let audioPlan = StudioAudioPlan(
            timeline: fitTimeline,
            sync: nil,
            clips: [],
            volume: 1.0
        )
        let layout = try StudioAudioComposer.addStrict(audioPlan, sources: sources, to: fitComposition)
        #expect(layout.placements.count == 2)
        #expect(!fitComposition.tracks(withMediaType: .audio).isEmpty)
    }

    // MARK: - Synthetic Movie Helper

    private static func writeSyntheticMovie(
        to url: URL,
        size: CGSize,
        duration: TimeInterval,
        color: (r: UInt8, g: UInt8, b: UInt8),
        preferredTransform: CGAffineTransform,
        toneHz: Double
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = preferredTransform
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
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 1)
        }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let totalFrames = max(1, Int((duration * Double(fps)).rounded()))
        for frame in 0..<totalFrames {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let width = CVPixelBufferGetWidth(pixelBuffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        row[x * 4 + 0] = color.b
                        row[x * 4 + 1] = color.g
                        row[x * 4 + 2] = color.r
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
        videoInput.markAsFinished()

        let totalSamples = Int((duration * sampleRate).rounded())
        var pcm = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let value = sin(2.0 * .pi * toneHz * Double(i) / sampleRate) * 0.25
            pcm[i] = Int16(value * Double(Int16.max))
        }
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
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        let dataSize = pcm.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        if let blockBuffer {
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    CMBlockBufferReplaceDataBytes(
                        with: base,
                        blockBuffer: blockBuffer,
                        offsetIntoDestination: 0,
                        dataLength: dataSize
                    )
                }
            }
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: .zero,
                decodeTimeStamp: .invalid
            )
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDesc,
                sampleCount: totalSamples,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
            if let sampleBuffer {
                while !audioInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                audioInput.append(sampleBuffer)
            }
        }
        audioInput.markAsFinished()

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 2)
        }
    }

    private static func rgbPixel(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let clampedX = min(max(x, 0), image.width - 1)
        let clampedY = min(max(y, 0), image.height - 1)
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: -clampedX, y: -(image.height - 1 - clampedY), width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }
}
