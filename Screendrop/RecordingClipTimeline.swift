//
//  RecordingClipTimeline.swift
//  Screendrop
//
//  Non-destructive edit map for the recording Studio. The source movie is
//  never modified: each clip keeps a range on the original recording, while
//  the editor/export timeline is the concatenation of the surviving ranges.
//

import Foundation

nonisolated struct RecordingClipSegment: Identifiable, Codable, Equatable, Sendable {
    static let minimumDuration: TimeInterval = 0.12
    static let minimumSpeed: Double = 1
    static let maximumSpeed: Double = 8

    /// Rounding-scale tolerance so clamping an edge to `end - minimumDuration`
    /// (e.g. `10 - (10 - 0.12) == 0.11999999999999922`) survives normalization,
    /// while meaningfully short survivors still reject.
    static let minimumDurationRoundingTolerance: TimeInterval = 1e-6

    /// Shared minimum-duration predicate used by both normalization and range
    /// deletion so any survivor accepted by an edit survives commit.
    static func isPlayableDuration(_ duration: TimeInterval) -> Bool {
        duration.isFinite && duration >= minimumDuration - minimumDurationRoundingTolerance
    }

    var id: UUID
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    /// Playback speed multiplier applied only to this clip (1...8). Baked
    /// into the composition via `AVMutableComposition.scaleTimeRange`, so
    /// video and audio speed up together and stay in sync.
    var speed: Double

    init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        speed: Double = 1
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
    }

    /// This clip over another source range, keeping its speed and any other
    /// per-clip attributes.
    func covering(_ start: TimeInterval, _ end: TimeInterval, id: UUID? = nil) -> RecordingClipSegment {
        var copy = self
        copy.id = id ?? self.id
        copy.sourceStart = start
        copy.sourceEnd = end
        return copy
    }

    /// Raw duration of the source range this clip covers.
    var duration: TimeInterval {
        max(0, sourceEnd - sourceStart)
    }

    /// How long this clip occupies on the edited/output timeline once its
    /// speed is applied.
    var editorDuration: TimeInterval {
        duration / max(speed, Self.minimumSpeed)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceStart
        case sourceEnd
        case speed
    }

    /// Accepted for migration from the first experimental split schema.
    private enum LegacyCodingKeys: String, CodingKey {
        case start
        case end
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceStart = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStart)
            ?? legacy.decode(TimeInterval.self, forKey: .start)
        sourceEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceEnd)
            ?? legacy.decode(TimeInterval.self, forKey: .end)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
    }
}

nonisolated struct RecordingClipTimeline: Codable, Equatable, Sendable {
    struct Location: Equatable, Sendable {
        var segmentIndex: Int
        var segmentID: UUID
        var editorStart: TimeInterval
        var offset: TimeInterval
        var sourceTime: TimeInterval
    }

    struct Slice: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            var segmentID: UUID
            var sourceStart: TimeInterval
            var sourceEnd: TimeInterval
        }

        var segmentID: UUID
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var editorStart: TimeInterval
        var editorEnd: TimeInterval

        var id: ID {
            ID(
                segmentID: segmentID,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            )
        }
    }

    var segments: [RecordingClipSegment]

    init(segments: [RecordingClipSegment]) {
        self.segments = segments
    }

    static func full(sourceDuration: TimeInterval) -> RecordingClipTimeline {
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        guard safeDuration > 0 else { return RecordingClipTimeline(segments: []) }
        return RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: safeDuration)
        ])
    }

    static func legacyTrim(
        start: TimeInterval?,
        end: TimeInterval?,
        sourceDuration: TimeInterval
    ) -> RecordingClipTimeline {
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        let safeStart = min(max(start ?? 0, 0), safeDuration)
        let safeEnd = min(max(end ?? safeDuration, safeStart), safeDuration)
        guard safeEnd - safeStart >= RecordingClipSegment.minimumDuration else {
            return full(sourceDuration: safeDuration)
        }
        return RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: safeStart, sourceEnd: safeEnd)
        ])
    }

    /// Total length of the edited/output timeline, honoring per-clip speed.
    var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.editorDuration }
    }

    /// Shared minimum rendered editor duration enforced across ripple delete,
    /// interactive commits, playback, and export so no committed cut can be
    /// rejected when played or exported.
    static let minimumPlayableEditorDuration: TimeInterval = RecordingClipSegment.minimumDuration

    var hasPlayableEditorDuration: Bool {
        duration.isFinite
            && duration >= Self.minimumPlayableEditorDuration - RecordingClipSegment.minimumDurationRoundingTolerance
    }

    func normalized(
        to sourceDuration: TimeInterval,
        fallbackToFull: Bool = true
    ) -> RecordingClipTimeline {
        let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
        var seenIDs = Set<UUID>()
        var normalized = segments.compactMap { segment -> RecordingClipSegment? in
            let start = min(max(segment.sourceStart, 0), safeDuration)
            let end = min(max(segment.sourceEnd, start), safeDuration)
            guard RecordingClipSegment.isPlayableDuration(end - start) else { return nil }
            let id = seenIDs.insert(segment.id).inserted ? segment.id : UUID()
            let speed = min(
                max(segment.speed.isFinite ? segment.speed : 1, RecordingClipSegment.minimumSpeed),
                RecordingClipSegment.maximumSpeed
            )
            var clip = segment.covering(start, end, id: id)
            clip.speed = speed
            return clip
        }

        // Clips can play in any order, but no moment of the recording plays
        // twice: subtract the union of earlier coverage and emit every
        // playable surviving piece in place, keeping the clip's identity on
        // the first survivor and minting fresh IDs for split-off pieces.
        var taken: [ClosedRange<TimeInterval>] = []
        var deduplicated: [RecordingClipSegment] = []
        for segment in normalized {
            var pieces: [(start: TimeInterval, end: TimeInterval)] = []
            var cursor = segment.sourceStart
            for range in taken where range.upperBound > segment.sourceStart && range.lowerBound < segment.sourceEnd {
                if range.lowerBound > cursor {
                    pieces.append((cursor, min(range.lowerBound, segment.sourceEnd)))
                }
                cursor = max(cursor, range.upperBound)
            }
            if cursor < segment.sourceEnd {
                pieces.append((cursor, segment.sourceEnd))
            }
            var keptID = false
            for piece in pieces where RecordingClipSegment.isPlayableDuration(piece.end - piece.start) {
                deduplicated.append(segment.covering(
                    piece.start,
                    piece.end,
                    id: keptID ? UUID() : segment.id
                ))
                keptID = true
                taken.append(piece.start...piece.end)
            }
            taken = Self.mergedRanges(taken)
        }
        normalized = deduplicated

        if normalized.isEmpty, fallbackToFull, safeDuration > 0 {
            return .full(sourceDuration: safeDuration)
        }
        return RecordingClipTimeline(segments: normalized)
    }

    /// Normalizes a proposed interactive edit without falling back to the full
    /// recording; returns nil when no playable clips would survive commit or
    /// the resulting cut is shorter than playback/export's minimum editor length.
    func validatedForCommit(sourceDuration: TimeInterval) -> RecordingClipTimeline? {
        let committed = normalized(to: sourceDuration, fallbackToFull: false)
        guard !committed.segments.isEmpty, committed.hasPlayableEditorDuration else { return nil }
        return committed
    }

    /// Applies a clip trim and validates commit survival, ensuring a trim can
    /// never silently drop the clip being trimmed.
    func replacingAndValidating(
        _ replacement: RecordingClipSegment,
        sourceDuration: TimeInterval
    ) -> RecordingClipTimeline? {
        guard let committed = replacing(replacement).validatedForCommit(sourceDuration: sourceDuration),
              committed.segments.contains(where: { $0.id == replacement.id }) else {
            return nil
        }
        return committed
    }

    func location(at editorTime: TimeInterval) -> Location? {
        guard !segments.isEmpty, duration > 0 else { return nil }
        let clamped = min(max(editorTime, 0), duration)
        var editorStart: TimeInterval = 0

        for (index, segment) in segments.enumerated() {
            let editorEnd = editorStart + segment.editorDuration
            if clamped < editorEnd || index == segments.index(before: segments.endIndex) {
                // `offset` is in editor-space; a sped-up segment covers more
                // source seconds per editor second, so the source offset
                // scales up by the clip's speed.
                let offset = min(max(clamped - editorStart, 0), segment.editorDuration)
                let sourceOffset = min(offset * segment.speed, segment.duration)
                return Location(
                    segmentIndex: index,
                    segmentID: segment.id,
                    editorStart: editorStart,
                    offset: offset,
                    sourceTime: segment.sourceStart + sourceOffset
                )
            }
            editorStart = editorEnd
        }
        return nil
    }

    func sourceTime(at editorTime: TimeInterval) -> TimeInterval {
        location(at: editorTime)?.sourceTime ?? 0
    }

    /// Half-open source-event lookup (`[sourceStart, sourceEnd)`), so an event
    /// at a reordered join maps to the clip where that source moment actually
    /// begins playing rather than the trailing edge of an earlier clip. When
    /// `includeTimelineEnd` is true, an exact hit on the final clip's end maps
    /// to `duration` if no other clip starts at that source moment.
    func editorTime(
        forSourceEventTime sourceTime: TimeInterval,
        includeTimelineEnd: Bool = false
    ) -> TimeInterval? {
        guard sourceTime.isFinite else { return nil }
        var editorStart: TimeInterval = 0
        for segment in segments {
            if sourceTime >= segment.sourceStart,
               sourceTime < segment.sourceEnd {
                return editorStart + (sourceTime - segment.sourceStart) / segment.speed
            }
            editorStart += segment.editorDuration
        }
        if includeTimelineEnd,
           let last = segments.last,
           abs(sourceTime - last.sourceEnd) <= 0.000_001 {
            return duration
        }
        return nil
    }

    func editorTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
        if let exact = editorTime(forSourceEventTime: sourceTime) {
            return exact
        }
        var editorStart: TimeInterval = 0
        for segment in segments {
            if sourceTime >= segment.sourceStart - 0.000_001,
               sourceTime <= segment.sourceEnd + 0.000_001 {
                let sourceOffset = min(max(sourceTime - segment.sourceStart, 0), segment.duration)
                return editorStart + sourceOffset / segment.speed
            }
            editorStart += segment.editorDuration
        }
        return nil
    }

    func editorRange(for segmentID: UUID) -> Range<TimeInterval>? {
        var editorStart: TimeInterval = 0
        for segment in segments {
            let editorEnd = editorStart + segment.editorDuration
            if segment.id == segmentID {
                return editorStart..<editorEnd
            }
            editorStart = editorEnd
        }
        return nil
    }

    func split(at editorTime: TimeInterval) -> (timeline: RecordingClipTimeline, selectedID: UUID)? {
        guard let location = location(at: editorTime) else { return nil }
        let segment = segments[location.segmentIndex]
        let sourceTime = location.sourceTime
        guard sourceTime - segment.sourceStart >= RecordingClipSegment.minimumDuration,
              segment.sourceEnd - sourceTime >= RecordingClipSegment.minimumDuration else {
            return nil
        }

        let trailingID = UUID()
        let leading = segment.covering(segment.sourceStart, sourceTime)
        let trailing = segment.covering(sourceTime, segment.sourceEnd, id: trailingID)
        var next = segments
        next.replaceSubrange(location.segmentIndex...location.segmentIndex, with: [leading, trailing])
        return (RecordingClipTimeline(segments: next), trailingID)
    }

    func deleting(segmentID: UUID) -> RecordingClipTimeline? {
        guard segments.count > 1, segments.contains(where: { $0.id == segmentID }) else {
            return nil
        }
        let next = segments.filter { $0.id != segmentID }
        guard next.reduce(0, { $0 + $1.duration }) >= RecordingClipSegment.minimumDuration else {
            return nil
        }
        return RecordingClipTimeline(segments: next)
    }

    func replacing(_ replacement: RecordingClipSegment) -> RecordingClipTimeline {
        guard let index = segments.firstIndex(where: { $0.id == replacement.id }) else {
            return self
        }
        var next = segments
        next[index] = replacement
        return RecordingClipTimeline(segments: next)
    }

    /// Cuts source-time ranges out of the timeline, splitting segments where
    /// a range lands inside one. Ranges may overlap segments partially, span
    /// several, or fall entirely in already-cut gaps (a no-op). Returns nil
    /// when nothing playable would survive.
    func removingSourceRanges(_ ranges: [ClosedRange<TimeInterval>]) -> RecordingClipTimeline? {
        let cuts = Self.mergedRanges(ranges)
        guard !cuts.isEmpty else { return self }

        var next: [RecordingClipSegment] = []
        for segment in segments {
            // Subtract every cut from this segment, keeping the surviving
            // sub-ranges in order. The leading survivor keeps the segment's
            // identity so selection and undo stay anchored.
            var pieces: [(start: TimeInterval, end: TimeInterval)] = []
            var cursor = segment.sourceStart
            for cut in cuts where cut.upperBound > segment.sourceStart && cut.lowerBound < segment.sourceEnd {
                if cut.lowerBound > cursor {
                    pieces.append((cursor, min(cut.lowerBound, segment.sourceEnd)))
                }
                cursor = max(cursor, cut.upperBound)
            }
            if cursor < segment.sourceEnd {
                pieces.append((cursor, segment.sourceEnd))
            }

            var keptSegmentID = false
            for piece in pieces where piece.end - piece.start >= RecordingClipSegment.minimumDuration {
                next.append(segment.covering(
                    piece.start,
                    piece.end,
                    id: keptSegmentID ? UUID() : segment.id
                ))
                keptSegmentID = true
            }
        }

        guard !next.isEmpty else { return nil }
        return RecordingClipTimeline(segments: next)
    }

    /// Overlapping/touching ranges collapsed into disjoint sorted ranges;
    /// empty and non-finite ranges are dropped.
    static func mergedRanges(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges
            .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func slices(overlapping sourceStart: TimeInterval, sourceEnd: TimeInterval) -> [Slice] {
        guard sourceEnd > sourceStart else { return [] }
        var result: [Slice] = []
        var editorOffset: TimeInterval = 0

        for segment in segments {
            let overlapStart = max(sourceStart, segment.sourceStart)
            let overlapEnd = min(sourceEnd, segment.sourceEnd)
            if overlapEnd > overlapStart {
                let editorStart = editorOffset + (overlapStart - segment.sourceStart) / segment.speed
                let editorEnd = editorOffset + (overlapEnd - segment.sourceStart) / segment.speed
                result.append(Slice(
                    segmentID: segment.id,
                    sourceStart: overlapStart,
                    sourceEnd: overlapEnd,
                    editorStart: editorStart,
                    editorEnd: editorEnd
                ))
            }
            editorOffset += segment.editorDuration
        }
        return result
    }

    /// One contiguous editor-time run where part of a source interval plays
    /// without interruption across clips.
    struct EditorRun: Equatable, Sendable {
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
        let slices: [Slice]

        var editorDuration: TimeInterval { editorEnd - editorStart }
    }

    /// Every touching monotonic editor-time run where `sourceStart..<sourceEnd`
    /// survives, in playback (editor) order. Runs break at backward joins so a
    /// cue or block spanning reversed adjacent clips never merges across a jump
    /// backward in source time.
    func editorRuns(overlapping sourceStart: TimeInterval, sourceEnd: TimeInterval) -> [EditorRun] {
        var runs: [EditorRun] = []
        for slice in slices(overlapping: sourceStart, sourceEnd: sourceEnd) {
            if let last = runs.last,
               let lastSlice = last.slices.last,
               abs(last.editorEnd - slice.editorStart) < 0.000_5,
               lastSlice.sourceEnd <= slice.sourceStart + 0.000_5 {
                runs[runs.count - 1] = EditorRun(
                    editorStart: last.editorStart,
                    editorEnd: slice.editorEnd,
                    slices: last.slices + [slice]
                )
            } else {
                runs.append(EditorRun(
                    editorStart: slice.editorStart,
                    editorEnd: slice.editorEnd,
                    slices: [slice]
                ))
            }
        }
        return runs
    }

    /// Where a stretch of the recording shows as one block on the edited
    /// timeline. In recording order its pieces always touch (a cut removes
    /// the time between them), so this is first to last. Once clips are
    /// reordered they may not, and the longest run that touches stands for it.
    func editorSpan(overlapping sourceStart: TimeInterval, sourceEnd: TimeInterval) -> Range<TimeInterval>? {
        editorRuns(overlapping: sourceStart, sourceEnd: sourceEnd)
            .max(by: { $0.editorDuration < $1.editorDuration })
            .map { $0.editorStart..<$0.editorEnd }
    }

    func isUnedited(sourceDuration: TimeInterval) -> Bool {
        guard segments.count == 1, let only = segments.first else { return false }
        return abs(only.sourceStart) < 0.000_001
            && abs(only.sourceEnd - sourceDuration) < 0.000_001
            && abs(only.speed - 1) < 0.000_001
    }

    /// Every cut on the edited timeline: where each clip starts, and the end.
    var editPoints: [TimeInterval] {
        var points: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for segment in segments {
            points.append(cursor)
            cursor += segment.editorDuration
        }
        points.append(cursor)
        return points
    }

    /// Outcome of ripple-deleting an editor-time range.
    enum EditorRangeRemoval: Equatable, Sendable {
        case removed(RecordingClipTimeline)
        case emptyRange
        case removesEntireVideo
        case leavesShortClip
    }

    /// Validates and removes a stretch of the edited video, closing up
    /// everything after it. Rejects empty ranges, cuts that leave no video,
    /// and cuts that would silently swallow an unmarked piece shorter than
    /// `RecordingClipSegment.minimumDuration`.
    func removeEditorRange(_ range: ClosedRange<TimeInterval>) -> EditorRangeRemoval {
        let tolerance = 0.000_5
        guard range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.upperBound - range.lowerBound > tolerance else {
            return .emptyRange
        }
        var next: [RecordingClipSegment] = []
        var editorStart: TimeInterval = 0
        for segment in segments {
            let editorEnd = editorStart + segment.editorDuration
            defer { editorStart = editorEnd }
            let cutLow = max(range.lowerBound, editorStart)
            let cutHigh = min(range.upperBound, editorEnd)
            guard cutHigh - cutLow > tolerance else {
                next.append(segment)
                continue
            }
            func source(_ editor: TimeInterval) -> TimeInterval {
                min(segment.sourceStart + (editor - editorStart) * segment.speed, segment.sourceEnd)
            }
            var keptID = false
            if cutLow - editorStart > tolerance {
                let leadingEnd = source(cutLow)
                guard RecordingClipSegment.isPlayableDuration(leadingEnd - segment.sourceStart) else {
                    return .leavesShortClip
                }
                next.append(segment.covering(segment.sourceStart, leadingEnd))
                keptID = true
            }
            if editorEnd - cutHigh > tolerance {
                let trailingStart = source(cutHigh)
                guard RecordingClipSegment.isPlayableDuration(segment.sourceEnd - trailingStart) else {
                    return .leavesShortClip
                }
                next.append(segment.covering(
                    trailingStart,
                    segment.sourceEnd,
                    id: keptID ? UUID() : segment.id
                ))
            }
        }
        guard !next.isEmpty else { return .removesEntireVideo }
        let candidate = RecordingClipTimeline(segments: next)
        guard candidate.hasPlayableEditorDuration else { return .leavesShortClip }
        return .removed(candidate)
    }

    /// The cut with a stretch of the edited video taken out, everything
    /// after closing up. Nil when the range is empty, removes the whole video,
    /// or would leave a clip shorter than `RecordingClipSegment.minimumDuration`.
    func removingEditorRange(_ range: ClosedRange<TimeInterval>) -> RecordingClipTimeline? {
        guard case .removed(let next) = removeEditorRange(range) else { return nil }
        return next
    }

    /// Editor times of cuts that jump back in the recording, where clips have
    /// been put in a new order. Motion (zoom, the pointer) lands on these
    /// instead of easing across from another moment. Ordinary forward cuts
    /// keep their easing.
    var hardCuts: [TimeInterval] {
        var cuts: [TimeInterval] = []
        var editorStart: TimeInterval = 0
        var previous: RecordingClipSegment?
        for segment in segments {
            if let previous, segment.sourceStart < previous.sourceEnd - 0.000_5 {
                cuts.append(editorStart)
            }
            editorStart += segment.editorDuration
            previous = segment
        }
        return cuts
    }

    /// Whether the clips play in recording order.
    var isInRecordingOrder: Bool { hardCuts.isEmpty }

    /// The cut with one clip moved to a new position in the list.
    func moving(segmentID: UUID, to destination: Int) -> RecordingClipTimeline? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return nil }
        let target = min(max(destination, 0), segments.count - 1)
        guard target != index else { return nil }
        var next = segments
        let segment = next.remove(at: index)
        next.insert(segment, at: target)
        return RecordingClipTimeline(segments: next)
    }

    /// The clip playing at an editor time.
    func segment(at editorTime: TimeInterval) -> RecordingClipSegment? {
        location(at: editorTime).map { segments[$0.segmentIndex] }
    }
}

nonisolated extension RecordingClipSegment {
    /// "1.5×", "2×": trailing zeros dropped.
    static func speedTitle(_ speed: Double) -> String {
        let safe = speed.isFinite ? speed : 1
        let rounded = (safe * 100).rounded() / 100
        let text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%g", rounded)
        return "\(text)×"
    }
}
