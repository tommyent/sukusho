import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing

struct StudioEditingTests {
    // MARK: - Ripple delete across clips and speed changes

    @Test func rippleDeleteAcrossSeveralClipsAndSpeedChanges() throws {
        // Clip A: source 0..4 @ 1x -> editor 0..4 (len 4)
        // Clip B: source 4..10 @ 2x -> editor 4..7 (len 3)
        // Clip C: source 10..22 @ 4x -> editor 7..10 (len 3)
        let clipA = RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 1)
        let clipB = RecordingClipSegment(sourceStart: 4, sourceEnd: 10, speed: 2)
        let clipC = RecordingClipSegment(sourceStart: 10, sourceEnd: 22, speed: 4)
        let timeline = RecordingClipTimeline(segments: [clipA, clipB, clipC])
        #expect(abs(timeline.duration - 10) < 0.0001)
        #expect(timeline.editPoints.count == 4)
        #expect(abs(timeline.editPoints[0] - 0) < 0.0001)
        #expect(abs(timeline.editPoints[1] - 4) < 0.0001)
        #expect(abs(timeline.editPoints[2] - 7) < 0.0001)
        #expect(abs(timeline.editPoints[3] - 10) < 0.0001)

        // Delete editor 2.5...8.0:
        // - Clip A keeps 0..2.5 @ 1x (editor 2.5, same ID)
        // - Clip B is completely removed
        // - Clip C keeps editor 8..10 -> source (10 + 1*4)..22 = 14..22 @ 4x (editor 2.0, keeps Clip C's ID)
        let after = try #require(timeline.removingEditorRange(2.5...8.0))
        #expect(after.segments.count == 2)
        #expect(after.segments[0].id == clipA.id)
        #expect(abs(after.segments[0].sourceStart - 0) < 0.0001)
        #expect(abs(after.segments[0].sourceEnd - 2.5) < 0.0001)
        #expect(after.segments[0].speed == 1)

        #expect(after.segments[1].id == clipC.id)
        #expect(abs(after.segments[1].sourceStart - 14) < 0.0001)
        #expect(abs(after.segments[1].sourceEnd - 22) < 0.0001)
        #expect(after.segments[1].speed == 4)
        #expect(abs(after.duration - 4.5) < 0.0001)

        // Deleting a middle slice inside one 2x clip splits it into two:
        // leading half keeps ID, trailing half gets a fresh ID.
        let splitMiddle = try #require(timeline.removingEditorRange(5.0...6.0))
        #expect(splitMiddle.segments.count == 4)
        #expect(splitMiddle.segments[1].id == clipB.id)
        #expect(abs(splitMiddle.segments[1].sourceStart - 4) < 0.0001)
        #expect(abs(splitMiddle.segments[1].sourceEnd - 6) < 0.0001)
        #expect(splitMiddle.segments[2].id != clipB.id)
        #expect(abs(splitMiddle.segments[2].sourceStart - 8) < 0.0001)
        #expect(abs(splitMiddle.segments[2].sourceEnd - 10) < 0.0001)
        #expect(splitMiddle.segments[2].speed == 2)

        // Deleting the whole video returns .removesEntireVideo; cutting near an edge
        // that would leave a sub-minimum unmarked stub returns .leavesShortClip rather
        // than silently consuming unmarked footage.
        #expect(timeline.removeEditorRange(0...10) == .removesEntireVideo)
        #expect(timeline.removingEditorRange(0...10) == nil)
        #expect(timeline.removeEditorRange(0.08...0.30) == .leavesShortClip)
        #expect(timeline.removingEditorRange(0.08...0.30) == nil)
        #expect(timeline.removeEditorRange(0.05...9.99) == .leavesShortClip)
        #expect(timeline.removeEditorRange(2.0...2.0) == .emptyRange)

        // At 8x, a 0.05 s editor range marks 0.40 s of source with room for both survivors.
        let fast = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 16, speed: 8)
        ])
        let fastCut = try #require(fast.removingEditorRange(0.50...0.55))
        #expect(fastCut.segments.count == 2)
        #expect(abs(fastCut.segments[0].sourceStart - 0) < 0.0001)
        #expect(abs(fastCut.segments[0].sourceEnd - 4.0) < 0.0001)
        #expect(abs(fastCut.segments[1].sourceStart - 4.4) < 0.0001)
        #expect(abs(fastCut.segments[1].sourceEnd - 16.0) < 0.0001)

        // Exact boundary just below minimumDuration (0.11975 s) on a trimmed 2..8 s clip of a 10 s source:
        // removeEditorRange rejects it with .leavesShortClip using the same predicate as normalization,
        // and validatedForCommit never silently restores the full 0..10 s source.
        let trimmed = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 2, sourceEnd: 8)
        ])
        #expect(trimmed.removeEditorRange(0.11975...6.0) == .leavesShortClip)
        let subMinCandidate = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 2, sourceEnd: 2.11975)
        ])
        #expect(subMinCandidate.validatedForCommit(sourceDuration: 10) == nil)
        // Document recovery (default fallbackToFull: true) still restores 0..10 s for corrupted persisted clips.
        #expect(subMinCandidate.normalized(to: 10).segments.count == 1)
        #expect(abs(subMinCandidate.normalized(to: 10).segments[0].sourceStart - 0) < 0.0001)
        #expect(abs(subMinCandidate.normalized(to: 10).segments[0].sourceEnd - 10) < 0.0001)

        // Rounding-scale minimum-duration trim: clamping Clip 2's leading edge to 10 - 0.12
        // produces 10 - (10 - 0.12) == 0.11999999999999922; must keep Clip 2, not silently delete it.
        let clip1 = RecordingClipSegment(sourceStart: 0, sourceEnd: 5)
        let clip2 = RecordingClipSegment(sourceStart: 5, sourceEnd: 10)
        let twoClips = RecordingClipTimeline(segments: [clip1, clip2])
        var clampedMin = clip2
        clampedMin.sourceStart = clip2.sourceEnd - RecordingClipSegment.minimumDuration
        #expect(RecordingClipSegment.isPlayableDuration(clampedMin.duration))
        let trimmedTwo = try #require(twoClips.replacingAndValidating(clampedMin, sourceDuration: 10))
        #expect(trimmedTwo.segments.count == 2)
        #expect(trimmedTwo.segments[1].id == clip2.id)
        // A truly sub-minimum trim must reject rather than silently dropping Clip 2 and keeping only Clip 1.
        var tooShort = clip2
        tooShort.sourceStart = 9.95
        #expect(twoClips.replacingAndValidating(tooShort, sourceDuration: 10) == nil)

        // Editor-duration parity with playback and export: on 2..8 s at 8x (editor 0.75 s),
        // deleting editor 0.05..0.75 s leaves 0.40 s of source but only 0.05 s of editor time,
        // which playback/export cannot render; ripple delete and commit validation both reject it.
        let fastShort = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 2, sourceEnd: 8, speed: 8)
        ])
        #expect(fastShort.removeEditorRange(0.05...0.75) == .leavesShortClip)
        let unplayableSurvivor = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 2, sourceEnd: 2.4, speed: 8)
        ])
        #expect(!unplayableSurvivor.hasPlayableEditorDuration)
        #expect(unplayableSurvivor.validatedForCommit(sourceDuration: 10) == nil)
    }

    @Test func rangeMarkingTracksInOutAndReopensWhenInPassesOut() throws {
        let firstIn = try #require(StudioEditing.markedRange(current: nil, edge: .start, at: 3.0, duration: 10))
        #expect(firstIn == 3.0...10.0)

        let narrowedOut = try #require(StudioEditing.markedRange(current: firstIn, edge: .end, at: 6.5, duration: 10))
        #expect(narrowedOut == 3.0...6.5)

        // Short positive editor ranges (e.g. 0.05 s at 8x) are preserved when setting In before Out.
        let shortOut = try #require(StudioEditing.markedRange(current: nil, edge: .end, at: 0.55, duration: 2.0))
        let shortRange = try #require(StudioEditing.markedRange(current: shortOut, edge: .start, at: 0.50, duration: 2.0))
        #expect(abs(shortRange.lowerBound - 0.50) < 0.0001 && abs(shortRange.upperBound - 0.55) < 0.0001)

        // Moving In past Out opens to the end until O is pressed again.
        let reopened = try #require(StudioEditing.markedRange(current: narrowedOut, edge: .start, at: 7.0, duration: 10))
        #expect(reopened == 7.0...10.0)

        // Marking Out first anchors from 0.
        let outOnly = try #require(StudioEditing.markedRange(current: nil, edge: .end, at: 4.0, duration: 10))
        #expect(outOnly == 0...4.0)
    }

    // MARK: - Markers across cuts, speed changes, and reordering

    @Test func markersStayOnFootageAcrossCutsAndReorderingAndGuideNavigation() throws {
        let m1 = RecordingMarker(sourceTime: 2.0, note: "Intro")
        let m2 = RecordingMarker(sourceTime: 5.0)
        let m3 = RecordingMarker(sourceTime: 8.5, note: "Finale")
        let markers = [m1, m2, m3]

        let full = RecordingClipTimeline.full(sourceDuration: 10)
        let initialTimes = StudioEditing.markerEditorTimes(markers, in: full)
        #expect(initialTimes.map(\.time) == [2.0, 5.0, 8.5])

        // Cut source 4..6 (editor 4..6): m2 drops out of sight, m3 moves earlier by 2 s.
        let cut = try #require(full.removingEditorRange(4.0...6.0))
        let afterCut = StudioEditing.markerEditorTimes(markers, in: cut)
        #expect(afterCut.map(\.marker.id) == [m1.id, m3.id])
        #expect(abs(afterCut[0].time - 2.0) < 0.0001)
        #expect(abs(afterCut[1].time - 6.5) < 0.0001)

        // Reorder so second clip (source 6..10) plays before first clip (source 0..4):
        // m3 (source 8.5) now sits at editor 2.5, before m1 (source 2.0) at editor 6.0.
        let reordered = try #require(cut.moving(segmentID: cut.segments[1].id, to: 0))
        let afterReorder = StudioEditing.markerEditorTimes(markers, in: reordered)
        #expect(afterReorder.map(\.marker.id) == [m3.id, m1.id])
        #expect(abs(afterReorder[0].time - 2.5) < 0.0001)
        #expect(abs(afterReorder[1].time - 6.0) < 0.0001)

        // Edit points merge clip cuts + marker times + audio edges in order for ↑/↓.
        let points = StudioEditing.editPoints(
            timeline: reordered,
            markerTimes: afterReorder.map(\.time),
            audioClipEdges: [1.0, 5.0],
            duration: reordered.duration
        )
        #expect(points == [0.0, 1.0, 2.5, 4.0, 5.0, 6.0, 8.0])
        #expect(StudioEditing.nextEditPoint(from: 0.0, in: points, duration: reordered.duration, forward: true) == 1.0)
        #expect(StudioEditing.nextEditPoint(from: 2.5, in: points, duration: reordered.duration, forward: true) == 4.0)
        #expect(StudioEditing.nextEditPoint(from: 6.0, in: points, duration: reordered.duration, forward: false) == 5.0)
        #expect(StudioEditing.nextEditPoint(from: 0.0, in: points, duration: reordered.duration, forward: false) == 0.0)

        // Markers round-trip cleanly via JSON Codable.
        let encoded = try JSONEncoder().encode(markers)
        let decoded = try JSONDecoder().decode([RecordingMarker].self, from: encoded)
        #expect(decoded == markers)

        // Chapters also stay visible and ordered in playback time after clip reordering.
        let chapters = [
            RecordingChapter(title: "Early", start: 1.5),
            RecordingChapter(title: "Late", start: 7.5),
        ]
        let mappedChapters = RecordingChapterPlanner.mapped(chapters, through: reordered)
        #expect(mappedChapters.map(\.title) == ["Late", "Early"])
        #expect(abs(mappedChapters[0].start - 1.5) < 0.0001)
        #expect(abs(mappedChapters[1].start - 5.5) < 0.0001)

        // Half-open lookup at a reordered join: [0..4, 8..12, 4..8].
        // Source 4.0 plays at editor 8.0 (start of clip 3), NOT editor 4.0 (end of clip 1).
        let joinTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4),
            RecordingClipSegment(sourceStart: 8, sourceEnd: 12),
            RecordingClipSegment(sourceStart: 4, sourceEnd: 8),
        ])
        let joinSource = StudioEditing.markerSourceTime(at: 8.0, in: joinTimeline)
        #expect(abs(joinSource - 4.0) < 0.0001)
        let joinMarker = RecordingMarker(sourceTime: joinSource)
        let joinMapped = StudioEditing.markerEditorTimes([joinMarker], in: joinTimeline)
        #expect(joinMapped.count == 1)
        #expect(abs(joinMapped[0].time - 8.0) < 0.0001)
        #expect(abs((joinTimeline.editorTime(forSourceEventTime: 4.0) ?? -1) - 8.0) < 0.0001)

        // Terminal-frame policy: dropping a marker at editor end (12.0, end of 4..8)
        // stays at the end of clip 3 (~11.999) instead of jumping to clip 2's start (source 8.0 at editor 4.0).
        let endSource = StudioEditing.markerSourceTime(at: 12.0, in: joinTimeline)
        #expect(endSource < 8.0 && endSource > 7.99)
        let endMapped = StudioEditing.markerEditorTimes([RecordingMarker(sourceTime: endSource)], in: joinTimeline)
        #expect(endMapped.count == 1)
        #expect(endMapped[0].time > 11.99 && endMapped[0].time <= 12.0)

        // Exact boundary chapter at source 4.0 maps to editor 8.0 on [0..4, 8..12, 4..8].
        let boundaryChapter = RecordingChapter(title: "Join", start: 4.0)
        let mappedJoinChapters = RecordingChapterPlanner.mapped([boundaryChapter], through: joinTimeline)
        #expect(mappedJoinChapters.count == 1)
        #expect(abs(mappedJoinChapters[0].start - 8.0) < 0.0001)

        // Event at an excised boundary (source 4.0 on [0..4, 8..12]) is excluded by half-open lookup.
        let excised = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4),
            RecordingClipSegment(sourceStart: 8, sourceEnd: 12),
        ])
        #expect(excised.editorTime(forSourceEventTime: 4.0) == nil)

        // Automatic chapter titles and openingSentenceTitle follow editor playback order:
        // [6..12, 0..6] with speech at source 7..8 (editor 1..2) and none in 0..6 (editor 6..12).
        let reorderedSpeech = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 6, sourceEnd: 12),
            RecordingClipSegment(sourceStart: 0, sourceEnd: 6),
        ])
        let spokenCues = [
            RecordingSubtitleCue(start: 7.0, end: 8.0, text: "First clip intro."),
        ]
        let autoChapters = [
            RecordingChapter(title: "Chapter 1", start: 6.0, autoTitle: true),
            RecordingChapter(title: "Chapter 2", start: 0.0, autoTitle: true),
        ]
        let titled = RecordingChapterPlanner.mapped(autoChapters, through: reorderedSpeech, cues: spokenCues)
        #expect(titled.count == 2)
        #expect(titled[0].title == "First clip intro")
        #expect(titled[1].title == "Chapter 2")

        // When both clips have speech, openingSentenceTitle picks the clip that now plays first.
        let twoClipCues = [
            RecordingSubtitleCue(start: 1.0, end: 2.0, text: "Later playback."),
            RecordingSubtitleCue(start: 7.0, end: 8.0, text: "Now plays first."),
        ]
        #expect(RecordingChapterPlanner.openingSentenceTitle(
            cues: twoClipCues, words: [], through: reorderedSpeech
        ) == "Now plays first")

        // Suggest Chapters on [24..48, 0..24] with narration bursts at source 4..6 (editor 28..30)
        // and source 28..30 (editor 4..6) walks editor playback order so BOTH bursts are suggested.
        let longReordered = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 24, sourceEnd: 48),
            RecordingClipSegment(sourceStart: 0, sourceEnd: 24),
        ])
        let burstCues = [
            RecordingSubtitleCue(start: 4.0, end: 6.0, text: "Second half topic."),
            RecordingSubtitleCue(start: 28.0, end: 30.0, text: "Opening topic."),
        ]
        let suggested = RecordingChapterPlanner.suggest(
            cues: burstCues, words: [], timeline: longReordered, keeping: []
        )
        let mappedSuggested = RecordingChapterPlanner.mapped(
            suggested, through: longReordered, cues: burstCues
        )
        #expect(mappedSuggested.count == 2)
        #expect(mappedSuggested[0].title == "Opening topic")
        #expect(abs(mappedSuggested[0].start - 4.0) < 0.0001)
        #expect(mappedSuggested[1].title == "Second half topic")
        #expect(abs(mappedSuggested[1].start - 28.0) < 0.0001)
    }

    // MARK: - Reordering, hardCuts, editorSpan, ViewportTimeline & PointerTimeline

    @Test @MainActor func normalizedKeepsClipOrderDeduplicatesOverlapsAndTracksHardCuts() throws {
        let first = RecordingClipSegment(sourceStart: 6, sourceEnd: 10, speed: 1)
        let second = RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 1)
        let overlappingThird = RecordingClipSegment(sourceStart: 3, sourceEnd: 7, speed: 1)

        let raw = RecordingClipTimeline(segments: [first, second, overlappingThird])
        let normalized = raw.normalized(to: 12)

        // Clip order is preserved (6..10 stays first), and overlappingThird trims to 4..6
        // without repeating any moment already claimed by earlier clips.
        #expect(normalized.segments.count == 3)
        #expect(normalized.segments[0].id == first.id)
        #expect(normalized.segments[0].sourceStart == 6 && normalized.segments[0].sourceEnd == 10)
        #expect(normalized.segments[1].id == second.id)
        #expect(normalized.segments[1].sourceStart == 0 && normalized.segments[1].sourceEnd == 4)
        #expect(normalized.segments[2].id == overlappingThird.id)
        #expect(normalized.segments[2].sourceStart == 4 && normalized.segments[2].sourceEnd == 6)

        // Prior clip overlapping the middle of a later clip splits out every uncovered survivor in place.
        let middle = RecordingClipSegment(sourceStart: 4, sourceEnd: 6)
        let spanning = RecordingClipSegment(sourceStart: 0, sourceEnd: 10, speed: 2)
        let splitNormalized = RecordingClipTimeline(segments: [middle, spanning]).normalized(to: 10)
        #expect(splitNormalized.segments.count == 3)
        #expect(splitNormalized.segments[0].id == middle.id)
        #expect(abs(splitNormalized.segments[0].sourceStart - 4) < 0.0001 && abs(splitNormalized.segments[0].sourceEnd - 6) < 0.0001)
        #expect(splitNormalized.segments[1].id == spanning.id)
        #expect(abs(splitNormalized.segments[1].sourceStart - 0) < 0.0001 && abs(splitNormalized.segments[1].sourceEnd - 4) < 0.0001)
        #expect(splitNormalized.segments[1].speed == 2)
        #expect(splitNormalized.segments[2].id != spanning.id && splitNormalized.segments[2].id != middle.id)
        #expect(abs(splitNormalized.segments[2].sourceStart - 6) < 0.0001 && abs(splitNormalized.segments[2].sourceEnd - 10) < 0.0001)
        #expect(splitNormalized.segments[2].speed == 2)

        // Jumping from 6..10 to 0..4 is a hard cut at editor 4.0; advancing 0..4 to 4..6 is not.
        #expect(!normalized.isInRecordingOrder)
        #expect(normalized.hardCuts.count == 1)
        #expect(abs(normalized.hardCuts[0] - 4.0) < 0.0001)

        // editorSpan returns the longest touching run for a source range split across reordered clips.
        // Source 2..9 overlaps:
        //   - clip 0 (6..10) -> editor 0..3 (length 3)
        //   - clip 1 (0..4)  -> editor 6..8 (length 2)
        //   - clip 2 (4..6)  -> editor 8..10 (length 2) -> touching clip 1: combined editor 6..10 (length 4)!
        let span = try #require(normalized.editorSpan(overlapping: 2, sourceEnd: 9))
        #expect(abs(span.lowerBound - 6.0) < 0.0001)
        #expect(abs(span.upperBound - 10.0) < 0.0001)

        // studioOccupiedLaneSpans emits ALL surviving runs plus a zero-width hardCut barrier at 4.0.
        let zoomCue = ZoomCue(start: 2, end: 9)
        let laneSpans = studioOccupiedLaneSpans(cues: [zoomCue], clipTimeline: normalized)
        let cueSpans = laneSpans.filter { $0.id == zoomCue.id }
        #expect(cueSpans.count == 2)
        #expect(abs(cueSpans[0].editorStart - 0.0) < 0.0001 && abs(cueSpans[0].editorEnd - 3.0) < 0.0001)
        #expect(abs(cueSpans[1].editorStart - 6.0) < 0.0001 && abs(cueSpans[1].editorEnd - 10.0) < 0.0001)
        #expect(laneSpans.contains { $0.id != zoomCue.id && abs($0.editorStart - 4.0) < 0.0001 && abs($0.editorEnd - 4.0) < 0.0001 })

        // On [8..12, 0..4], drawing or moving a zoom across the backward join at editor 4.0
        // stays constrained to one monotonic source run rather than collapsing to zero.
        let backward = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 8, sourceEnd: 12),
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4),
        ])
        let emptySpans = studioOccupiedLaneSpans(cues: [], clipTimeline: backward)
        let gap = try #require(studioGap(around: 3.0, toward: 5.0, spans: emptySpans, duration: backward.duration))
        #expect(abs(gap.lowerBound - 0.0) < 0.0001 && abs(gap.upperBound - 4.0) < 0.0001)
        let draft = try #require(studioDraftRange(anchor: 3.0, pointer: 5.0, gap: gap, minimumLength: ZoomCue.minimumDuration))
        #expect(abs(draft.lowerBound - 3.0) < 0.0001 && abs(draft.upperBound - 4.0) < 0.0001)
        let drawn = try #require(studioDrawnSourceSpan(
            for: 3.0...5.0,
            clipTimeline: backward,
            sourceDuration: 12,
            among: [],
            minimum: ZoomCue.minimumDuration
        ))
        #expect(abs(drawn.lowerBound - 11.0) < 0.0001 && abs(drawn.upperBound - 12.0) < 0.0001)

        let movedZoom = studioMovedSourceRange(clipTimeline: backward, editorStart: 3.0, editorLength: 2.0)
        #expect(abs(movedZoom.start - 10.0) < 0.0001 && abs(movedZoom.end - 12.0) < 0.0001)

        // Cue covering source 0..4 over touching reversed clips [2..4, 0..2]:
        // editorSpan breaks at the backward join so the block displays one monotonic piece (0..2 = source 2..4),
        // and trimming is disabled for multi-run cues in both hit-testing and trim resolution so the other
        // surviving clip (0..2) never loses its zoom.
        let touchingReversed = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 2, sourceEnd: 4),
            RecordingClipSegment(sourceStart: 0, sourceEnd: 2),
        ])
        let spanningCue = ZoomCue(start: 0, end: 4)
        let spanningRuns = touchingReversed.editorRuns(overlapping: spanningCue.start, sourceEnd: spanningCue.end)
        #expect(spanningRuns.count == 2)
        let displayedSpan = try #require(touchingReversed.editorSpan(overlapping: spanningCue.start, sourceEnd: spanningCue.end))
        #expect(abs(displayedSpan.lowerBound - 0.0) < 0.0001 && abs(displayedSpan.upperBound - 2.0) < 0.0001)
        let displayedBlock = StudioLaneBlock(
            item: spanningCue,
            editorStart: displayedSpan.lowerBound,
            editorEnd: displayedSpan.upperBound,
            allowsTrim: spanningRuns.count <= 1
        )
        #expect(!displayedBlock.allowsTrim)
        #expect(studioTrimmedZoomSourceTime(
            for: StudioBlockEdit(base: displayedBlock, kind: .trimTrailing, delta: -0.5),
            clipTimeline: touchingReversed
        ) == nil)
        #expect(studioTrimmedZoomSourceTime(
            for: StudioBlockEdit(base: displayedBlock, kind: .trimLeading, delta: 0.5),
            clipTimeline: touchingReversed
        ) == nil)
        // Pointer hit-tester returns .body (never .edge) for non-trimmable multi-run blocks whether selected or not.
        let scale = StudioTimelineScale(viewportWidth: 400, duration: 4, zoom: 1)
        let frame = StudioBlockFrame(editorStart: 0, editorEnd: 2, scale: scale)
        let unselectedTester = StudioBlockHitTester(
            entries: [.init(id: spanningCue.id, frame: frame, allowsTrim: false)],
            selectedID: nil
        )
        #expect(unselectedTester.target(atX: frame.minX + 2) == .body(spanningCue.id))
        #expect(unselectedTester.target(atX: frame.maxX - 2) == .body(spanningCue.id))
        let selectedTester = StudioBlockHitTester(
            entries: [.init(id: spanningCue.id, frame: frame, allowsTrim: false)],
            selectedID: spanningCue.id
        )
        #expect(selectedTester.target(atX: frame.minX + 2) == .body(spanningCue.id))
        #expect(selectedTester.target(atX: frame.maxX - 2) == .body(spanningCue.id))

        // moving(segmentID:to:) reorders and returns nil for no-op or unknown ID.
        let moved = try #require(normalized.moving(segmentID: overlappingThird.id, to: 0))
        #expect(moved.segments.map(\.id) == [overlappingThird.id, first.id, second.id])
        #expect(normalized.moving(segmentID: first.id, to: 0) == nil)
        #expect(normalized.moving(segmentID: UUID(), to: 0) == nil)
    }

    @Test func reorderedHardCutsSnapViewportAndPointerTimelinesWithoutEasingBackwards() throws {
        // Clip 1 (later footage): source 5..10 (editor 0..5)
        // Clip 2 (earlier footage): source 0..5 (editor 5..10) -> hard cut at editor 5.0
        let clipLater = RecordingClipSegment(sourceStart: 5, sourceEnd: 10, speed: 1)
        let clipEarlier = RecordingClipSegment(sourceStart: 0, sourceEnd: 5, speed: 1)
        let reordered = RecordingClipTimeline(segments: [clipLater, clipEarlier])
        #expect(reordered.hardCuts == [5.0])

        let capture = PointerCaptureFile(
            travel: [
                PointerTravelSample(time: 0.0, x: 0.1, y: 0.1),
                PointerTravelSample(time: 2.0, x: 0.1, y: 0.1),
                PointerTravelSample(time: 4.5, x: 0.1, y: 0.1),
                PointerTravelSample(time: 5.0, x: 0.9, y: 0.9),
                PointerTravelSample(time: 7.5, x: 0.9, y: 0.9),
                PointerTravelSample(time: 9.9, x: 0.9, y: 0.9),
            ],
            presses: [
                PointerPressEvent(time: 0.1, x: 0.1, y: 0.1, button: 0, phase: .down),
                PointerPressEvent(time: 0.2, x: 0.1, y: 0.1, button: 0, phase: .up),
                PointerPressEvent(time: 9.85, x: 0.9, y: 0.9, button: 0, phase: .down),
                PointerPressEvent(time: 9.9, x: 0.9, y: 0.9, button: 0, phase: .up),
            ]
        )

        // 1. ViewportTimeline: zoom cue at 5..10 (2.5x pinned top-right) and zoom cue at 0..5 (1.5x pinned bottom-left).
        let cueLater = ZoomCue(
            start: 5.0,
            end: 10.0,
            zoom: 2.5,
            anchorMode: .pinnedAnchor,
            pinnedPoint: CGPoint(x: 0.8, y: 0.8)
        )
        let cueEarlier = ZoomCue(
            start: 0.0,
            end: 5.0,
            zoom: 1.5,
            anchorMode: .pinnedAnchor,
            pinnedPoint: CGPoint(x: 0.2, y: 0.2)
        )
        let viewport = ViewportTimeline.build(
            cues: [cueEarlier, cueLater],
            capture: capture,
            clipTimeline: reordered
        )

        // Just before the hard cut (editor 4.95): settled near 2.5x, (0.8, 0.8).
        let beforeCut = viewport.frame(at: 4.95)
        #expect(abs(beforeCut.magnification - 2.5) < 0.05)
        #expect(beforeCut.anchor.x > 0.75)

        // Right at the hard cut (editor 5.0): snapped immediately to 1.5x and clamped (0.2, 0.2) -> (1/3, 1/3).
        let atCut = viewport.frame(at: 5.0)
        #expect(abs(atCut.magnification - 1.5) < 0.01)
        let expectedClampedAnchor = 1.0 / (2.0 * 1.5) // 0.3333...
        #expect(abs(atCut.anchor.x - expectedClampedAnchor) < 0.01)
        #expect(abs(atCut.anchor.y - expectedClampedAnchor) < 0.01)

        // 2. PointerTimeline: pointer sits at (0.9, 0.9) before hard cut, snaps to (0.1, 0.1) at hard cut
        // with no glide across the screen, no artificial tilt spike, and no press pulse bleed.
        let pointer = PointerTimeline.build(
            capture: capture,
            duration: 10,
            recordingSizeInPoints: CGSize(width: 1000, height: 1000),
            clipTimeline: reordered
        )
        let pointerBefore = try #require(pointer.frame(at: 4.95))
        #expect(abs(pointerBefore.location.x - 0.9) < 0.05)
        #expect(abs(pointerBefore.location.y - 0.9) < 0.05)

        let pointerAtCut = try #require(pointer.frame(at: 5.0))
        #expect(abs(pointerAtCut.location.x - 0.1) < 0.01)
        #expect(abs(pointerAtCut.location.y - 0.1) < 0.01)
        #expect(abs(pointerAtCut.tiltDegrees) < 0.01)
        // The press at source 9.85 (editor 4.85) must not bleed its ripple past the hard cut at 5.0.
        #expect(pointerAtCut.press == nil)

        // 3. Fractional hard cut at editor 1.004 s (between 120 Hz samples 120 and 121):
        // neither ViewportTimeline nor PointerTimeline blends across the cut, and an orphan press
        // 50 ms before the cut (source 6.954) does not carry its 150 ms hold across the cut.
        let fractionalTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 6.0, sourceEnd: 7.004),
            RecordingClipSegment(sourceStart: 0.0, sourceEnd: 2.0),
        ])
        let fractionalCapture = PointerCaptureFile(
            travel: [
                PointerTravelSample(time: 0.0, x: 0.1, y: 0.1),
                PointerTravelSample(time: 1.9, x: 0.1, y: 0.1),
                PointerTravelSample(time: 6.0, x: 0.9, y: 0.9),
                PointerTravelSample(time: 7.0, x: 0.9, y: 0.9),
            ],
            presses: [
                PointerPressEvent(time: 6.954, x: 0.9, y: 0.9, button: 0, phase: .down),
            ]
        )
        let fractionalViewport = ViewportTimeline.build(
            cues: [
                ZoomCue(start: 6.0, end: 7.1, zoom: 2.5, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.8, y: 0.8)),
                ZoomCue(start: 0.0, end: 2.0, zoom: 1.5, anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.2, y: 0.2)),
            ],
            capture: fractionalCapture,
            clipTimeline: fractionalTimeline
        )
        // Before 1.004 s (1.002 s): pre-cut side (2.5x), not blended toward 1.5x.
        #expect(abs(fractionalViewport.frame(at: 1.002).magnification - 2.5) < 0.05)
        // At exact 1.004 s: post-cut side (1.5x), not blended with 2.5x.
        #expect(abs(fractionalViewport.frame(at: 1.004).magnification - 1.5) < 0.01)

        let fractionalPointer = PointerTimeline.build(
            capture: fractionalCapture,
            duration: 8.0,
            recordingSizeInPoints: CGSize(width: 1000, height: 1000),
            clipTimeline: fractionalTimeline
        )
        let fBefore = try #require(fractionalPointer.frame(at: 1.002))
        #expect(abs(fBefore.location.x - 0.9) < 0.05)
        let fAtCut = try #require(fractionalPointer.frame(at: 1.004))
        #expect(abs(fAtCut.location.x - 0.1) < 0.01)
        #expect(fAtCut.press == nil)
        // Orphan press hold must end at the hard cut, so incoming clip keeps full magnification (1.0, not 0.8).
        let fAfter = try #require(fractionalPointer.frame(at: 1.02))
        #expect(abs(fAfter.magnification - 1.0) < 0.01)

        // 4. Exact sampled hard cut at editor 1.0 s where an outgoing orphan press ends at 1.0 s
        // AND an incoming press starts at 1.0 s (via anticipation): the first incoming sample at 1.0 s
        // advances past the outgoing interval and reflects the incoming clip's pressed state (0.8).
        let alignedTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 6.0, sourceEnd: 7.0),
            RecordingClipSegment(sourceStart: 0.0, sourceEnd: 2.0),
        ])
        let alignedCapture = PointerCaptureFile(
            travel: [
                PointerTravelSample(time: 0.0, x: 0.1, y: 0.1),
                PointerTravelSample(time: 1.9, x: 0.1, y: 0.1),
                PointerTravelSample(time: 6.0, x: 0.9, y: 0.9),
                PointerTravelSample(time: 7.0, x: 0.9, y: 0.9),
            ],
            presses: [
                PointerPressEvent(time: 6.95, x: 0.9, y: 0.9, button: 0, phase: .down),
                PointerPressEvent(time: 0.02, x: 0.1, y: 0.1, button: 0, phase: .down),
                PointerPressEvent(time: 0.15, x: 0.1, y: 0.1, button: 0, phase: .up),
            ]
        )
        let alignedPointer = PointerTimeline.build(
            capture: alignedCapture,
            duration: 8.0,
            recordingSizeInPoints: CGSize(width: 1000, height: 1000),
            clipTimeline: alignedTimeline
        )
        let incomingAtExactCut = try #require(alignedPointer.frame(at: 1.0))
        #expect(abs(incomingAtExactCut.location.x - 0.1) < 0.01)
        #expect(abs(incomingAtExactCut.magnification - 0.8) < 0.01)
    }

    // MARK: - Snap point selection & trim snapping / reorder control

    @Test func snapPointSelectionPicksNearestWithinToleranceAndComputesReorderAwareTrimBounds() throws {
        let points = StudioEditing.clipSnapPoints(
            playhead: 5.0,
            markers: [2.2, 8.0],
            recordedClicks: [5.08, 9.5],
            audioClipEdges: [3.0, 5.03]
        )
        // 5.02 is closer to 5.03 (0.01) than to 5.0 (0.02) or 5.08 (0.06).
        #expect(abs(StudioEditing.snapped(5.02, to: points, tolerance: 0.1) - 5.03) < 0.0001)
        // Exact hit still returns the matched snap target so the guide appears even when delta == 0.
        #expect(StudioEditing.snapTarget(for: 5.0, in: points, tolerance: 0.1) == 5.0)
        #expect(StudioEditing.snapTarget(for: 6.5, in: points, tolerance: 0.1) == nil)
        // Outside tolerance -> unchanged.
        #expect(StudioEditing.snapped(6.5, to: points, tolerance: 0.1) == 6.5)
        // Zero/invalid tolerance -> unchanged.
        #expect(StudioEditing.snapped(5.02, to: points, tolerance: 0) == 5.02)

        // Reorder-aware trim bounds: clip B (6..8) plays first, clip A (0..3) plays second.
        // Clip B can expand left to 3 (end of clip A in source time), and right to sourceDuration 10.
        let clipA = RecordingClipSegment(sourceStart: 0, sourceEnd: 3, speed: 1)
        let clipB = RecordingClipSegment(sourceStart: 6, sourceEnd: 8, speed: 1)
        let reordered = RecordingClipTimeline(segments: [clipB, clipA])

        let boundsB = try #require(StudioEditing.trimBounds(forClipID: clipB.id, in: reordered, sourceDuration: 10))
        #expect(boundsB.previousEnd == 3)
        #expect(boundsB.nextStart == 10)

        let boundsA = try #require(StudioEditing.trimBounds(forClipID: clipA.id, in: reordered, sourceDuration: 10))
        #expect(boundsA.previousEnd == 0)
        #expect(boundsA.nextStart == 6)

        // Reorder insertion index math.
        #expect(StudioEditing.reorderInsertionIndex(atEditorTime: 0.5, in: reordered) == 0)
        #expect(StudioEditing.reorderInsertionIndex(atEditorTime: 1.5, in: reordered) == 1)
        #expect(StudioEditing.reorderInsertionIndex(atEditorTime: 4.5, in: reordered) == 2)
        #expect(StudioEditing.reorderDestinationIndex(from: 0, insertionIndex: 0) == nil)
        #expect(StudioEditing.reorderDestinationIndex(from: 0, insertionIndex: 1) == nil)
        #expect(StudioEditing.reorderDestinationIndex(from: 0, insertionIndex: 2) == 1)
        #expect(StudioEditing.reorderDestinationIndex(from: 1, insertionIndex: 0) == 0)
    }

    @Test @MainActor func clipStripTrimSnapsInvertsWithCommandPreviewsSourceAndReordersWithOptionDrag() throws {
        // 10 s timeline across 500 pt -> 50 pt/s, tolerance 7 pt = 0.14 s.
        let control = RecordingClipTimelineControl(frame: NSRect(x: 0, y: 0, width: 500, height: 52))
        let store = RecordingTimelineThumbnailStore()
        let first = RecordingClipSegment(sourceStart: 0, sourceEnd: 5, speed: 1)
        let second = RecordingClipSegment(sourceStart: 5, sourceEnd: 10, speed: 1)
        let timeline = RecordingClipTimeline(segments: [first, second])

        control.update(
            timeline: timeline,
            sourceDuration: 10,
            thumbnails: store,
            selectedClipID: first.id,
            playheadTime: 4.0
        )
        // Even with empty static snapPoints, the strip snaps to its own playheadTime (4.0 s)
        // so the dock never has to read currentTime on every playback tick.
        control.snapPoints = []
        control.snaps = true

        var guides: [TimeInterval?] = []
        var previews: [TimeInterval?] = []
        var committed: RecordingClipSegment?
        control.snapGuideDidChange = { guides.append($0) }
        control.trimPreviewDidChange = { previews.append($0) }
        control.trimDidCommit = { committed = $0 }

        func mouse(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: x, y: 26),
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }

        // Grab trailing edge of clip 1 (~x = 248) and drag near snap point 4.0 s (~x = 203 -> 4.06 s, within 0.14 s).
        control.mouseDown(with: try mouse(.leftMouseDown, x: 248))
        #expect(previews.last != nil)
        control.mouseDragged(with: try mouse(.leftMouseDragged, x: 203))
        #expect(guides.last == 4.0)
        // Fixed scale during trim: dragged trailing edge aligns with the 4.0 s snap guide (~x = 200),
        // not shifted rightward to ~222 by dividing by the shorter 9 s draft duration.
        let snappedFrame = try #require(control.clipFrame(for: first.id))
        let guideX = control.xCoordinate(for: 4.0)
        #expect(abs(guideX - 200.0) < 1.5)
        #expect(abs((snappedFrame.maxX + 2.0) - guideX) < 0.5)

        // Holding ⌘ while dragging turns snapping off and clears the snap guide.
        control.mouseDragged(with: try mouse(.leftMouseDragged, x: 203, flags: .command))
        #expect(guides.last == Optional<TimeInterval>.none)

        // Releasing ⌘ catches the snap point again; an exact hit at 5.0 s (playhead/target) also shows the guide.
        control.snapPoints = [5.0]
        control.mouseDragged(with: try mouse(.leftMouseDragged, x: 248))
        #expect(guides.last == 5.0)
        control.snapPoints = []
        control.mouseDragged(with: try mouse(.leftMouseDragged, x: 203))
        #expect(guides.last == 4.0)
        control.mouseUp(with: try mouse(.leftMouseUp, x: 203))
        #expect(guides.last == Optional<TimeInterval>.none)
        #expect(previews.last == Optional<TimeInterval>.none)
        let trimmed = try #require(committed)
        #expect(abs(trimmed.sourceEnd - 4.0) < 0.001)

        // ⌥-drag on clip 2 to the start of clip 1 clears stale hover preview and requests reorder to index 0.
        var reordered: (UUID, Int)?
        var lastHover: TimeInterval? = 9.0
        control.reorderRequested = { reordered = ($0, $1) }
        control.hoverTimeDidChange = { lastHover = $0 }
        control.update(
            timeline: timeline,
            sourceDuration: 10,
            thumbnails: store,
            selectedClipID: second.id,
            playheadTime: 4.0
        )
        control.mouseMoved(with: try mouse(.mouseMoved, x: 375))
        #expect(lastHover != nil)
        control.mouseDown(with: try mouse(.leftMouseDown, x: 375, flags: .option))
        #expect(lastHover == nil)
        control.mouseDragged(with: try mouse(.leftMouseDragged, x: 40, flags: .option))
        // Drawing mid-reorder renders the ghost + insertion bar without crashing.
        if let rep = control.bitmapImageRepForCachingDisplay(in: control.bounds) {
            control.cacheDisplay(in: control.bounds, to: rep)
        }
        control.mouseUp(with: try mouse(.leftMouseUp, x: 40, flags: .option))
        let result = try #require(reordered)
        #expect(result.0 == second.id)
        #expect(result.1 == 0)

        // VoiceOver: with selection clear, activating Clip 2 selects it and exposes named reorder actions.
        var a11ySelected: UUID?
        var a11yReordered: (UUID, Int)?
        control.selectionDidChange = { a11ySelected = $0 }
        control.reorderRequested = { a11yReordered = ($0, $1) }
        control.update(
            timeline: timeline,
            sourceDuration: 10,
            thumbnails: store,
            selectedClipID: nil,
            playheadTime: 0
        )
        let children = try #require(control.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.count == 2)
        #expect(children[1].accessibilityPerformPress())
        #expect(a11ySelected == second.id)
        let actions = try #require(children[1].accessibilityCustomActions())
        let moveEarlier = try #require(actions.first { $0.name == "Move Clip Earlier" })
        #expect(moveEarlier.handler?() == true)
        #expect(a11yReordered?.0 == second.id && a11yReordered?.1 == 0)
        // Clip 1 can only move later, not earlier.
        let clip1Actions = try #require(children[0].accessibilityCustomActions())
        #expect(clip1Actions.map(\.name) == ["Move Clip Later"])
        // Ruler accessibility value exposes both marked range bounds when active.
        #expect(StudioEditing.rulerAccessibilityValue(duration: 12, range: 2.4...5.5) == "Marked range 0:02.4 to 0:05.5")
        #expect(StudioEditing.rulerAccessibilityValue(duration: 12, range: nil) == "Duration 0:12")
    }

    // MARK: - Key handler standing aside in text fields & coexisting with playback keys

    @Test @MainActor func editingKeyHandlerStandsAsideInTextFieldsCropAndSheetsAndPreservesExistingKeys() throws {
        // Active Studio window allows key handling.
        #expect(StudioEditing.shouldHandleKeyEvent(
            isLoaded: true,
            isRestoringDocument: false,
            isEditingSourceRegion: false,
            isWindowMatch: true,
            hasAttachedSheet: false,
            isEditingText: false
        ))

        // Stands aside when a text field has focus, crop/redaction is open, a sheet is attached, or unloaded.
        #expect(!StudioEditing.shouldHandleKeyEvent(
            isLoaded: true, isRestoringDocument: false, isEditingSourceRegion: false,
            isWindowMatch: true, hasAttachedSheet: false, isEditingText: true
        ))
        #expect(!StudioEditing.shouldHandleKeyEvent(
            isLoaded: true, isRestoringDocument: false, isEditingSourceRegion: true,
            isWindowMatch: true, hasAttachedSheet: false, isEditingText: false
        ))
        #expect(!StudioEditing.shouldHandleKeyEvent(
            isLoaded: true, isRestoringDocument: false, isEditingSourceRegion: false,
            isWindowMatch: true, hasAttachedSheet: true, isEditingText: false
        ))
        #expect(!StudioEditing.shouldHandleKeyEvent(
            isLoaded: false, isRestoringDocument: false, isEditingSourceRegion: false,
            isWindowMatch: true, hasAttachedSheet: false, isEditingText: false
        ))

        // Bare-letter editing keys: I, O, M, N.
        #expect(StudioEditing.keyAction(keyCode: 34, characters: "i", modifiers: [], isARepeat: false) == .markRange(.start))
        #expect(StudioEditing.keyAction(keyCode: 31, characters: "o", modifiers: [], isARepeat: false) == .markRange(.end))
        #expect(StudioEditing.keyAction(keyCode: 46, characters: "m", modifiers: [], isARepeat: false) == .toggleMarker)
        #expect(StudioEditing.keyAction(keyCode: 45, characters: "n", modifiers: [], isARepeat: false) == .toggleSnapping)

        // Holding bare letters consumes repeats rather than beeping or toggling rapidly.
        #expect(StudioEditing.keyAction(keyCode: 46, characters: "m", modifiers: [], isARepeat: true) == .consume)
        #expect(StudioEditing.keyAction(keyCode: 45, characters: "n", modifiers: [], isARepeat: true) == .consume)

        // ⌥X clears range only when a range is marked; plain X is untouched.
        #expect(StudioEditing.keyAction(keyCode: 7, characters: "x", modifiers: .option, isARepeat: false, hasRangeSelection: true) == .clearRange)
        #expect(StudioEditing.keyAction(keyCode: 7, characters: "x", modifiers: .option, isARepeat: false, hasRangeSelection: false) == nil)
        #expect(StudioEditing.keyAction(keyCode: 7, characters: "x", modifiers: [], isARepeat: false, hasRangeSelection: true) == nil)

        // ⌫ deletes a selected block/clip when present, or the marked range otherwise.
        #expect(StudioEditing.keyAction(keyCode: 51, characters: "\u{7f}", modifiers: [], isARepeat: false, hasRangeSelection: true, hasDeletableSelection: false) == .deleteRange)
        #expect(StudioEditing.keyAction(keyCode: 51, characters: "\u{7f}", modifiers: [], isARepeat: false, hasRangeSelection: false, hasDeletableSelection: false) == nil)
        #expect(StudioEditing.keyAction(keyCode: 51, characters: "\u{7f}", modifiers: [], isARepeat: false, hasRangeSelection: true, hasDeletableSelection: true) == .deleteSelection)
        #expect(StudioEditing.keyAction(keyCode: 51, characters: "\u{7f}", modifiers: [], isARepeat: false, hasFocusedControl: true, hasRangeSelection: true, hasDeletableSelection: false) == nil)

        // S splits at playhead; C splits at hover only when hovering; both yield to modifiers/repeats.
        #expect(StudioEditing.keyAction(keyCode: 1, characters: "s", modifiers: [], isARepeat: false) == .splitAtPlayhead)
        #expect(StudioEditing.keyAction(keyCode: 1, characters: "s", modifiers: [], isARepeat: true) == .consume)
        #expect(StudioEditing.keyAction(keyCode: 8, characters: "c", modifiers: [], isARepeat: false, hasHoverTime: true) == .splitAtHover)
        #expect(StudioEditing.keyAction(keyCode: 8, characters: "c", modifiers: [], isARepeat: false, hasHoverTime: false) == nil)

        // ↑ / ↓ jump edit points, and yield to focused controls.
        #expect(StudioEditing.keyAction(keyCode: 126, characters: nil, modifiers: [], isARepeat: false) == .seekToEditPoint(forward: false))
        #expect(StudioEditing.keyAction(keyCode: 125, characters: nil, modifiers: [], isARepeat: false) == .seekToEditPoint(forward: true))
        #expect(StudioEditing.keyAction(keyCode: 126, characters: nil, modifiers: [], isARepeat: false, hasFocusedControl: true) == nil)
        #expect(StudioEditing.keyAction(keyCode: 125, characters: nil, modifiers: [], isARepeat: false, hasFocusedControl: true) == nil)

        // Existing J/K/L, ←/→, Home/End, Space, ⌘-shortcuts pass through untouched.
        for (code, ch) in [(38 as UInt16, "j"), (40, "k"), (37, "l"), (49, " ")] {
            #expect(StudioEditing.keyAction(keyCode: code, characters: ch, modifiers: [], isARepeat: false) == nil)
        }
        #expect(StudioEditing.keyAction(keyCode: 123, characters: nil, modifiers: [], isARepeat: false) == nil)
        #expect(StudioEditing.keyAction(keyCode: 124, characters: nil, modifiers: [], isARepeat: false) == nil)
        #expect(StudioEditing.keyAction(keyCode: 34, characters: "i", modifiers: .command, isARepeat: false) == nil)

        // Hovering the clip strip never steals first responder from a text field, and the strip
        // honors allowsKeyboardShortcuts when crop/modal picking is active.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let strip = RecordingClipTimelineControl(frame: NSRect(x: 0, y: 40, width: 500, height: 52))
        window.contentView?.addSubview(textField)
        window.contentView?.addSubview(strip)
        window.makeFirstResponder(textField)
        let fieldEditor = window.firstResponder
        #expect(fieldEditor is NSText)

        let enterEvent = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 100, y: 66),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        strip.mouseEntered(with: enterEvent)
        #expect(window.firstResponder === fieldEditor)

        var splitCalled = false
        strip.splitRequested = { _ in splitCalled = true }
        strip.allowsKeyboardShortcuts = { false }
        let sEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ))
        strip.keyDown(with: sEvent)
        #expect(!splitCalled)
    }

    // MARK: - Webcam feed across backward cuts

    @Test func cameraFrameFeedRestartsAcrossBackwardCut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("camera.mov")

        // 4-second movie: 0s=Red, 1s=Green, 2s=Blue, 3s=White.
        let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (240, 20, 20),
            (20, 240, 20),
            (20, 20, 240),
            (240, 240, 240),
        ]
        try await writeSolidColorMovie(to: url, size: CGSize(width: 64, height: 64), colors: colors)

        let feed = try #require(try await RecordingCameraFrameFeed(url: url, offset: 0.2))
        defer { feed.cancel() }

        func sampleRGB(_ buffer: CVPixelBuffer) -> (r: Int, g: Int, b: Int) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buffer)
            let offset = 32 * bpr + 32 * 4
            return (Int(ptr[offset + 2]), Int(ptr[offset + 1]), Int(ptr[offset]))
        }

        // First clip: source 2..4 -> camera 2.2s (Blue) then 3.2s (White).
        let atBlue = try #require(try feed.latestFrame(at: 2.5))
        let blueRGB = sampleRGB(atBlue)
        #expect(blueRGB.b > 180 && blueRGB.r < 80)

        let atWhite = try #require(try feed.latestFrame(at: 3.5))
        let whiteRGB = sampleRGB(atWhite)
        #expect(whiteRGB.r > 180 && whiteRGB.g > 180 && whiteRGB.b > 180)

        // Backward cut to second clip: source 0..2 -> camera restarts to 0s (Red), then 1s (Green).
        let atRed = try #require(try feed.latestFrame(at: 0.0))
        let redRGB = sampleRGB(atRed)
        #expect(redRGB.r > 180 && redRGB.g < 80 && redRGB.b < 80)

        let atGreen = try #require(try feed.latestFrame(at: 1.5))
        let greenRGB = sampleRGB(atGreen)
        #expect(greenRGB.g > 180 && greenRGB.r < 80 && greenRGB.b < 80)
    }

    // MARK: - Shared captions & transcript runs across reordered clips

    @Test func sharedCaptionsAndTranscriptEmitSeparateRunsInEditorOrder() {
        // Clips [0..4, 8..12, 4..8]: cue over source 3..5 survives at editor 3..4 and 8..9,
        // NOT as one 3..9 span covering unrelated footage 8..12.
        let reordered = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4),
            RecordingClipSegment(sourceStart: 8, sourceEnd: 12),
            RecordingClipSegment(sourceStart: 4, sourceEnd: 8),
        ])
        let words: [RecordingTranscriptWord] = [
            .init(text: "before ", start: 3.0, end: 3.9),
            .init(text: "after", start: 4.1, end: 5.0),
            .init(text: "middle", start: 9.0, end: 10.0),
        ]
        let cues: [RecordingSubtitleCue] = [
            .init(start: 3.0, end: 5.0, text: "before after"),
            .init(start: 9.0, end: 10.0, text: "middle"),
        ]

        let shared = RecordingTranscript(words: words, cues: cues).sharedEntries(in: reordered)
        #expect(shared.cues.count == 3)
        #expect(shared.cues[0].text == "before")
        #expect(abs(shared.cues[0].start - 3.0) < 0.0001 && abs(shared.cues[0].end - 4.0) < 0.0001)
        #expect(shared.cues[1].text == "middle")
        #expect(abs(shared.cues[1].start - 5.0) < 0.0001 && abs(shared.cues[1].end - 6.0) < 0.0001)
        #expect(shared.cues[2].text == "after")
        #expect(abs(shared.cues[2].start - 8.0) < 0.0001 && abs(shared.cues[2].end - 9.0) < 0.0001)

        // Words are also emitted in editor playback order.
        #expect(shared.words.map(\.text) == ["before ", "middle", "after"])
        #expect(abs(shared.words[0].start - 3.0) < 0.0001)
        #expect(abs(shared.words[1].start - 5.0) < 0.0001)
        #expect(abs(shared.words[2].start - 8.1) < 0.0001)

        // Translated caption tracks map to separate touching runs in editor order too.
        let track = RecordingCaptionTrack(lang: "es", label: "Español", cues: [
            .init(start: 3.0, end: 5.0, text: "antes después"),
            .init(start: 9.0, end: 10.0, text: "medio"),
        ])
        let payload = CloudShareText.payload(summary: nil, tracks: [track]) { start, end in
            reordered.editorRuns(overlapping: start, sourceEnd: end).map { ($0.editorStart, $0.editorEnd) }
        }
        #expect(payload.tracks.count == 1)
        let mappedTrackCues = payload.tracks[0].cues
        #expect(mappedTrackCues.count == 3)
        #expect(abs(mappedTrackCues[0].start - 3.0) < 0.0001 && abs(mappedTrackCues[0].end - 4.0) < 0.0001)
        #expect(abs(mappedTrackCues[1].start - 5.0) < 0.0001 && abs(mappedTrackCues[1].end - 6.0) < 0.0001)
        #expect(abs(mappedTrackCues[2].start - 8.0) < 0.0001 && abs(mappedTrackCues[2].end - 9.0) < 0.0001)

        // Ambiguous partial corrected cue (two raw words corrected to one word, then cut in half)
        // is omitted from shared cues rather than resurrecting the original unedited word.
        let halfCut = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 1.0, sourceEnd: 2.0)
        ])
        let correctedTranscript = RecordingTranscript(
            words: [
                .init(text: "secret ", start: 0.0, end: 1.0),
                .init(text: "raw ", start: 1.0, end: 2.0),
            ],
            cues: [
                .init(start: 0.0, end: 2.0, text: "Redacted"),
            ]
        )
        #expect(correctedTranscript.sharedEntries(in: halfCut).cues.isEmpty)

        // Touching reversed clips [2..4, 0..2] break cue runs at the backward join and rebuild in editor order.
        let reversedAdjacent = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 2.0, sourceEnd: 4.0),
            RecordingClipSegment(sourceStart: 0.0, sourceEnd: 2.0),
        ])
        let reversedTranscript = RecordingTranscript(
            words: [
                .init(text: "first ", start: 0.5, end: 1.5),
                .init(text: "second", start: 2.5, end: 3.5),
            ],
            cues: [
                .init(start: 0.0, end: 4.0, text: "First Second"),
            ]
        )
        let reversedShared = reversedTranscript.sharedEntries(in: reversedAdjacent)
        #expect(reversedShared.cues.count == 2)
        #expect(reversedShared.cues[0].text == "Second")
        #expect(abs(reversedShared.cues[0].start - 0.0) < 0.0001 && abs(reversedShared.cues[0].end - 2.0) < 0.0001)
        #expect(reversedShared.cues[1].text == "First")
        #expect(abs(reversedShared.cues[1].start - 2.0) < 0.0001 && abs(reversedShared.cues[1].end - 4.0) < 0.0001)
    }

    // MARK: - Live trim preview of restored footage

    @Test func trimPreviewSwitchesToSourceAssetWhenRestoringCutFootage() throws {
        // After ripple-deleting source 4..6, extending clip 1's trailing edge to source 5.0
        // cannot be shown by the cut composition; it requests direct source-asset preview.
        let cut = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4),
            RecordingClipSegment(sourceStart: 6, sourceEnd: 10),
        ])
        // Inside current cut -> fast path on edited clock.
        #expect(StudioEditing.trimPreviewTarget(
            forSourceTime: 3.2,
            in: cut,
            sourceDuration: 10,
            usingSourceAsset: false
        ) == .editedTime(3.2))

        // Inside deleted gap (5.0) -> switches to source-asset preview at 5.0 (NOT boundary 6.0).
        #expect(StudioEditing.trimPreviewTarget(
            forSourceTime: 5.0,
            in: cut,
            sourceDuration: 10,
            usingSourceAsset: false
        ) == .sourceTime(5.0))

        // Once on source-asset preview during a drag, dragging back into 3.5 stays on source clock cleanly.
        #expect(StudioEditing.trimPreviewTarget(
            forSourceTime: 3.5,
            in: cut,
            sourceDuration: 10,
            usingSourceAsset: true
        ) == .sourceTime(3.5))

        // While a redacted cut rebuild is still preparing (no ready cut item yet), source preview is gated off.
        #expect(StudioEditing.trimPreviewTarget(
            forSourceTime: 5.0,
            in: cut,
            sourceDuration: 10,
            usingSourceAsset: false,
            hasReadyCutItem: false
        ) == nil)

        // Single-owner gate prevents competing cut/source redaction tasks from leaving source item active.
        var gate = StudioPlayerItemGate()
        let cutGen1 = gate.beginCutBuild(isAsync: true)
        #expect(!gate.isCutReady)
        let blockedSource = gate.beginSourcePreview(isAsync: true)
        #expect(blockedSource == nil) // blocked until cut is ready
        let finishedCut1 = gate.finishCutBuild(generation: cutGen1)
        #expect(finishedCut1)
        #expect(gate.isCutReady)

        // Start async source preview, then supersede it with a new cut rebuild: stale source task is rejected.
        let rawSourceGen = gate.beginSourcePreview(isAsync: true)
        let sourceGen = try #require(rawSourceGen)
        let cutGen2 = gate.beginCutBuild(isAsync: true)
        let staleFinish = gate.finishSourcePreview(generation: sourceGen)
        #expect(!staleFinish)
        let finishedCut2 = gate.finishCutBuild(generation: cutGen2)
        #expect(finishedCut2)
        #expect(!gate.isShowingSourcePreview)

        // Normal source preview -> release restores saved cut item cleanly.
        let rawSourceGen2 = gate.beginSourcePreview(isAsync: false)
        let sourceGen2 = try #require(rawSourceGen2)
        let activeFinish = gate.finishSourcePreview(generation: sourceGen2)
        #expect(activeFinish)
        let restored = gate.endSourcePreview()
        #expect(restored)
        #expect(!gate.isShowingSourcePreview && gate.isCutReady)
    }

    private func writeSolidColorMovie(
        to url: URL,
        size: CGSize,
        colors: [(r: UInt8, g: UInt8, b: UInt8)]
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let width = Int(size.width)
        let height = Int(size.height)
        for (index, color) in colors.enumerated() {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * bpr + x * 4
                    base[i] = color.b
                    base[i + 1] = color.g
                    base[i + 2] = color.r
                    base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(index), preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    // MARK: - Thumbnail store retry after missed tiles

    @Test @MainActor func thumbnailStoreRetiresMissedKeysAndRetriesWithBoundedAttempts() async throws {
        let store = RecordingTimelineThumbnailStore()
        let attemptsByKey = LockedAttemptBox()
        let redaction = RecordingRedaction(start: 0, end: 5, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))

        store.renderBatch = { _, requests, redactions in
            var results: [RecordingTimelineThumbnailStore.Sample] = []
            for req in requests {
                let count = attemptsByKey.record(key: req.key, tolerance: req.tolerance, redactionCount: redactions.count)
                // Tile 0 misses on attempt 1, succeeds on attempt 2 (with widened tolerance).
                if req.key == .init(level: 0, index: 0) {
                    if count >= 2 {
                        results.append(.init(key: req.key, image: NSImage(size: NSSize(width: 8, height: 8))))
                    }
                    continue
                }
                // Tile 1 always misses (verifies retry cap prevents infinite loop).
                if req.key == .init(level: 0, index: 1) {
                    continue
                }
                results.append(.init(key: req.key, image: NSImage(size: NSSize(width: 8, height: 8))))
            }
            return results
        }

        store.prepare(url: URL(fileURLWithPath: "/tmp/synthetic.mov"), duration: 12, redactions: [redaction])
        for _ in 0..<80 {
            if attemptsByKey.count(for: .init(level: 0, index: 0)) >= 2
                && attemptsByKey.count(for: .init(level: 0, index: 1)) >= 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))

        let grid = store.grid(forTargetSpan: 12.0 / 32.0)
        // Tile 0 recovered on retry with widened tolerance and redactions preserved.
        #expect(store.image(in: grid, tileIndex: 0) != nil)
        let tile0Tolerances = attemptsByKey.tolerances(for: .init(level: 0, index: 0))
        #expect(tile0Tolerances.count == 2)
        #expect(tile0Tolerances[1] > tile0Tolerances[0])
        #expect(attemptsByKey.sawRedactions)

        // Tile 1 attempted initial + 2 retries (3 total) and stopped cleanly.
        #expect(attemptsByKey.count(for: .init(level: 0, index: 1)) == 3)
        store.releaseResources()
    }
}

nonisolated private final class LockedAttemptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [RecordingTimelineThumbnailStore.Key: Int] = [:]
    private var recordedTolerances: [RecordingTimelineThumbnailStore.Key: [TimeInterval]] = [:]
    private var redactionFlag = false

    func record(key: RecordingTimelineThumbnailStore.Key, tolerance: TimeInterval, redactionCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        recordedTolerances[key, default: []].append(tolerance)
        if redactionCount > 0 { redactionFlag = true }
        return next
    }

    func count(for key: RecordingTimelineThumbnailStore.Key) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }

    func tolerances(for key: RecordingTimelineThumbnailStore.Key) -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTolerances[key] ?? []
    }

    var sawRedactions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return redactionFlag
    }
}
