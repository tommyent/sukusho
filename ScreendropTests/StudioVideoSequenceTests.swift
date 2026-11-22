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
        let (fitComposition, fitVideoComp, fitTimeMap) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
            primarySource: primarySource,
            importedSources: ["phone-portrait.mov": portraitSource],
            timeline: fitTimeline,
            renderSize: primarySource.displaySize
        )
        #expect(abs(fitVideoComp.renderSize.width - 320) < 1)
        #expect(abs(fitVideoComp.renderSize.height - 180) < 1)
        #expect(fitTimeMap.entries.count == 2)

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
        let (fillComposition, fillVideoComp, _) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
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

    // MARK: - Round 2 Regressions (Findings 1, 3, 6)

    @Test func fractionalCutPreviewAndCompositionReaderMaskPrimaryWithZeroDetailLeak() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVideoSeqPrivacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("primary-checker.mov")
        let importURL = tempDir.appendingPathComponent("flat-import.mov")

        // High-contrast 4x4 checkerboard primary (raw detail ~120+, masked ~0).
        try await Self.writeCheckerboardMovie(
            to: primaryURL,
            size: CGSize(width: 160, height: 120),
            duration: 2.0
        )
        // Flat solid-blue import (detail ~0).
        try await Self.writeSyntheticMovie(
            to: importURL,
            size: CGSize(width: 160, height: 120),
            duration: 1.0,
            color: (r: 30, g: 110, b: 220),
            preferredTransform: .identity,
            toneHz: 440
        )

        let primarySource = try await StudioVideoSource.load(url: primaryURL)
        let importSource = try await StudioVideoSource.load(url: importURL)

        // Confirm raw primary has high checkerboard detail before masking.
        let rawGen = AVAssetImageGenerator(asset: primarySource.asset)
        rawGen.requestedTimeToleranceBefore = .zero
        rawGen.requestedTimeToleranceAfter = .zero
        let rawImg = try await rawGen.image(at: CMTime(seconds: 0.55, preferredTimescale: 600)).image
        let rawDetail = Self.detailScore(of: rawImg)
        #expect(rawDetail > 50)

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

        // Fixture 1: 3 x 0.2505s + 0.25s imports, masked primary 0.50..<0.75, trailing import.
        let fixture1 = RecordingClipTimeline(segments: [
            makeImport(0.2505),
            makeImport(0.2505),
            makeImport(0.2505),
            makeImport(0.25),
            RecordingClipSegment(sourceStart: 0.50, sourceEnd: 0.75),
            makeImport(0.25)
        ])

        // Fixture 2: 16 x 0.2511s imports, masked primary 0.50..<0.75, trailing import.
        let fixture2 = RecordingClipTimeline(
            segments: (0..<16).map { _ in makeImport(0.2511) } + [
                RecordingClipSegment(sourceStart: 0.50, sourceEnd: 0.75),
                makeImport(0.25)
            ]
        )

        // Fixture 3: split primary + split/reordered fractional imports producing the same cut edges.
        let baseImport = makeImport(0.7515)
        let baseTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0.50, sourceEnd: 0.75),
            baseImport,
            makeImport(0.25)
        ])
        let split1 = try #require(baseTimeline.split(at: 0.25 + 0.2505)).timeline
        let split2 = try #require(split1.split(at: 0.25 + 0.5010)).timeline
        // Move the primary clip (index 0) after the four fractional import pieces (index 4).
        let fixture3 = try #require(split2.moving(segmentID: split2.segments[0].id, to: 4))

        for timeline in [fixture1, fixture2, fixture3] {
            let redactionSource = RecordingRedactionPreviewSource()
            redactionSource.update(redactions: [fullMask], clipTimeline: timeline)

            let (composition, videoComposition, timeMap) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
                primarySource: primarySource,
                importedSources: ["flat-import.mov": importSource],
                timeline: timeline,
                renderSize: primarySource.displaySize,
                redactionSource: redactionSource
            )
            let primaryEntry = try #require(timeMap.entries.first { $0.isPrimaryRecording })

            // Preview compositor: check first cut frame, next frame, mid frame, and last frame of primary.
            let previewGen = AVAssetImageGenerator(asset: composition)
            previewGen.videoComposition = videoComposition
            previewGen.requestedTimeToleranceBefore = .zero
            previewGen.requestedTimeToleranceAfter = .zero

            let frameStep = CMTime(value: 1, timescale: 60)
            let checkTimes = [
                primaryEntry.editorRange.start,
                primaryEntry.editorRange.start + frameStep,
                primaryEntry.editorRange.start + CMTime(seconds: primaryEntry.editorRange.duration.seconds / 2, preferredTimescale: 600),
                primaryEntry.editorRange.end - frameStep
            ]
            for time in checkTimes {
                let image = try await previewGen.image(at: time).image
                let detail = Self.detailScore(of: image)
                #expect(detail < 5.0, "Preview leaked checkerboard detail (\(detail)) at t=\(time.seconds)")
            }

            // Reader with `timeMap.timeRange` must NEVER fail with AVErrorInvalidVideoComposition (-11841),
            // and every sample inside `primaryEntry` must be masked.
            let reader = try AVAssetReader(asset: composition)
            let tracks = try await composition.loadTracks(withMediaType: .video)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: tracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.videoComposition = videoComposition
            reader.add(output)
            reader.timeRange = timeMap.timeRange
            #expect(reader.startReading())

            var primarySamplesChecked = 0
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard let entry = timeMap.entry(at: pts),
                      entry.isPrimaryRecording,
                      let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                primarySamplesChecked += 1
                let detail = Self.detailScore(of: buffer)
                #expect(detail < 5.0, "Reader sample leaked detail (\(detail)) at t=\(pts.seconds)")
            }
            #expect(reader.status == .completed, "Reader failed with \(String(describing: reader.error))")
            #expect(primarySamplesChecked > 0)
        }

        // Verify scaled/intersected sourceInterval math covers the exact 2x source span per output frame.
        let scaledEntry = StudioCompositionTimeMap.Entry(
            segmentIndex: 0,
            segmentID: UUID(),
            isPrimaryRecording: true,
            mediaFileName: nil,
            editorRange: CMTimeRange(
                start: CMTime(seconds: 1.0, preferredTimescale: 600),
                duration: CMTime(seconds: 0.5, preferredTimescale: 600)
            ),
            sourceRange: CMTimeRange(
                start: CMTime(seconds: 2.0, preferredTimescale: 600),
                duration: CMTime(seconds: 1.0, preferredTimescale: 600)
            )
        )
        let interval = scaledEntry.sourceInterval(
            at: CMTime(seconds: 1.0, preferredTimescale: 600),
            frameDuration: 1.0 / 60.0
        )
        #expect(abs(interval.start - 2.0) < 0.0005)
        #expect(abs(interval.end - (2.0 + 2.0 / 60.0)) < 0.001)
    }

    @Test func lateUnredactedThumbnailBatchIsDiscardedAfterRedactionRefreshWhileKeepingImportedTiles() async throws {
        let store = RecordingTimelineThumbnailStore()
        let primaryURL = URL(fileURLWithPath: "/tmp/thumb-primary.mov")
        let importedURL = URL(fileURLWithPath: "/tmp/thumb-import.mov")

        nonisolated final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var didStart = false
            private var didRelease = false
            private var primaryCalls = 0

            func nextPrimaryCallIndex() -> Int {
                lock.withLock {
                    primaryCalls += 1
                    return primaryCalls
                }
            }

            func signalStartedAndWait() async {
                await withCheckedContinuation { cont in
                    let shouldResumeImmediately: Bool = lock.withLock {
                        didStart = true
                        if let waiting = startedContinuation {
                            startedContinuation = nil
                            waiting.resume()
                        }
                        if didRelease {
                            return true
                        }
                        releaseContinuation = cont
                        return false
                    }
                    if shouldResumeImmediately {
                        cont.resume()
                    }
                }
            }

            func waitUntilStarted(timeout: Duration = .seconds(5)) async throws {
                let deadline = ContinuousClock.now.advanced(by: timeout)
                while !lock.withLock({ didStart }) {
                    if ContinuousClock.now >= deadline {
                        throw NSError(
                            domain: "StudioVideoSequenceTests",
                            code: 96,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for primary thumbnail batch to start"]
                        )
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }

            func release() {
                let cont: CheckedContinuation<Void, Never>? = lock.withLock {
                    didRelease = true
                    let c = releaseContinuation
                    releaseContinuation = nil
                    return c
                }
                cont?.resume()
            }
        }

        let gate = Gate()
        let redTile = Self.solidNSImage(r: 230, g: 20, b: 20)
        let greenTile = Self.solidNSImage(r: 20, g: 210, b: 40)
        let blueTile = Self.solidNSImage(r: 30, g: 80, b: 230)

        store.renderBatch = { url, requests, redactions in
            if url == importedURL {
                return requests.map { RecordingTimelineThumbnailStore.Sample(key: $0.key, image: blueTile) }
            }
            if redactions.isEmpty {
                let call = gate.nextPrimaryCallIndex()
                if call == 1 {
                    // Suspend unredacted batch even if cancelled, simulating a slow decoder finishing late.
                    await gate.signalStartedAndWait()
                }
                return requests.map { RecordingTimelineThumbnailStore.Sample(key: $0.key, image: redTile) }
            } else {
                return requests.map { RecordingTimelineThumbnailStore.Sample(key: $0.key, image: greenTile) }
            }
        }

        // 1. Register imported source first and let its blue tiles settle in cache.
        store.registerSource(key: "imp.mov", url: importedURL, duration: 4.0)
        for _ in 0..<50 {
            if store.image(in: store.grid(forTargetSpan: 1.0, sourceKey: "imp.mov"), tileIndex: 0, sourceKey: "imp.mov") != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let importedBefore = store.image(in: store.grid(forTargetSpan: 1.0, sourceKey: "imp.mov"), tileIndex: 0, sourceKey: "imp.mov")
        #expect(importedBefore != nil)

        // 2. Prepare unredacted primary; wait until batch 1 is suspended inside renderBatch.
        store.prepare(url: primaryURL, duration: 4.0, redactions: [])
        try await gate.waitUntilStarted()

        // 3. Install a redaction on primary while the unredacted batch is in flight.
        let mask = RecordingRedaction(start: 0, end: 4, rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: .pixelate)
        store.prepare(url: primaryURL, duration: 4.0, redactions: [mask])

        // 4. Release the stale unredacted batch and let the new redacted batches finish.
        gate.release()
        let primaryGrid = store.grid(forTargetSpan: 1.0, sourceKey: "")
        for _ in 0..<80 {
            if store.cachedTileCount >= 64 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // Imported blue tile must still be cached and untouched.
        let importedAfter = store.image(in: store.grid(forTargetSpan: 1.0, sourceKey: "imp.mov"), tileIndex: 0, sourceKey: "imp.mov")
        #expect(importedAfter != nil)
        if let cg = importedAfter?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let px = Self.rgbPixel(in: cg, x: 4, y: 4)
            #expect(px.b > 180 && px.r < 80)
        }

        // Every cached primary tile must be green (redacted), NEVER red (unredacted).
        var checkedPrimaryTiles = 0
        for idx in 0..<8 {
            if let img = store.image(in: primaryGrid, tileIndex: idx, sourceKey: ""),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                checkedPrimaryTiles += 1
                let px = Self.rgbPixel(in: cg, x: 4, y: 4)
                #expect(px.g > 150 && px.r < 80, "Stale unredacted tile leaked into cache at tile \(idx)")
            }
        }
        #expect(checkedPrimaryTiles > 0)
    }

    @Test func markersAndChaptersStayOnRepeatedClipOccurrenceAcrossSplitsReordersAndLegacyFallback() throws {
        let firstOccurrence = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 2,
            mediaFileName: "clip.mov",
            displayName: "Clip",
            sourceDuration: 2
        )
        let secondOccurrence = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 2,
            mediaFileName: "clip.mov",
            displayName: "Clip",
            sourceDuration: 2
        )
        let timeline = RecordingClipTimeline(segments: [firstOccurrence, secondOccurrence])

        // Drop marker and chapter on the SECOND occurrence at editor time 3.0 (source 1.0).
        let anchor = StudioEditing.markerAnchor(at: 3.0, in: timeline)
        #expect(anchor.mediaFileName == "clip.mov")
        #expect(anchor.clipOccurrenceID == secondOccurrence.effectiveOccurrenceID)
        #expect(abs(anchor.sourceTime - 1.0) < 0.0001)

        let marker = RecordingMarker(
            sourceTime: anchor.sourceTime,
            mediaFileName: anchor.mediaFileName,
            clipOccurrenceID: anchor.clipOccurrenceID
        )
        let chapter = RecordingChapter(
            title: "Second take",
            start: 1.0,
            mediaFileName: "clip.mov",
            clipOccurrenceID: secondOccurrence.effectiveOccurrenceID
        )

        // Both must resolve to editor time 3.0 (second occurrence), NOT 1.0 (first occurrence).
        let mappedMarkers = StudioEditing.markerEditorTimes([marker], in: timeline)
        #expect(mappedMarkers.count == 1)
        #expect(abs(mappedMarkers[0].time - 3.0) < 0.0001)

        let mappedChapters = RecordingChapterPlanner.mapped([chapter], through: timeline)
        #expect(mappedChapters.count == 1)
        #expect(abs(mappedChapters[0].start - 3.0) < 0.0001)

        // Split the second occurrence at editor time 2.5 (source 0.5): trailing half inherits occurrenceID.
        let splitTimeline = try #require(timeline.split(at: 2.5)).timeline
        #expect(splitTimeline.segments.count == 3)
        #expect(splitTimeline.segments[2].effectiveOccurrenceID == secondOccurrence.effectiveOccurrenceID)

        let afterSplitMarkers = StudioEditing.markerEditorTimes([marker], in: splitTimeline)
        #expect(afterSplitMarkers.count == 1)
        #expect(abs(afterSplitMarkers[0].time - 3.0) < 0.0001)

        let afterSplitChapters = RecordingChapterPlanner.mapped([chapter], through: splitTimeline)
        #expect(afterSplitChapters.count == 1)
        #expect(abs(afterSplitChapters[0].start - 3.0) < 0.0001)

        // Move the second occurrence's trailing half (0.5..<2.0) to index 0: marker & chapter move to 0.5!
        let reordered = try #require(splitTimeline.moving(segmentID: splitTimeline.segments[2].id, to: 0))
        let afterReorderMarkers = StudioEditing.markerEditorTimes([marker], in: reordered)
        #expect(afterReorderMarkers.count == 1)
        #expect(abs(afterReorderMarkers[0].time - 0.5) < 0.0001)

        let afterReorderChapters = RecordingChapterPlanner.mapped([chapter], through: reordered)
        #expect(afterReorderChapters.count == 1)
        #expect(abs(afterReorderChapters[0].start - 0.5) < 0.0001)

        // Deleting occurrence 2 removes its marker & chapter rather than jumping onto occurrence 1.
        let onlyFirst = RecordingClipTimeline(segments: [firstOccurrence])
        #expect(StudioEditing.markerEditorTimes([marker], in: onlyFirst).isEmpty)
        #expect(RecordingChapterPlanner.mapped([chapter], through: onlyFirst).isEmpty)

        // Older projects without clipOccurrenceID still fall back to filename + sourceTime lookup.
        let legacyMarker = RecordingMarker(sourceTime: 1.0, mediaFileName: "clip.mov", clipOccurrenceID: nil)
        let legacyChapter = RecordingChapter(title: "Legacy", start: 1.0, mediaFileName: "clip.mov", clipOccurrenceID: nil)
        let legacyMappedMarkers = StudioEditing.markerEditorTimes([legacyMarker], in: timeline)
        #expect(legacyMappedMarkers.count == 1)
        #expect(abs(legacyMappedMarkers[0].time - 1.0) < 0.0001)
        let legacyMappedChapters = RecordingChapterPlanner.mapped([legacyChapter], through: timeline)
        #expect(legacyMappedChapters.count == 1)
        #expect(abs(legacyMappedChapters[0].start - 1.0) < 0.0001)

        // Codable round-trip preserves clipOccurrenceID and segment occurrenceID.
        let encodedSeg = try JSONEncoder().encode(splitTimeline.segments[2])
        let decodedSeg = try JSONDecoder().decode(RecordingClipSegment.self, from: encodedSeg)
        #expect(decodedSeg.occurrenceID == secondOccurrence.id)
        let encodedMarker = try JSONEncoder().encode(marker)
        let decodedMarker = try JSONDecoder().decode(RecordingMarker.self, from: encodedMarker)
        #expect(decodedMarker.clipOccurrenceID == secondOccurrence.id)
    }

    // MARK: - Round 3 Regressions (Findings 9, 10)

    @Test func primaryShortPictureTrackDoesNotStretchAndMasksPreviewWithoutLeak() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVideoSeqShortPic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("short-primary.mov")
        // 2.00 s video track inside a 2.98 s movie: checkerboard + 880 Hz tone ONLY during 0.50..<0.75 s.
        try await Self.writeTimedCheckerboardMovie(
            to: url,
            size: CGSize(width: 160, height: 120),
            videoDuration: 2.0,
            audioDuration: 2.98,
            checkerWindow: 0.50..<0.75,
            backgroundColor: (r: 128, g: 128, b: 128),
            toneWindow: 0.50..<0.75,
            toneHz: 880
        )

        let asset = AVURLAsset(url: url)
        let assetDuration = try await asset.load(.duration).seconds
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoTrackDuration = try await videoTrack.load(.timeRange).duration.seconds
        #expect(assetDuration > 2.90)
        #expect(videoTrackDuration > 1.95 && videoTrackDuration < 2.05)

        let timeline = RecordingClipTimeline.full(sourceDuration: assetDuration)
        let (composition, timeMap) = try RecordingCompositionBuilder.makeVideoCompositionWithTimeMap(
            videoTrack: videoTrack,
            timeline: timeline
        )

        // Composition time map must preserve unstretched 2.00 s video + explicit empty tail.
        #expect(timeMap.entries.count == 2)
        #expect(timeMap.entries[0].hasVideo == true)
        #expect(abs(timeMap.entries[0].editorRange.duration.seconds - videoTrackDuration) < 0.02)
        #expect(abs(timeMap.entries[0].sourceRange.duration.seconds - videoTrackDuration) < 0.02)
        #expect(timeMap.entries[1].hasVideo == false)
        #expect(abs(timeMap.entries[1].editorRange.end.seconds - assetDuration) < 0.02)

        // Without mask, checkerboard must stay at 0.55 s and NEVER stretch to 0.90 s.
        let unmaskedGen = AVAssetImageGenerator(asset: composition)
        unmaskedGen.requestedTimeToleranceBefore = .zero
        unmaskedGen.requestedTimeToleranceAfter = .zero
        let unmaskedMid = try await unmaskedGen.image(at: CMTime(seconds: 0.55, preferredTimescale: 600)).image
        let unmaskedLate = try await unmaskedGen.image(at: CMTime(seconds: 0.90, preferredTimescale: 600)).image
        #expect(Self.detailScore(of: unmaskedMid) > 50)
        #expect(Self.detailScore(of: unmaskedLate) < 5.0)

        // With full-frame redaction on 0.50..<0.75, single-source preview sharing timeMap must show 0 detail leak.
        let mask = RecordingRedaction(
            start: 0.50,
            end: 0.75,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            mode: .pixelate,
            strength: 1.0
        )
        let previewSource = RecordingRedactionPreviewSource()
        previewSource.update(redactions: [mask], clipTimeline: timeline, timeMap: timeMap)
        let previewVideoComp = try await previewSource.composition(asset: composition)

        let previewGen = AVAssetImageGenerator(asset: composition)
        previewGen.videoComposition = previewVideoComp
        previewGen.requestedTimeToleranceBefore = .zero
        previewGen.requestedTimeToleranceAfter = .zero
        for t in [0.55, 0.75, 0.90] {
            let img = try await previewGen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let detail = Self.detailScore(of: img)
            #expect(detail < 5.0, "Single-source short-picture preview leaked detail (\(detail)) at t=\(t)")
        }
    }

    @Test func multiSourceImportedShortPictureTrackDoesNotStretchAndRendersBlackTail() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVideoSeqMultiShort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("primary.mov")
        let importURL = tempDir.appendingPathComponent("short-import.mov")
        try await Self.writeSyntheticMovie(
            to: primaryURL,
            size: CGSize(width: 160, height: 120),
            duration: 1.0,
            color: (r: 220, g: 30, b: 30),
            preferredTransform: .identity,
            toneHz: 440
        )
        // Imported clip: 1.00 s video (checkerboard only at 0.25..<0.50, green elsewhere) + 2.00 s audio.
        try await Self.writeTimedCheckerboardMovie(
            to: importURL,
            size: CGSize(width: 160, height: 120),
            videoDuration: 1.0,
            audioDuration: 2.0,
            checkerWindow: 0.25..<0.50,
            backgroundColor: (r: 30, g: 200, b: 60),
            toneWindow: 0.25..<0.50,
            toneHz: 880
        )

        let primarySource = try await StudioVideoSource.load(url: primaryURL)
        let importSource = try await StudioVideoSource.load(url: importURL)
        #expect(importSource.duration > 1.95)

        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0),
            RecordingClipSegment(
                sourceStart: 0,
                sourceEnd: importSource.duration,
                mediaFileName: "short-import.mov",
                displayName: "Short Import",
                sourceDuration: importSource.duration
            )
        ])

        let redactionSource = RecordingRedactionPreviewSource()
        redactionSource.update(redactions: [], clipTimeline: timeline)

        for useRedactionCompositor in [false, true] {
            let (composition, videoComposition, timeMap) = try RecordingCompositionBuilder.makeMultiSourceVideoComposition(
                primarySource: primarySource,
                importedSources: ["short-import.mov": importSource],
                timeline: timeline,
                renderSize: primarySource.displaySize,
                redactionSource: useRedactionCompositor ? redactionSource : nil
            )

            #expect(timeMap.entries.count == 3)
            #expect(timeMap.entries[0].isPrimaryRecording == true && timeMap.entries[0].hasVideo == true)
            #expect(timeMap.entries[1].isPrimaryRecording == false && timeMap.entries[1].hasVideo == true)
            #expect(abs(timeMap.entries[1].editorRange.duration.seconds - 1.0) < 0.03)
            #expect(timeMap.entries[2].isPrimaryRecording == false && timeMap.entries[2].hasVideo == false)

            let gen = AVAssetImageGenerator(asset: composition)
            gen.videoComposition = videoComposition
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero

            // 1.35 s = imported source 0.35 s -> unstretched checkerboard
            let checkerImg = try await gen.image(at: CMTime(seconds: 1.35, preferredTimescale: 600)).image
            #expect(Self.detailScore(of: checkerImg) > 50)

            // 1.75 s = imported source 0.75 s -> flat green (checkerboard NOT stretched here)
            let greenImg = try await gen.image(at: CMTime(seconds: 1.75, preferredTimescale: 600)).image
            #expect(Self.detailScore(of: greenImg) < 5.0)
            let greenPx = Self.rgbPixel(in: greenImg, x: 80, y: 60)
            #expect(greenPx.g > 150 && greenPx.r < 90)

            // 2.50 s = empty video tail -> clean solid black
            let tailImg = try await gen.image(at: CMTime(seconds: 2.50, preferredTimescale: 600)).image
            #expect(Self.detailScore(of: tailImg) < 5.0)
            let blackPx = Self.rgbPixel(in: tailImg, x: 80, y: 60)
            #expect(blackPx.r < 15 && blackPx.g < 15 && blackPx.b < 15)

            // Reader must complete across timeMap.timeRange without -11841.
            let reader = try AVAssetReader(asset: composition)
            let tracks = try await composition.loadTracks(withMediaType: .video)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: tracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.videoComposition = videoComposition
            reader.add(output)
            reader.timeRange = timeMap.timeRange
            #expect(reader.startReading())
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            #expect(reader.status == .completed, "Reader failed with \(String(describing: reader.error))")
            #expect(count > 0)
        }
    }

    @Test func thumbnailQueuePumpsSurvivingSourceWithoutConcurrentDecodersAfterDeletingActiveSource() async throws {
        let store = RecordingTimelineThumbnailStore()
        let urlA = URL(fileURLWithPath: "/tmp/thumb-delete-A.mov")
        let urlB = URL(fileURLWithPath: "/tmp/thumb-keep-B.mov")
        let tileA = Self.solidNSImage(r: 230, g: 30, b: 30)
        let tileB = Self.solidNSImage(r: 30, g: 210, b: 60)

        nonisolated final class GateAndTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var didStartA = false
            private var didReleaseA = false
            private var inFlight = 0
            private var peakConcurrent = 0
            private var startsByURL: [URL: Int] = [:]

            func enter(url: URL) {
                lock.withLock {
                    inFlight += 1
                    peakConcurrent = max(peakConcurrent, inFlight)
                    startsByURL[url, default: 0] += 1
                }
            }

            func leave() {
                lock.withLock {
                    inFlight = max(0, inFlight - 1)
                }
            }

            func startedCount(for url: URL) -> Int {
                lock.withLock { startsByURL[url, default: 0] }
            }

            var maxConcurrent: Int {
                lock.withLock { peakConcurrent }
            }

            func suspendA() async {
                await withCheckedContinuation { cont in
                    let resumeNow: Bool = lock.withLock {
                        didStartA = true
                        if let waiting = startedContinuation {
                            startedContinuation = nil
                            waiting.resume()
                        }
                        if didReleaseA { return true }
                        releaseContinuation = cont
                        return false
                    }
                    if resumeNow { cont.resume() }
                }
            }

            func waitUntilAStarted(timeout: Duration = .seconds(5)) async throws {
                let deadline = ContinuousClock.now.advanced(by: timeout)
                while !lock.withLock({ didStartA }) {
                    if ContinuousClock.now >= deadline {
                        throw NSError(
                            domain: "StudioVideoSequenceTests",
                            code: 97,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for thumbnail batch A to start"]
                        )
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }

            func releaseA() {
                let cont: CheckedContinuation<Void, Never>? = lock.withLock {
                    didReleaseA = true
                    let c = releaseContinuation
                    releaseContinuation = nil
                    return c
                }
                cont?.resume()
            }
        }

        let tracker = GateAndTracker()
        store.renderBatch = { url, requests, _ in
            tracker.enter(url: url)
            defer { tracker.leave() }
            if url == urlA {
                await tracker.suspendA()
                return requests.map { RecordingTimelineThumbnailStore.Sample(key: $0.key, image: tileA) }
            } else {
                await Task.yield()
                return requests.map { RecordingTimelineThumbnailStore.Sample(key: $0.key, image: tileB) }
            }
        }

        // 1. Register A so its batch starts and suspends inside renderBatch.
        store.registerSource(key: "A", url: urlA, duration: 4.0)
        try await tracker.waitUntilAStarted(timeout: .seconds(5))

        // 2. Queue B while A is still in flight.
        store.registerSource(key: "B", url: urlB, duration: 4.0)

        // 3. Delete A while A's batch is still running, then re-register B (early no-op).
        store.syncImportedSources(keeping: ["B"])
        store.registerSource(key: "B", url: urlB, duration: 4.0)

        // 4. While A is still draining, NO second concurrent decoder may start for B.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(tracker.startedCount(for: urlB) == 0)
        #expect(tracker.maxConcurrent == 1)

        // 5. Release A; completion must restart pump() for B and populate B's tiles.
        tracker.releaseA()
        let gridB = store.grid(forTargetSpan: 1.0, sourceKey: "B")
        for _ in 0..<100 {
            if store.image(in: gridB, tileIndex: 0, sourceKey: "B") != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let tileB0 = store.image(in: gridB, tileIndex: 0, sourceKey: "B")
        #expect(tileB0 != nil, "Surviving source B stalled with blank thumbnails after deleting active source A")
        if let cg = tileB0?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let px = Self.rgbPixel(in: cg, x: 4, y: 4)
            #expect(px.g > 150 && px.r < 80)
        }
        #expect(tracker.startedCount(for: urlB) > 0)
        #expect(tracker.maxConcurrent == 1)
    }

    // MARK: - Round 4 Integration Regressions (Format 7, Cleanup, Conform, Drop Routing, Package Resolver)

    @Test func packageResolverValidatesSequenceMediaFileNameAndRawEditRedactions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVideoSeqPkgR4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = dir.appendingPathComponent("outside.mov")
        try Data("outside".utf8).write(to: outside)

        func makePkg(_ name: String) throws -> URL {
            let pkg = dir.appendingPathComponent(name, isDirectory: true)
            let media = pkg.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try Data("screen".utf8).write(to: pkg.appendingPathComponent("screen.mov"))
            return pkg
        }

        // 1. Sequence clip `mediaFileName` symlink inside `media/` must be rejected by Finished preflight.
        let symClipPkg = try makePkg("SymClip.sukushorec")
        let symName = "\(UUID().uuidString).mov"
        try FileManager.default.createSymbolicLink(
            at: symClipPkg.appendingPathComponent("media/\(symName)"),
            withDestinationURL: outside
        )
        let clipEditJSON = """
        {
            "formatVersion": 7,
            "clips": [
                { "sourceStart": 0, "sourceEnd": 1, "mediaFileName": "\(symName)" }
            ]
        }
        """
        try Data(clipEditJSON.utf8).write(to: symClipPkg.appendingPathComponent("edit.json"))
        #expect(throws: RecordingPackageMedia.ValidationError.unsafeFile(symName)) {
            try RecordingPackageMedia.validateRenderInputs(in: symClipPkg)
        }

        // 2. Raw preflight returns draft redactions over saved edit, empty when no edit, and refuses corrupt edit.
        let cleanPkg = try makePkg("Clean.sukushorec")
        let cleanRaw = try RecordingPackageMedia.validateRawImportInputs(in: cleanPkg)
        #expect(cleanRaw.redactions.isEmpty)

        let draftMaskPkg = try makePkg("DraftMask.sukushorec")
        let savedNoMaskJSON = """
        { "formatVersion": 7, "redactions": [] }
        """
        let draftMask = RecordingRedaction(start: 0.2, end: 0.8, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), mode: .pixelate)
        struct MinimalEdit: Encodable {
            let formatVersion: Int
            let redactions: [RecordingRedaction]
        }
        try Data(savedNoMaskJSON.utf8).write(to: draftMaskPkg.appendingPathComponent("edit.json"))
        try JSONEncoder().encode(MinimalEdit(formatVersion: 7, redactions: [draftMask]))
            .write(to: draftMaskPkg.appendingPathComponent("edit.draft.json"))
        let draftRaw = try RecordingPackageMedia.validateRawImportInputs(in: draftMaskPkg)
        #expect(draftRaw.redactions.count == 1)
        #expect(draftRaw.redactions[0].mode == .pixelate)

        let corruptPkg = try makePkg("Corrupt.sukushorec")
        try Data("{ not valid json".utf8).write(to: corruptPkg.appendingPathComponent("edit.json"))
        #expect(throws: RecordingPackageMedia.ValidationError.invalidPackage("Corrupt.sukushorec")) {
            try RecordingPackageMedia.validateRawImportInputs(in: corruptPkg)
        }

        // 3. Format version 7 is current; v6 passes; v99 is refused for renders and raw imports.
        #expect(RecordingPackageMedia.currentFormatVersion == 7)
        let v6Pkg = try makePkg("V6.sukushorec")
        try Data("{ \"formatVersion\": 6 }".utf8).write(to: v6Pkg.appendingPathComponent("edit.json"))
        _ = try RecordingPackageMedia.validateRenderInputs(in: v6Pkg)
        _ = try RecordingPackageMedia.validateRawImportInputs(in: v6Pkg)

        let futurePkg = try makePkg("Future.sukushorec")
        try Data("{ \"formatVersion\": 99 }".utf8).write(to: futurePkg.appendingPathComponent("edit.json"))
        #expect(throws: RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99)) {
            try RecordingPackageMedia.validateRenderInputs(in: futurePkg)
        }
        #expect(throws: RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99)) {
            try RecordingPackageMedia.validateRawImportInputs(in: futurePkg)
        }
    }

    @Test func unifiedMediaCleanupKeepsAllReferencedTypesAndRemovesOnlyUnreferencedOwnedFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioVideoSeqCleanupR4-\(UUID().uuidString)", isDirectory: true)
        let pkg = dir.appendingPathComponent("Proj.sukushorec", isDirectory: true)
        let media = pkg.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seqClip = "\(UUID().uuidString).mov"
        let overlayClip = "\(UUID().uuidString).mov"
        let imageFile = "\(UUID().uuidString).png"
        let audioFile = "\(UUID().uuidString).wav"
        let orphanMov = "\(UUID().uuidString).mov"
        let orphanPng = "\(UUID().uuidString).png"
        let nonOwnedMov = "manual.mov"

        for name in [seqClip, overlayClip, imageFile, audioFile, orphanMov, orphanPng, nonOwnedMov] {
            try Data("payload".utf8).write(to: media.appendingPathComponent(name))
        }

        let referenced: Set<String> = [seqClip, overlayClip, imageFile, audioFile]
        RecordingOverlayMedia.cleanupUnreferencedMedia(in: media, referenced: referenced)

        for kept in [seqClip, overlayClip, imageFile, audioFile, nonOwnedMov] {
            #expect(FileManager.default.fileExists(atPath: media.appendingPathComponent(kept).path), "Expected \(kept) to survive")
        }
        for removed in [orphanMov, orphanPng] {
            #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent(removed).path), "Expected \(removed) to be removed")
        }
    }

    @Test func linkedVideoOverlayConformGatesBySourceIdentityAcrossPrimaryAndImportedClips() {
        let primary = RecordingClipSegment(sourceStart: 0, sourceEnd: 4)
        let imported = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 4,
            mediaFileName: "broll.mov",
            displayName: "B-Roll",
            sourceDuration: 4
        )
        let old = RecordingClipTimeline(segments: [primary, imported])
        // Overlay sits strictly on the imported clip's 1..<3 s (editor 5..<7 s).
        let overlay = RecordingVideoOverlay(
            fileName: "pip.mov",
            displayName: "PiP",
            start: 5,
            fileDuration: 2,
            isLinked: true
        )

        // Delete the imported clip, leaving only primary 0..<4 (which ALSO has source times 1..<3!).
        // Source-identity gating must prevent the overlay from attaching to primary's 1..<3.
        let withoutImported = RecordingClipTimeline(segments: [primary])
        let conformedAfterDelete = StudioVideoOverlayLane.conform([overlay], from: old, to: withoutImported)
        #expect(conformedAfterDelete.isEmpty)

        // Reorder imported before primary: overlay must move with imported to editor 1..<3, NOT duplicate onto primary.
        let reordered = RecordingClipTimeline(segments: [imported, primary])
        let conformedAfterReorder = StudioVideoOverlayLane.conform([overlay], from: old, to: reordered)
        #expect(conformedAfterReorder.count == 1)
        #expect(abs(conformedAfterReorder[0].start - 1.0) < 0.001)
        #expect(abs(conformedAfterReorder[0].end - 3.0) < 0.001)
    }

    @Test func finderMovieDropRoutingFollowsHoveredLaneWithoutStealingToOverlay() {
        #expect(StudioMediaDropRouting.videoDestination(for: .clips, canDropClip: true, canDropOverlay: true) == .clips)
        #expect(StudioMediaDropRouting.videoDestination(for: .videoOverlay, canDropClip: true, canDropOverlay: true) == .videoOverlay)
        #expect(StudioMediaDropRouting.videoDestination(for: .other, canDropClip: true, canDropOverlay: true) == nil)
        #expect(StudioMediaDropRouting.videoDestination(for: nil, canDropClip: true, canDropOverlay: true) == nil)
        #expect(StudioMediaDropRouting.videoDestination(for: .clips, canDropClip: false, canDropOverlay: true) == nil)
        #expect(StudioMediaDropRouting.videoDestination(for: .videoOverlay, canDropClip: true, canDropOverlay: false) == nil)
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        timeoutSeconds: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 98)
            }
            if Date() >= deadline {
                throw NSError(
                    domain: "StudioVideoSequenceTests",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for AVAssetWriterInput(\(input.mediaType.rawValue))"]
                )
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func writeTimedCheckerboardMovie(
        to url: URL,
        size: CGSize,
        videoDuration: TimeInterval,
        audioDuration: TimeInterval,
        checkerWindow: Range<TimeInterval>,
        backgroundColor: (r: UInt8, g: UInt8, b: UInt8),
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

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 20)
        }
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
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        let fps = 60
        let totalFrames = max(1, Int((videoDuration * Double(fps)).rounded()))
        let totalSamples = Int((audioDuration * sampleRate).rounded())
        let audioChunkSamples = 4410 // 0.1 s chunks, interleaved with video so AVAssetWriter never stalls

        func appendAudioChunk(startSample: Int, count: Int) async throws {
            var pcm = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let sampleIdx = startSample + i
                let t = Double(sampleIdx) / sampleRate
                if toneWindow.contains(t) {
                    let value = sin(2.0 * .pi * toneHz * t) * 0.4
                    pcm[i] = Int16(value * Double(Int16.max))
                }
            }
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
            let block = try #require(blockBuffer)
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    CMBlockBufferReplaceDataBytes(
                        with: base,
                        blockBuffer: block,
                        offsetIntoDestination: 0,
                        dataLength: dataSize
                    )
                }
            }
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid
            )
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDesc,
                sampleCount: count,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
            let sb = try #require(sampleBuffer)
            try await Self.waitUntilReady(audioInput, writer: writer)
            audioInput.append(sb)
        }

        // Feed whichever input AVAssetWriter is ready to accept so the muxer's
        // interleaving buffer can never deadlock waiting on the other track.
        var frame = 0
        var audioCursor = 0
        var videoMarkedFinished = false
        var audioMarkedFinished = false
        let writeDeadline = Date().addingTimeInterval(10)

        while frame < totalFrames || audioCursor < totalSamples {
            if writer.status == .failed || writer.status == .cancelled {
                throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 22)
            }
            if Date() >= writeDeadline {
                throw NSError(
                    domain: "StudioVideoSequenceTests",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out writing timed movie (frame=\(frame)/\(totalFrames), audio=\(audioCursor)/\(totalSamples))"]
                )
            }
            if frame >= totalFrames && !videoMarkedFinished {
                videoInput.markAsFinished()
                videoMarkedFinished = true
            }
            if audioCursor >= totalSamples && !audioMarkedFinished {
                audioInput.markAsFinished()
                audioMarkedFinished = true
            }

            let videoReady = frame < totalFrames && videoInput.isReadyForMoreMediaData
            let audioReady = audioCursor < totalSamples && audioInput.isReadyForMoreMediaData
            guard videoReady || audioReady else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }

            let videoTime = frame < totalFrames ? Double(frame) / Double(fps) : Double.infinity
            let audioTime = audioCursor < totalSamples ? Double(audioCursor) / sampleRate : Double.infinity

            if audioReady && (!videoReady || audioTime <= videoTime) {
                let count = min(audioChunkSamples, totalSamples - audioCursor)
                try await appendAudioChunk(startSample: audioCursor, count: count)
                audioCursor += count
            } else if videoReady {
                let isChecker = checkerWindow.contains(videoTime)
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
                            if isChecker {
                                let v: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 255 : 0
                                row[x * 4 + 0] = v
                                row[x * 4 + 1] = v
                                row[x * 4 + 2] = v
                            } else {
                                row[x * 4 + 0] = backgroundColor.b
                                row[x * 4 + 1] = backgroundColor.g
                                row[x * 4 + 2] = backgroundColor.r
                            }
                            row[x * 4 + 3] = 255
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                frame += 1
            }
        }
        if !videoMarkedFinished { videoInput.markAsFinished() }
        if !audioMarkedFinished { audioInput.markAsFinished() }

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 21)
        }
    }

    private static func writeCheckerboardMovie(
        to url: URL,
        size: CGSize,
        duration: TimeInterval
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 10)
        }
        writer.startSession(atSourceTime: .zero)
        let fps = 60
        let totalFrames = max(1, Int((duration * Double(fps)).rounded()))
        for frame in 0..<totalFrames {
            try await Self.waitUntilReady(videoInput, writer: writer)
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
                        let isWhite = ((x / 4) + (y / 4)) % 2 == 0
                        let v: UInt8 = isWhite ? 255 : 0
                        row[x * 4 + 0] = v
                        row[x * 4 + 1] = v
                        row[x * 4 + 2] = v
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "StudioVideoSequenceTests", code: 11)
        }
    }

    /// Mean absolute horizontal + vertical neighbor luma difference across the
    /// interior of a frame (high for raw checkerboard, ~0 for fully masked or
    /// flat color frames).
    private static func detailScore(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        guard width > 4, height > 4 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return lumaGradientScore(rgba: bytes, width: width, height: height, bytesPerRow: width * 4, isBGRA: false)
    }

    private static func detailScore(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let raw = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: height * bytesPerRow)
        return lumaGradientScore(rgba: Array(raw), width: width, height: height, bytesPerRow: bytesPerRow, isBGRA: true)
    }

    private static func lumaGradientScore(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int, isBGRA: Bool) -> Double {
        func luma(_ x: Int, _ y: Int) -> Double {
            let offset = y * bytesPerRow + x * 4
            let r = Double(rgba[offset + (isBGRA ? 2 : 0)])
            let g = Double(rgba[offset + 1])
            let b = Double(rgba[offset + (isBGRA ? 0 : 2)])
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
        var sum = 0.0
        var count = 0
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let c = luma(x, y)
                sum += abs(c - luma(x + 1, y)) + abs(c - luma(x, y + 1))
                count += 2
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func solidNSImage(r: UInt8, g: UInt8, b: UInt8) -> NSImage {
        let width = 16, height = 16
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            bytes[i * 4 + 0] = r
            bytes[i * 4 + 1] = g
            bytes[i * 4 + 2] = b
            bytes[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: width, height: height))
    }

    // MARK: - Round 5 Regressions (Findings 11, 12, 15)

    @Test func displayTransformGuardAllowsAxisAlignedAndRejectsShearOrOblique() {
        let size = CGSize(width: 384, height: 216)
        #expect(RecordingCompositionBuilder.isIdentityTransform(.identity))
        #expect(RecordingCompositionBuilder.isSupportedDisplayTransform(.identity, naturalSize: size))
        #expect(!RecordingCompositionBuilder.isIdentityTransform(CGAffineTransform(rotationAngle: .pi / 2)))
        #expect(RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(rotationAngle: .pi / 2), naturalSize: size))
        #expect(RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(rotationAngle: .pi), naturalSize: size))
        #expect(RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(rotationAngle: -.pi / 2), naturalSize: size))
        #expect(RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(scaleX: -1, y: 1), naturalSize: size))

        // Oblique rotation, shear, singular, and zero naturalSize must fail closed.
        #expect(!RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(rotationAngle: .pi / 6), naturalSize: size))
        #expect(!RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(a: 1, b: 0.25, c: 0, d: 1, tx: 0, ty: 0), naturalSize: size))
        #expect(!RecordingCompositionBuilder.isSupportedDisplayTransform(CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0), naturalSize: size))
        #expect(!RecordingCompositionBuilder.isSupportedDisplayTransform(.identity, naturalSize: .zero))
    }

    @Test func readFormatVersionRecognizesFutureHeaderEvenWithUnknownEnumCase() throws {
        let futureWithUnknownEnum = Data("""
        {
          "formatVersion": 99,
          "redactions": [{ "mode": "mosaic_v2", "start": 0, "end": 1, "rect": [[0, 0], [0.5, 1]] }]
        }
        """.utf8)
        #expect(RecordingPackageMedia.readFormatVersion(from: futureWithUnknownEnum) == 99)
        #expect(RecordingPackageMedia.readFormatVersion(from: Data("{}".utf8)) == 1)
        #expect(RecordingPackageMedia.readFormatVersion(from: Data("{ not json".utf8)) == nil)

        // Package validation must classify a format-99 draft with an unknown enum case
        // as unsupportedFormatVersion(99), not invalidPackage.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioFutureHeader-\(UUID().uuidString)", isDirectory: true)
        let pkg = root.appendingPathComponent("Future.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("stub".utf8).write(to: pkg.appendingPathComponent("screen.mov"))
        try Data(#"{"formatVersion":7}"#.utf8).write(to: pkg.appendingPathComponent("edit.json"))
        try futureWithUnknownEnum.write(to: pkg.appendingPathComponent("edit.draft.json"))

        do {
            _ = try RecordingPackageMedia.validateRawImportInputs(in: pkg)
            Issue.record("Expected validateRawImportInputs to throw unsupportedFormatVersion(99)")
        } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
            // Expected
        }
        do {
            _ = try RecordingPackageMedia.validateRenderInputs(in: pkg)
            Issue.record("Expected validateRenderInputs to throw unsupportedFormatVersion(99)")
        } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
            // Expected
        }
    }

    @Test func splittingOneRepeatDoesNotDuplicateLinkedAudioOrPiPFromAnotherRepeat() throws {
        // Two repeats A and B of the same 2.0 s imported clip ("clip.mov").
        let repeatA = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 2.0,
            mediaFileName: "clip.mov",
            displayName: "Clip",
            sourceDuration: 2.0
        )
        let repeatB = RecordingClipSegment(
            sourceStart: 0,
            sourceEnd: 2.0,
            mediaFileName: "clip.mov",
            displayName: "Clip",
            sourceDuration: 2.0
        )
        let initial = RecordingClipTimeline(segments: [repeatA, repeatB])

        // Linked audio and linked PiP live ONLY at 0.25..<1.0 s inside repeat A.
        var linkedAudio = RecordingAudioClip(
            fileName: "vo.m4a",
            displayName: "VO",
            start: 0.25,
            fileDuration: 2.0
        )
        linkedAudio.trimStart = 0
        linkedAudio.trimEnd = 0.75
        linkedAudio.isLinked = true
        var linkedPiP = RecordingVideoOverlay(
            fileName: "pip.mov",
            displayName: "PiP",
            start: 0.25,
            fileDuration: 2.0,
            presentation: .pip,
            isLinked: true
        )
        linkedPiP.trimStart = 0
        linkedPiP.trimEnd = 0.75

        // Split repeat B at editor time 2.25 s (0.25 s into B).
        let afterSplitB = try #require(initial.split(at: 2.25)).timeline
        #expect(afterSplitB.segments.count == 3)
        #expect(afterSplitB.segments[1].effectiveOccurrenceID == repeatB.effectiveOccurrenceID)
        #expect(afterSplitB.segments[2].effectiveOccurrenceID == repeatB.effectiveOccurrenceID)

        let conformedAudio = StudioAudioConform.conform(
            [linkedAudio],
            hidden: [],
            from: initial,
            to: afterSplitB
        ).clips
        #expect(conformedAudio.count == 1)
        #expect(abs(conformedAudio[0].start - 0.25) < 0.002)
        #expect(abs(conformedAudio[0].end - 1.0) < 0.002)

        let conformedPiP = StudioVideoOverlayLane.conform(
            [linkedPiP],
            from: initial,
            to: afterSplitB
        )
        #expect(conformedPiP.count == 1)
        #expect(abs(conformedPiP[0].start - 0.25) < 0.002)
        #expect(abs(conformedPiP[0].end - 1.0) < 0.002)

        // Splitting repeat A at 0.50 s must still conform A's own linked audio and PiP
        // without duplicating anything onto B's pieces.
        let afterSplitA = try #require(afterSplitB.split(at: 0.50)).timeline
        let audioAfterSplitA = StudioAudioConform.conform(
            conformedAudio,
            hidden: [],
            from: afterSplitB,
            to: afterSplitA
        ).clips
        #expect(audioAfterSplitA.count == 1)
        #expect(abs(audioAfterSplitA[0].start - 0.25) < 0.002)
        #expect(abs(audioAfterSplitA[0].end - 1.0) < 0.002)

        let pipAfterSplitA = StudioVideoOverlayLane.conform(
            conformedPiP,
            from: afterSplitB,
            to: afterSplitA
        )
        #expect(pipAfterSplitA.count == 1)
        #expect(abs(pipAfterSplitA[0].start - 0.25) < 0.002)
        #expect(abs(pipAfterSplitA[0].end - 1.0) < 0.002)
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
            try await Self.waitUntilReady(videoInput, writer: writer)
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
