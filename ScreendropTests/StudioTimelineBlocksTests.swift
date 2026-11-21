import AppKit
import Foundation
import Testing

struct StudioTimelineBlocksTests {
    // MARK: - Drag thresholds

    @Test @MainActor func editKindThresholdsSeparateMoveFromTrim() {
        #expect(StudioBlockEditKind.move.dragThreshold == 3)
        #expect(StudioBlockEditKind.trimLeading.dragThreshold == 0.5)
        #expect(StudioBlockEditKind.trimTrailing.dragThreshold == 0.5)

        // Move waits out a < 3 pt wobble, horizontally or vertically.
        #expect(!StudioBlockEditKind.move.startsDrag(translation: 2.9, vertical: 0))
        #expect(!StudioBlockEditKind.move.startsDrag(translation: 0, vertical: -2.9))
        #expect(StudioBlockEditKind.move.startsDrag(translation: 3.0, vertical: 0))
        #expect(StudioBlockEditKind.move.startsDrag(translation: -3.0, vertical: 0))
        #expect(StudioBlockEditKind.move.startsDrag(translation: 0, vertical: 3.0))

        // Trim engages at 0.5 pt horizontally and ignores pure vertical drift.
        #expect(!StudioBlockEditKind.trimLeading.startsDrag(translation: 0.49, vertical: 10))
        #expect(StudioBlockEditKind.trimLeading.startsDrag(translation: 0.5, vertical: 0))
        #expect(StudioBlockEditKind.trimLeading.startsDrag(translation: -0.5, vertical: 0))
        #expect(!StudioBlockEditKind.trimTrailing.startsDrag(translation: -0.49, vertical: 10))
        #expect(StudioBlockEditKind.trimTrailing.startsDrag(translation: -0.5, vertical: 0))
    }

    // MARK: - Hit testing & narrow blocks

    @Test @MainActor func narrowBlockKeepsGrabbableMiddleAndCappedEdgeInsets() {
        // 100 s timeline in 500 pt (5 pt/s): a 0.5 s block has natural width 2.5 pt,
        // so StudioBlockFrame widens it to minimumWidth = 24 pt.
        let scale = StudioTimelineScale(viewportWidth: 500, duration: 100, zoom: 1)
        let id = UUID()
        let frame = StudioBlockFrame(editorStart: 20, editorEnd: 20.5, scale: scale)

        #expect(frame.minX == 100)
        #expect(frame.width == StudioBlockMetrics.minimumWidth)
        #expect(frame.maxX == 124)
        // Edge inset caps at 20% of width (4.8 pt < 6 pt), leaving 60% in the middle.
        #expect(abs(frame.edgeInset - 4.8) < 0.0001)

        let tester = StudioBlockHitTester(entries: [.init(id: id, frame: frame)], selectedID: nil)
        #expect(tester.target(atX: frame.minX - 4.1) == .empty)
        #expect(tester.target(atX: frame.minX - 4.0) == .edge(id, .leading))
        #expect(tester.target(atX: frame.minX + 4.7) == .edge(id, .leading))
        #expect(tester.target(atX: frame.minX + 4.9) == .body(id))
        #expect(tester.target(atX: frame.minX + frame.width / 2) == .body(id))
        #expect(tester.target(atX: frame.maxX - 4.9) == .body(id))
        #expect(tester.target(atX: frame.maxX - 4.7) == .edge(id, .trailing))
        #expect(tester.target(atX: frame.maxX + 4.0) == .edge(id, .trailing))
        #expect(tester.target(atX: frame.maxX + 4.1) == .empty)
    }

    @Test @MainActor func selectedBlockHandlesBeatAdjacentUnselectedBlockAndMeetingEdgesPreferInside() {
        let scale = StudioTimelineScale(viewportWidth: 600, duration: 60, zoom: 1) // 10 pt/s
        let firstID = UUID()
        let secondID = UUID()
        let firstFrame = StudioBlockFrame(editorStart: 10, editorEnd: 20, scale: scale)   // 100...200
        let secondFrame = StudioBlockFrame(editorStart: 20, editorEnd: 30, scale: scale) // 200...300
        let entries: [StudioBlockHitTester.Entry] = [
            .init(id: firstID, frame: firstFrame),
            .init(id: secondID, frame: secondFrame),
        ]

        // Unselected: where two blocks meet at x = 200, being inside the second block
        // prefers its leading edge over the first block's outward reach, and vice versa.
        let unselected = StudioBlockHitTester(entries: entries, selectedID: nil)
        #expect(unselected.target(atX: 199) == .edge(firstID, .trailing))
        #expect(unselected.target(atX: 201) == .edge(secondID, .leading))

        // Selected: the selected block's outer handles extend 8 pt outside and 2 pt inside,
        // answering before its neighbour even where the handle overlaps the neighbour.
        let selectedFirst = StudioBlockHitTester(entries: entries, selectedID: firstID)
        #expect(selectedFirst.target(atX: 92) == .edge(firstID, .leading))
        #expect(selectedFirst.target(atX: 101.9) == .edge(firstID, .leading))
        #expect(selectedFirst.target(atX: 102.1) == .body(firstID))
        #expect(selectedFirst.target(atX: 197.9) == .body(firstID))
        #expect(selectedFirst.target(atX: 198.1) == .edge(firstID, .trailing))
        #expect(selectedFirst.target(atX: 208) == .edge(firstID, .trailing))
        // Past the 8 pt handle reach, the neighbour answers normally.
        #expect(selectedFirst.target(atX: 209) == .body(secondID))
    }

    @Test @MainActor func shortBlockNearTimelineEndSlidesInwardToStayWhole() {
        let scale = StudioTimelineScale(viewportWidth: 500, duration: 100, zoom: 1) // 5 pt/s
        let frame = StudioBlockFrame(editorStart: 99, editorEnd: 100, scale: scale)
        #expect(frame.width == StudioBlockMetrics.minimumWidth)
        #expect(frame.maxX == scale.contentWidth)
        #expect(frame.minX == scale.contentWidth - StudioBlockMetrics.minimumWidth)
    }

    // MARK: - Neighbour clamping in editor time across a speed change

    @Test @MainActor func movingBlockAcrossSpeedChangeClampsAtNeighbourAndPreservesEditorLength() throws {
        // Clip 1: 0..10 s at 1x (editor 0..10 s).
        // Clip 2: 10..30 s at 2x (editor 10..20 s). Total editor duration = 20 s.
        let clipTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 10, speed: 1),
            RecordingClipSegment(sourceStart: 10, sourceEnd: 30, speed: 2),
        ])
        #expect(abs(clipTimeline.duration - 20) < 0.0001)

        let blockAID = UUID()
        let blockBID = UUID()
        // Block A sits on 1x (editor 2..4, length 2 s).
        // Block B sits on 2x (editor 14..16 -> source 18..22, length 2 s).
        let overlap = StudioLaneOverlap.forbidden(spans: [
            StudioLaneSpan(id: blockAID, editorStart: 2, editorEnd: 4),
            StudioLaneSpan(id: blockBID, editorStart: 14, editorEnd: 16),
        ])

        // Drag Block A +20 editor seconds to the right, straight across the 1x -> 2x cut into Block B.
        let clampedRight = overlap.clampedDelta(
            20,
            blockID: blockAID,
            editorStart: 2,
            editorEnd: 4,
            kind: .move,
            duration: clipTimeline.duration
        )
        #expect(abs(clampedRight - 10) < 0.0001)

        let movedRight = studioMovedSourceRange(
            clipTimeline: clipTimeline,
            editorStart: 2 + clampedRight, // 12 s on 2x clip
            editorLength: 2
        )
        // On the 2x clip, 2 editor seconds starting at editor 12 covers source 14..18 (4 source seconds).
        #expect(abs(movedRight.start - 14) < 0.0001)
        #expect(abs(movedRight.end - 18) < 0.0001)

        // Mapping that source range back onto the edited timeline preserves the 2 s editor length
        // and parks flush against Block B at editor 14.
        let rightSlices = clipTimeline.slices(overlapping: movedRight.start, sourceEnd: movedRight.end)
        let firstRight = try #require(rightSlices.first)
        let lastRight = try #require(rightSlices.last)
        #expect(abs(firstRight.editorStart - 12) < 0.0001)
        #expect(abs(lastRight.editorEnd - 14) < 0.0001)

        // Conversely, sliding Block B from the 2x clip onto the 1x clip keeps its 2 s editor length
        // (shrinking its source span from 4 s to 2 s) and stops flush against Block A at editor 4.
        let clampedLeft = overlap.clampedDelta(
            -15,
            blockID: blockBID,
            editorStart: 14,
            editorEnd: 16,
            kind: .move,
            duration: clipTimeline.duration
        )
        #expect(abs(clampedLeft - (-10)) < 0.0001)

        let movedLeft = studioMovedSourceRange(
            clipTimeline: clipTimeline,
            editorStart: 14 + clampedLeft, // 4 s on 1x clip
            editorLength: 2
        )
        #expect(abs(movedLeft.start - 4) < 0.0001)
        #expect(abs(movedLeft.end - 6) < 0.0001)

        // Trimming stops cleanly at neighbours too.
        let clampedTrimTrailing = overlap.clampedDelta(
            15,
            blockID: blockAID,
            editorStart: 2,
            editorEnd: 4,
            kind: .trimTrailing,
            duration: clipTimeline.duration
        )
        #expect(abs(clampedTrimTrailing - 10) < 0.0001)

        let clampedTrimLeading = overlap.clampedDelta(
            -20,
            blockID: blockBID,
            editorStart: 14,
            editorEnd: 16,
            kind: .trimLeading,
            duration: clipTimeline.duration
        )
        #expect(abs(clampedTrimLeading - (-10)) < 0.0001)
    }

    // MARK: - Drawn drafts land exactly where shown

    @Test @MainActor func draftRangeAndSourceSpanLandExactlyWhereDrawnAcrossSpeedChanges() throws {
        // Clip 1: 0..10 s at 1x (editor 0..10 s).
        // Clip 2: 15..25 s at 2x (editor 10..15 s; 10..15 s source was cut out).
        let clipTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 10, speed: 1),
            RecordingClipSegment(sourceStart: 15, sourceEnd: 25, speed: 2),
        ])
        let sourceDuration: TimeInterval = 25
        let existingID = UUID()
        let spans = [StudioLaneSpan(id: existingID, editorStart: 12, editorEnd: 14)]
        let occupiedSource: [ClosedRange<TimeInterval>] = [19...23]
        let minimum: TimeInterval = 0.5

        // 1. Short forward drag just before a neighbour on the 2x clip: grows to minimumLength
        // by pushing backward from the gap ceiling (12), landing at 11.5...12.0.
        let gap = try #require(studioGap(around: 11.8, spans: spans, duration: clipTimeline.duration))
        #expect(gap == 0...12)
        let draft = try #require(studioDraftRange(anchor: 11.8, pointer: 11.9, gap: gap, minimumLength: minimum))
        #expect(abs(draft.lowerBound - 11.5) < 0.0001)
        #expect(abs(draft.upperBound - 12.0) < 0.0001)

        // Commit through studioDrawnSourceSpan and map back to editor time: must match draft exactly.
        let sourceSpan = try #require(studioDrawnSourceSpan(
            for: draft,
            clipTimeline: clipTimeline,
            sourceDuration: sourceDuration,
            among: occupiedSource,
            minimum: minimum
        ))
        #expect(abs(sourceSpan.lowerBound - 18.0) < 0.0001)
        #expect(abs(sourceSpan.upperBound - 19.0) < 0.0001)

        let landedSlices = clipTimeline.slices(overlapping: sourceSpan.lowerBound, sourceEnd: sourceSpan.upperBound)
        let landedFirst = try #require(landedSlices.first)
        let landedLast = try #require(landedSlices.last)
        #expect(abs(landedFirst.editorStart - draft.lowerBound) < 0.0001)
        #expect(abs(landedLast.editorEnd - draft.upperBound) < 0.0001)

        // 2. Backward drag spanning the 1x/2x boundary lands at the exact drawn range.
        let crossDraft = try #require(studioDraftRange(anchor: 11.0, pointer: 9.0, gap: gap, minimumLength: minimum))
        #expect(abs(crossDraft.lowerBound - 9.0) < 0.0001)
        #expect(abs(crossDraft.upperBound - 11.0) < 0.0001)

        let crossSource = try #require(studioDrawnSourceSpan(
            for: crossDraft,
            clipTimeline: clipTimeline,
            sourceDuration: sourceDuration,
            among: occupiedSource,
            minimum: minimum
        ))
        let crossSlices = clipTimeline.slices(overlapping: crossSource.lowerBound, sourceEnd: crossSource.upperBound)
        #expect(abs((try #require(crossSlices.first).editorStart) - crossDraft.lowerBound) < 0.0001)
        #expect(abs((try #require(crossSlices.last).editorEnd) - crossDraft.upperBound) < 0.0001)

        // 3. A gap narrower than minimumLength produces no draft, and pressing inside a block has no gap.
        #expect(studioGap(around: 13.0, spans: spans, duration: clipTimeline.duration) == nil)
        let tinyGap: ClosedRange<TimeInterval> = 14...14.3
        #expect(studioDraftRange(anchor: 14.1, pointer: 14.2, gap: tinyGap, minimumLength: minimum) == nil)

        // 4. A hidden cue in the cut-out 10..15 source stretch never causes overlap on commit.
        let hiddenOccupied: [ClosedRange<TimeInterval>] = [10...15, 19...23]
        let trimmed = try #require(studioDrawnSourceSpan(
            for: 9.0...11.0,
            clipTimeline: clipTimeline,
            sourceDuration: sourceDuration,
            among: hiddenOccupied,
            minimum: minimum
        ))
        // Trimmed to the source range before the cut-out cue (9...10), still >= minimum.
        #expect(abs(trimmed.lowerBound - 9.0) < 0.0001)
        #expect(abs(trimmed.upperBound - 10.0) < 0.0001)
    }

    // MARK: - Clip strip tidy-ups

    @Test @MainActor func clipStripShowsTitleOnlyWhenSelectedOrHoveredAndSkipsNarrowClipBadges() {
        let control = RecordingClipTimelineControl(frame: NSRect(x: 0, y: 0, width: 200, height: 52))
        let store = RecordingTimelineThumbnailStore()
        // First clip is 0.12 s at 8x -> 0.015 s editor out of 10.015 s -> < 1 pt wide,
        // so rect.insetBy(dx: 12, dy: 5) produces a null rect (8c3a2e0 regression).
        let narrowSpedUp = RecordingClipSegment(sourceStart: 0, sourceEnd: 0.12, speed: 8)
        let mainClip = RecordingClipSegment(sourceStart: 0.12, sourceEnd: 10.12, speed: 1)
        let timeline = RecordingClipTimeline(segments: [narrowSpedUp, mainClip])

        control.update(
            timeline: timeline,
            sourceDuration: 10.12,
            thumbnails: store,
            selectedClipID: nil,
            playheadTime: 0
        )

        // Unselected & unhovered clip does not show its title, even when wide.
        let wideRect = CGRect(x: 0, y: 0, width: 120, height: 48)
        let narrowRect = CGRect(x: 0, y: 0, width: 40, height: 48)
        #expect(!control.showsTitle(on: mainClip, in: wideRect))

        // Selecting the clip reveals its title when wide, still hides it when narrow.
        control.update(
            timeline: timeline,
            sourceDuration: 10.12,
            thumbnails: store,
            selectedClipID: mainClip.id,
            playheadTime: 0
        )
        #expect(control.showsTitle(on: mainClip, in: wideRect))
        #expect(!control.showsTitle(on: mainClip, in: narrowRect))
        #expect(!control.showsTitle(on: narrowSpedUp, in: wideRect))

        // Speed badge formatting.
        #expect(RecordingClipSegment.speedTitle(1) == "1×")
        #expect(RecordingClipSegment.speedTitle(1.5) == "1.5×")
        #expect(RecordingClipSegment.speedTitle(8) == "8×")

        // Drawing the control with the narrow sped-up clip selected must not crash on null inset rect.
        control.update(
            timeline: timeline,
            sourceDuration: 10.12,
            thumbnails: store,
            selectedClipID: narrowSpedUp.id,
            playheadTime: 0
        )
        let rep = control.bitmapImageRepForCachingDisplay(in: control.bounds)
        #expect(rep != nil)
        if let rep {
            control.cacheDisplay(in: control.bounds, to: rep)
        }
    }
}
