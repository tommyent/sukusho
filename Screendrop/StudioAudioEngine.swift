//
//  StudioAudioEngine.swift
//  Screendrop
//
//  The rules that keep sound and picture together in Studio. Pure values:
//  no players, no files.
//
//  The video is a list of clips, each a range of the recording. Sound comes
//  in two kinds:
//
//  - A clip's own sound: the recording's audio, or a soundtrack imported to
//    stand in for it. Either way it is tied to the recording's clock, so it
//    is cut exactly where the picture is. `RecordingAudioSync` is what ties
//    an imported soundtrack to that clock.
//  - Audio clips on lanes under the video. `StudioAudioConform` carries
//    them through every change to the video's clips.
//

import Foundation

// MARK: - Replacement reference

/// Unresolved persisted reference to an imported soundtrack whose file is
/// missing or unreadable, kept so saving or undoing never drops it.
nonisolated struct StudioReplacementReference: Equatable, Sendable {
    var fileName: String
    var displayName: String?

    var label: String { displayName ?? fileName }

    /// Unresolved persisted reference to an imported soundtrack whose file is
    /// missing or unreadable, kept so saving or undoing never drops it.
    static func resolve(
        fileName: String?,
        displayName: String?,
        sync: RecordingAudioSync?,
        loadedExists: Bool
    ) -> (unresolvedReference: StudioReplacementReference?, sync: RecordingAudioSync?, error: String?) {
        guard let fileName else { return (nil, nil, nil) }
        if loadedExists { return (nil, sync, nil) }
        let ref = StudioReplacementReference(fileName: fileName, displayName: displayName)
        return (ref, sync, "Could not load “\(ref.label)”. Reset to recorded audio or import it again.")
    }
}

// MARK: - Soundtrack sync

/// Where an imported soundtrack lines up with the recording. A soundtrack
/// comes back from a cleanup tool matching the cut it was exported from, so
/// the cut at that moment is recorded here: each span says which stretch of
/// the file is the sound of which stretch of the recording. From then on
/// the soundtrack follows the picture through any later edit.
nonisolated struct RecordingAudioSync: Codable, Equatable, Sendable {
    struct Span: Codable, Equatable, Sendable {
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        /// The file time that plays at `sourceStart`.
        var fileStart: TimeInterval
        /// Recording seconds per file second: the clip's speed when the
        /// soundtrack was made.
        var rate: Double

        var fileEnd: TimeInterval { fileStart + (sourceEnd - sourceStart) / max(rate, 0.01) }
    }

    /// A stretch of the file standing in for a stretch of the recording.
    struct Piece: Equatable, Sendable {
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var fileStart: TimeInterval
        var fileEnd: TimeInterval
    }

    /// Kept in recording order, which `pieces` relies on.
    var spans: [Span] {
        didSet { spans.sort { $0.sourceStart < $1.sourceStart } }
    }
    /// Shifts the soundtrack against the picture, in seconds: positive
    /// plays it later. For files that come back from a cleanup tool with a
    /// little latency added.
    var offset: TimeInterval = 0
    /// Whether stretches left uncovered by the soundtrack fall back to the
    /// recording's own audio. False for legacy v6 projects saved before sync
    /// was tracked, whose shorter replacements ended in silence.
    var fillsGapsWithRecording: Bool = true
    /// How far the soundtrack can be slid either way.
    static let offsetLimit: TimeInterval = 1

    init(spans: [Span], offset: TimeInterval = 0, fillsGapsWithRecording: Bool = true) {
        self.spans = spans.sorted { $0.sourceStart < $1.sourceStart }
        self.offset = offset.isFinite ? min(max(offset, -Self.offsetLimit), Self.offsetLimit) : 0
        self.fillsGapsWithRecording = fillsGapsWithRecording
    }

    private enum CodingKeys: String, CodingKey {
        case spans
        case offset
        case fillsGapsWithRecording
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spans = try container.decode([Span].self, forKey: .spans).sorted { $0.sourceStart < $1.sourceStart }
        let decodedOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .offset) ?? 0
        offset = decodedOffset.isFinite ? min(max(decodedOffset, -Self.offsetLimit), Self.offsetLimit) : 0
        fillsGapsWithRecording = try container.decodeIfPresent(Bool.self, forKey: .fillsGapsWithRecording) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spans, forKey: .spans)
        if offset != 0 { try container.encode(offset, forKey: .offset) }
        if !fillsGapsWithRecording { try container.encode(false, forKey: .fillsGapsWithRecording) }
    }

    /// The soundtrack laid flat over a cut from its first frame, which is
    /// what an export of that cut's audio lines up with. Replacement audio
    /// applies only to primary-recording segments; imported clips keep their
    /// own audio tracks.
    static func flat(over timeline: RecordingClipTimeline) -> RecordingAudioSync {
        var spans: [Span] = []
        var editorStart: TimeInterval = 0
        for segment in timeline.segments {
            if segment.isPrimaryRecording {
                spans.append(Span(
                    sourceStart: segment.sourceStart,
                    sourceEnd: segment.sourceEnd,
                    fileStart: editorStart,
                    rate: max(segment.speed, RecordingClipSegment.minimumSpeed)
                ))
            }
            editorStart += segment.editorDuration
        }
        return RecordingAudioSync(spans: spans)
    }

    /// Legacy v6 flat replacement where any stretch beyond the file stays silent.
    static func legacyFlat(over timeline: RecordingClipTimeline) -> RecordingAudioSync {
        var sync = flat(over: timeline)
        sync.fillsGapsWithRecording = false
        return sync
    }

    /// How long a file has to be to cover every span.
    var coveredFileDuration: TimeInterval {
        spans.map(\.fileEnd).max() ?? 0
    }

    /// The file stretches that cover a range of the recording, in order,
    /// kept inside a file `fileDuration` long. Anything they leave
    /// uncovered has no soundtrack.
    func pieces(
        from sourceStart: TimeInterval,
        to sourceEnd: TimeInterval,
        fileDuration: TimeInterval
    ) -> [Piece] {
        guard sourceEnd > sourceStart else { return [] }
        var pieces: [Piece] = []
        for span in spans {
            let rate = max(span.rate, 0.01)
            // An offset moves the file under the recording: the file time
            // that plays at a moment is `offset` earlier.
            let fileStart = span.fileStart - offset
            var low = max(sourceStart, span.sourceStart, pieces.last?.sourceEnd ?? sourceStart)
            var high = min(sourceEnd, span.sourceEnd)
            // Only where the file has sound: an offset can push its start
            // past the span's, and the file may be shorter than the cut it
            // was made for.
            let firstCovered = span.sourceStart + max(0, -fileStart) * rate
            let lastCovered = span.sourceStart + max(0, fileDuration - fileStart) * rate
            low = max(low, firstCovered)
            high = min(high, lastCovered)
            guard high - low > 0.001 else { continue }
            pieces.append(Piece(
                sourceStart: low,
                sourceEnd: high,
                fileStart: fileStart + (low - span.sourceStart) / rate,
                fileEnd: fileStart + (high - span.sourceStart) / rate
            ))
        }
        return pieces
    }
}

// MARK: - Carrying audio through an edit

nonisolated enum StudioAudioConform {
    private static let epsilon: TimeInterval = 0.000_5

    /// A linked audio slice hidden by trimming its video segment inward or by
    /// a ripple delete, retained so reopening an adjacent trim edge restores
    /// the clip seamlessly.
    struct HiddenLinkedRange: Codable, Equatable, Sendable {
        var segmentID: UUID
        /// Opposite-side surviving segment ID for a ripple gap so the hidden
        /// interval stays alive while either side survives and restores the
        /// portion revealed by either side.
        var secondarySegmentID: UUID? = nil
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var filePerSource: Double
        var clip: RecordingAudioClip

        /// Segment IDs eligible to reveal this hidden interval when reopened.
        var eligibleSegmentIDs: [UUID] {
            if let secondarySegmentID, secondarySegmentID != segmentID {
                return [segmentID, secondarySegmentID]
            }
            return [segmentID]
        }
    }

    /// The audio clips as they should be after the video's clips change
    /// from `old` to `new`.
    ///
    /// A linked clip is treated as part of the picture above it: each
    /// moment of it goes wherever that moment of the recording went, so
    /// video that was removed takes its sound with it and a clip that
    /// changed speed retimes the sound under it. An unlinked clip stays in
    /// one piece and follows the footage moment under its start.
    static func conform(
        _ clips: [RecordingAudioClip],
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingAudioClip] {
        conform(clips, hidden: [], from: old, to: new).clips
    }

    /// Conforms `clips` and updates `hidden` linked ranges across reversible
    /// boundary trims and ripple gaps. Restored audio is computed from saved
    /// hidden intervals first, then edge extension fills only what's left.
    static func conform(
        _ clips: [RecordingAudioClip],
        hidden: [HiddenLinkedRange],
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> (clips: [RecordingAudioClip], hidden: [HiddenLinkedRange]) {
        guard old != new else { return (clips, hidden) }
        let oldSegmentsByID = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newSegmentsByID = Dictionary(new.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func isSameMediaOccurrence(_ lhs: RecordingClipSegment, _ rhs: RecordingClipSegment) -> Bool {
            if lhs.isPrimaryRecording || rhs.isPrimaryRecording {
                return lhs.isPrimaryRecording && rhs.isPrimaryRecording
            }
            return lhs.mediaFileName == rhs.mediaFileName
                && lhs.effectiveOccurrenceID == rhs.effectiveOccurrenceID
        }
        func matchingNewSegments(for oldSeg: RecordingClipSegment) -> [RecordingClipSegment] {
            new.segments.filter { isSameMediaOccurrence($0, oldSeg) }
        }

        // Retain hidden intervals while at least one eligible flanking segment survives.
        var capturedHidden: [HiddenLinkedRange] = hidden.compactMap { entry in
            let surviving = entry.eligibleSegmentIDs.filter { newSegmentsByID[$0] != nil }
            guard let primary = surviving.first else { return nil }
            var updated = entry
            updated.segmentID = primary
            updated.secondarySegmentID = surviving.dropFirst().first
            return updated
        }

        // Capture linked slices hidden by inward trims or ripple gaps on surviving segments.
        for clip in clips where clip.isLinked {
            let clipSpeed = max(clip.speed, 0.01)
            var oldEditorStart: TimeInterval = 0
            for oldSeg in old.segments {
                let oldEditorEnd = oldEditorStart + oldSeg.editorDuration
                defer { oldEditorStart = oldEditorEnd }
                guard let newSeg = newSegmentsByID[oldSeg.id] else { continue }
                let low = max(clip.start, oldEditorStart)
                let high = min(clip.end, oldEditorEnd)
                guard high - low > epsilon else { continue }
                let sourceLow = oldSeg.sourceStart + (low - oldEditorStart) * oldSeg.speed
                let sourceHigh = oldSeg.sourceStart + (high - oldEditorStart) * oldSeg.speed
                let fileLow = clip.trimStart + (low - clip.start) * clipSpeed
                let filePerSource = clipSpeed / oldSeg.speed
                // Source ranges still visible in `new` for this source are not hidden.
                let coveredInNew = RecordingClipTimeline.mergedRanges(
                    matchingNewSegments(for: oldSeg).map { $0.sourceStart...$0.sourceEnd }
                )

                func storeHidden(from rawStart: TimeInterval, to rawEnd: TimeInterval) {
                    guard rawEnd - rawStart > epsilon else { return }
                    var cursor = rawStart
                    var missing: [(TimeInterval, TimeInterval)] = []
                    for covered in coveredInNew where covered.upperBound > rawStart && covered.lowerBound < rawEnd {
                        if covered.lowerBound > cursor + epsilon {
                            missing.append((cursor, min(covered.lowerBound, rawEnd)))
                        }
                        cursor = max(cursor, covered.upperBound)
                    }
                    if rawEnd > cursor + epsilon {
                        missing.append((cursor, rawEnd))
                    }
                    for (s0, s1) in missing {
                        let f0 = fileLow + (s0 - sourceLow) * filePerSource
                        let f1 = min(clip.trimEnd, fileLow + (s1 - sourceLow) * filePerSource)
                        guard f1 - f0 >= RecordingAudioClip.minimumFileSpan else { continue }
                        var template = clip
                        template.originID = clip.lineageID
                        template.trimStart = f0
                        template.trimEnd = f1
                        if abs(f0 - clip.trimStart) > 0.002 {
                            template.fadeIn = 0
                            template.keepsLeadingSplit = false
                        }
                        if abs(f1 - clip.trimEnd) > 0.002 {
                            template.fadeOut = 0
                            template.keepsTrailingSplit = false
                        }
                        // When a ripple delete splits a segment or trims both sides
                        // of a gap, attach the opposite gap-facing segment as well.
                        let secondaryID: UUID?
                        if newSeg.sourceEnd <= s0 + epsilon {
                            secondaryID = new.segments
                                .filter { other in
                                    other.id != newSeg.id
                                        && isSameMediaOccurrence(other, newSeg)
                                        && other.sourceStart >= s1 - epsilon
                                        && (oldSegmentsByID[other.id].map { other.sourceStart > $0.sourceStart + epsilon } ?? true)
                                }
                                .min(by: { $0.sourceStart < $1.sourceStart })?.id
                        } else if newSeg.sourceStart >= s1 - epsilon {
                            secondaryID = new.segments
                                .filter { other in
                                    other.id != newSeg.id
                                        && isSameMediaOccurrence(other, newSeg)
                                        && other.sourceEnd <= s0 + epsilon
                                        && (oldSegmentsByID[other.id].map { other.sourceEnd < $0.sourceEnd - epsilon } ?? true)
                                }
                                .max(by: { $0.sourceEnd < $1.sourceEnd })?.id
                        } else {
                            secondaryID = nil
                        }
                        capturedHidden.append(HiddenLinkedRange(
                            segmentID: oldSeg.id,
                            secondarySegmentID: secondaryID,
                            sourceStart: s0,
                            sourceEnd: s1,
                            filePerSource: filePerSource,
                            clip: template
                        ))
                    }
                }

                if newSeg.sourceStart > sourceLow + epsilon {
                    storeHidden(from: sourceLow, to: min(sourceHigh, newSeg.sourceStart))
                }
                if newSeg.sourceEnd < sourceHigh - epsilon {
                    storeHidden(from: max(sourceLow, newSeg.sourceEnd), to: sourceHigh)
                }
            }
        }

        var result: [RecordingAudioClip] = []
        for clip in clips {
            if clip.isLinked {
                result.append(contentsOf: conformLinked(clip, from: old, to: new))
            } else {
                var moved = clip
                moved.start = max(0, mapPoint(clip.start, from: old, to: new))
                result.append(moved)
            }
        }
        var healedBoundaries: [(lineage: UUID, time: TimeInterval)] = []

        // 1. Restore from saved hidden intervals first (preserving their explicit
        //    split boundaries, mutes, levels, and fades across any eligible side
        //    of a trim or ripple gap).
        var segmentEditorStarts: [UUID: TimeInterval] = [:]
        var cursor: TimeInterval = 0
        for seg in new.segments {
            segmentEditorStarts[seg.id] = cursor
            cursor += seg.editorDuration
        }

        var remainingHidden: [HiddenLinkedRange] = []
        for entry in capturedHidden {
            let ownerAnchor = newSegmentsByID[entry.segmentID] ?? oldSegmentsByID[entry.segmentID]
            let eligible = entry.eligibleSegmentIDs.compactMap { id -> RecordingClipSegment? in
                guard let seg = newSegmentsByID[id] else { return nil }
                if let ownerAnchor, !isSameMediaOccurrence(seg, ownerAnchor) { return nil }
                return seg
            }
            guard !eligible.isEmpty else { continue }

            let revealedSegments: [(seg: RecordingClipSegment, start: TimeInterval, end: TimeInterval)] = eligible
                .compactMap { seg in
                    let low = max(entry.sourceStart, seg.sourceStart)
                    let high = min(entry.sourceEnd, seg.sourceEnd)
                    return high - low > epsilon ? (seg, low, high) : nil
                }
                .sorted { $0.start < $1.start }

            guard !revealedSegments.isEmpty else {
                remainingHidden.append(entry)
                continue
            }

            let lineage = entry.clip.lineageID
            for (newSeg, revealedStart, revealedEnd) in revealedSegments {
                guard let segEditorStart = segmentEditorStarts[newSeg.id] else { continue }
                let speed = max(newSeg.speed, RecordingClipSegment.minimumSpeed)
                let editorStart = segEditorStart + (revealedStart - newSeg.sourceStart) / speed
                let f0 = entry.clip.trimStart + (revealedStart - entry.sourceStart) * entry.filePerSource
                let f1 = min(entry.clip.trimEnd, entry.clip.trimStart + (revealedEnd - entry.sourceStart) * entry.filePerSource)
                let derivedSpeed = min(
                    max(entry.filePerSource * speed, RecordingAudioClip.derivedSpeedRange.lowerBound),
                    RecordingAudioClip.derivedSpeedRange.upperBound
                )
                let editorEnd = editorStart + (f1 - f0) / derivedSpeed

                // Subtract any sub-intervals already covered by surviving pieces
                // of the same original clip lineage so no interval plays twice.
                let coveringPieces = result.enumerated().filter { _, existing in
                    existing.isLinked
                        && existing.lineageID == lineage
                        && existing.end > editorStart + 0.002
                        && existing.start < editorEnd - 0.002
                }
                for (coveredIndex, existing) in coveringPieces {
                    if existing.start <= editorStart + 0.005,
                       abs(f0 - entry.clip.trimStart) <= 0.002,
                       abs(existing.trimStart - entry.clip.trimStart) <= 0.002,
                       entry.clip.fadeIn > 0, existing.fadeIn == 0 {
                        result[coveredIndex].fadeIn = entry.clip.fadeIn
                    }
                    if existing.end >= editorEnd - 0.005,
                       abs(f1 - entry.clip.trimEnd) <= 0.002,
                       abs(existing.trimEnd - entry.clip.trimEnd) <= 0.002,
                       entry.clip.fadeOut > 0, existing.fadeOut == 0 {
                        result[coveredIndex].fadeOut = entry.clip.fadeOut
                    }
                }
                var uncovered: [(TimeInterval, TimeInterval)] = [(editorStart, editorEnd)]
                for (_, existing) in coveringPieces {
                    uncovered = uncovered.flatMap { low, high -> [(TimeInterval, TimeInterval)] in
                        if existing.end <= low + 0.002 || existing.start >= high - 0.002 {
                            return [(low, high)]
                        }
                        var parts: [(TimeInterval, TimeInterval)] = []
                        if existing.start > low + 0.002 { parts.append((low, existing.start)) }
                        if existing.end < high - 0.002 { parts.append((existing.end, high)) }
                        return parts
                    }
                }

                for (subStart, subEnd) in uncovered {
                    let subF0 = f0 + (subStart - editorStart) * derivedSpeed
                    let subF1 = min(f1, f0 + (subEnd - editorStart) * derivedSpeed)
                    guard subF1 - subF0 >= RecordingAudioClip.minimumFileSpan,
                          subEnd - subStart >= RecordingAudioClip.minimumPlayableDuration else { continue }
                    var restored = entry.clip
                    restored.originID = lineage
                    restored.start = subStart
                    restored.trimStart = subF0
                    restored.trimEnd = subF1
                    restored.speed = derivedSpeed
                    if abs(subF0 - entry.clip.trimStart) > 0.002 {
                        restored.fadeIn = 0
                        restored.keepsLeadingSplit = false
                    }
                    if abs(subF1 - entry.clip.trimEnd) > 0.002 {
                        restored.fadeOut = 0
                        restored.keepsTrailingSplit = false
                    }

                    // Seamlessly rejoin an adjacent restored/surviving piece of the same lineage
                    // when neither side carries an explicit split boundary, fade, or level/mute change.
                    if let matchIndex = result.firstIndex(where: { existing in
                        existing.isLinked
                            && existing.lineageID == lineage
                            && existing.lane == restored.lane
                            && existing.isMuted == restored.isMuted
                            && abs(existing.volume - restored.volume) < 0.000_1
                            && !existing.keepsTrailingSplit && !restored.keepsLeadingSplit
                            && existing.fadeOut < 0.001 && restored.fadeIn < 0.001
                            && abs(existing.speed - restored.speed) < 0.000_1
                            && abs(existing.end - restored.start) < 0.002
                            && abs(existing.trimEnd - restored.trimStart) < 0.002
                    }) {
                        result[matchIndex].trimEnd = restored.trimEnd
                        result[matchIndex].fadeOut = restored.fadeOut
                        result[matchIndex].keepsTrailingSplit = restored.keepsTrailingSplit
                        healedBoundaries.append((lineage, restored.end))
                    } else if let matchIndex = result.firstIndex(where: { existing in
                        existing.isLinked
                            && existing.lineageID == lineage
                            && existing.lane == restored.lane
                            && existing.isMuted == restored.isMuted
                            && abs(existing.volume - restored.volume) < 0.000_1
                            && !restored.keepsTrailingSplit && !existing.keepsLeadingSplit
                            && restored.fadeOut < 0.001 && existing.fadeIn < 0.001
                            && abs(existing.speed - restored.speed) < 0.000_1
                            && abs(restored.end - existing.start) < 0.002
                            && abs(restored.trimEnd - existing.trimStart) < 0.002
                    }) {
                        result[matchIndex].start = restored.start
                        result[matchIndex].trimStart = restored.trimStart
                        result[matchIndex].fadeIn = restored.fadeIn
                        result[matchIndex].keepsLeadingSplit = restored.keepsLeadingSplit
                        healedBoundaries.append((lineage, restored.start))
                    } else {
                        if result.contains(where: { $0.id == restored.id }) { restored.id = UUID() }
                        result.append(restored)
                        healedBoundaries.append((lineage, restored.start))
                        healedBoundaries.append((lineage, restored.end))
                    }
                }
            }

            // Retain any sub-ranges of this hidden entry still outside every eligible segment.
            let revealedRanges = RecordingClipTimeline.mergedRanges(
                revealedSegments.map { $0.start...$0.end }
            )
            var remCursor = entry.sourceStart
            var unrevealed: [(TimeInterval, TimeInterval)] = []
            for revealed in revealedRanges {
                if revealed.lowerBound > remCursor + epsilon {
                    unrevealed.append((remCursor, min(revealed.lowerBound, entry.sourceEnd)))
                }
                remCursor = max(remCursor, revealed.upperBound)
            }
            if entry.sourceEnd > remCursor + epsilon {
                unrevealed.append((remCursor, entry.sourceEnd))
            }
            for (remStart, remEnd) in unrevealed {
                let rf0 = entry.clip.trimStart + (remStart - entry.sourceStart) * entry.filePerSource
                let rf1 = min(entry.clip.trimEnd, entry.clip.trimStart + (remEnd - entry.sourceStart) * entry.filePerSource)
                guard rf1 - rf0 >= RecordingAudioClip.minimumFileSpan else { continue }
                var slice = entry
                slice.sourceStart = remStart
                slice.sourceEnd = remEnd
                slice.clip.trimStart = rf0
                slice.clip.trimEnd = rf1
                if remStart > entry.sourceStart + epsilon {
                    slice.clip.fadeIn = 0
                    slice.clip.keepsLeadingSplit = false
                }
                if remEnd < entry.sourceEnd - epsilon {
                    slice.clip.fadeOut = 0
                    slice.clip.keepsTrailingSplit = false
                }
                remainingHidden.append(slice)
            }
        }

        // 2. Edge extension fills only what saved hidden intervals did not already restore.
        result = healingExtensions(result, from: old, to: new, healedBoundaries: &healedBoundaries)

        // 3. Merge adjacent pieces of the same original clip lineage ONLY at
        //    boundaries actively repaired by healing (never across explicit audio splits).
        if !healedBoundaries.isEmpty {
            result = mergingContiguousLineage(result, healedBoundaries: healedBoundaries)
        }
        return (resolvingLanes(result), remainingHidden)
    }

    private static func mergingContiguousLineage(
        _ clips: [RecordingAudioClip],
        healedBoundaries: [(lineage: UUID, time: TimeInterval)]
    ) -> [RecordingAudioClip] {
        let sorted = clips.sorted { ($0.lane, $0.start) < ($1.lane, $1.start) }
        var merged: [RecordingAudioClip] = []
        for clip in sorted {
            if clip.isLinked,
               let index = merged.lastIndex(where: { existing in
                   existing.isLinked
                       && existing.lineageID == clip.lineageID
                       && existing.lane == clip.lane
                       && !existing.keepsTrailingSplit && !clip.keepsLeadingSplit
                       && existing.isMuted == clip.isMuted
                       && existing.fadeOut < 0.001 && clip.fadeIn < 0.001
                       && abs(existing.volume - clip.volume) < 0.000_1
                       && abs(existing.speed - clip.speed) < 0.000_1
                       && abs(existing.end - clip.start) < 0.002
                       && abs(existing.trimEnd - clip.trimStart) < 0.002
                       && healedBoundaries.contains {
                           $0.lineage == clip.lineageID && abs($0.time - clip.start) < 0.005
                       }
               }) {
                merged[index].trimEnd = clip.trimEnd
                merged[index].fadeOut = clip.fadeOut
                merged[index].keepsTrailingSplit = clip.keepsTrailingSplit
            } else {
                merged.append(clip)
            }
        }
        return merged
    }

    /// Opening a clip's trim back up brings back the linked sound under
    /// it, as it brings back the clip's own sound. A linked piece whose
    /// edge sat on the clip's edge grows with it, as far as its file and
    /// its neighbours on the lane allow. Sound that was trimmed on its own
    /// ends somewhere else, so it is left alone.
    private static func healingExtensions(
        _ clips: [RecordingAudioClip],
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline,
        healedBoundaries: inout [(lineage: UUID, time: TimeInterval)]
    ) -> [RecordingAudioClip] {
        let oldSegments = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = clips
        var editorStart: TimeInterval = 0
        for segment in new.segments {
            defer { editorStart += segment.editorDuration }
            guard let before = oldSegments[segment.id] else { continue }
            let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)
            let grewAtEnd = segment.sourceEnd - before.sourceEnd
            let grewAtStart = before.sourceStart - segment.sourceStart
            guard grewAtEnd > 0.001 || grewAtStart > 0.001 else { continue }

            // Where the clip's old edges now sit in the new cut.
            let oldEndHere = editorStart + (before.sourceEnd - segment.sourceStart) / speed
            let oldStartHere = editorStart + (before.sourceStart - segment.sourceStart) / speed

            for index in result.indices where result[index].isLinked {
                var clip = result[index]
                let neighbours = result.enumerated()
                    .filter { $0.offset != index && $0.element.lane == clip.lane }
                    .map(\.element)
                if grewAtEnd > 0.001, !clip.keepsTrailingSplit, abs(clip.end - oldEndHere) < 0.002, clip.trimEnd < clip.fileDuration - 0.001 {
                    let room = neighbours.map(\.start).filter { $0 >= clip.end - 0.002 }.min() ?? .infinity
                    let wanted = grewAtEnd / speed
                    let grow = min(wanted, room - clip.end, (clip.fileDuration - clip.trimEnd) / max(clip.speed, 0.01))
                    if grow > 0.001 {
                        clip.trimEnd += grow * clip.speed
                        healedBoundaries.append((clip.lineageID, clip.end))
                    }
                }
                if grewAtStart > 0.001, !clip.keepsLeadingSplit, abs(clip.start - oldStartHere) < 0.002, clip.trimStart > 0.001 {
                    let room = neighbours.map(\.end).filter { $0 <= clip.start + 0.002 }.max() ?? -.infinity
                    let wanted = grewAtStart / speed
                    let grow = min(wanted, clip.start - max(room, editorStart), clip.trimStart / max(clip.speed, 0.01))
                    if grow > 0.001 {
                        clip.start -= grow
                        clip.trimStart -= grow * clip.speed
                        healedBoundaries.append((clip.lineageID, clip.start))
                    }
                }
                result[index] = clip
            }
        }
        return result
    }

    /// Where a moment of the old cut is in the new one. A moment whose
    /// video was removed lands on the cut that replaced it.
    static func mapPoint(
        _ time: TimeInterval,
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> TimeInterval {
        let oldDuration = old.duration
        guard time < oldDuration - epsilon, let location = old.location(at: time) else {
            return new.duration + max(0, time - oldDuration)
        }
        let oldSeg = old.segments[location.segmentIndex]
        let source = location.sourceTime
        let occurrenceID = oldSeg.isPrimaryRecording ? nil : oldSeg.effectiveOccurrenceID
        if let mapped = editorTime(
            forSourceTime: source,
            mediaFileName: oldSeg.mediaFileName,
            occurrenceID: occurrenceID,
            preferring: location.segmentID,
            in: new
        ) {
            return mapped
        }
        // Removed: the next video from the same occurrence (or same primary source) that survives starts where it was.
        var editorStart: TimeInterval = 0
        var best: (source: TimeInterval, editor: TimeInterval)?
        for segment in new.segments {
            let matchesOccurrence = occurrenceID == nil || segment.effectiveOccurrenceID == occurrenceID
            if segment.mediaFileName == oldSeg.mediaFileName,
               matchesOccurrence,
               segment.sourceStart >= source - epsilon,
               best == nil || segment.sourceStart < best!.source {
                best = (segment.sourceStart, editorStart)
            }
            editorStart += segment.editorDuration
        }
        return best?.editor ?? new.duration
    }

    private static func editorTime(
        forSourceTime source: TimeInterval,
        mediaFileName: String?,
        occurrenceID: UUID?,
        preferring id: UUID,
        in timeline: RecordingClipTimeline
    ) -> TimeInterval? {
        var editorStart: TimeInterval = 0
        var fallback: TimeInterval?
        for segment in timeline.segments {
            let matchesOccurrence = occurrenceID == nil || segment.effectiveOccurrenceID == occurrenceID
            if segment.mediaFileName == mediaFileName,
               matchesOccurrence,
               source >= segment.sourceStart - epsilon,
               source <= segment.sourceEnd + epsilon {
                let offset = min(max(source - segment.sourceStart, 0), segment.duration) / segment.speed
                if segment.id == id { return editorStart + offset }
                if fallback == nil { fallback = editorStart + offset }
            }
            editorStart += segment.editorDuration
        }
        return fallback
    }

    private static func conformLinked(
        _ clip: RecordingAudioClip,
        from old: RecordingClipTimeline,
        to new: RecordingClipTimeline
    ) -> [RecordingAudioClip] {
        let clipSpeed = max(clip.speed, 0.01)
        var pieces: [RecordingAudioClip] = []

        func append(start: TimeInterval, fileStart: TimeInterval, fileEnd: TimeInterval, speed: Double) {
            guard fileEnd - fileStart > epsilon, speed > 0 else { return }
            var piece = clip
            piece.start = start
            piece.trimStart = fileStart
            piece.trimEnd = fileEnd
            piece.speed = speed
            // Joins what a cut didn't actually separate, so a split of the
            // video alone leaves the sound in one piece.
            if var last = pieces.last,
               abs(last.end - piece.start) < 0.002,
               abs(last.trimEnd - piece.trimStart) < 0.002,
               abs(last.speed - piece.speed) < 0.000_1 {
                last.trimEnd = piece.trimEnd
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(piece)
            }
        }

        // Under the video: each stretch follows the clip/source it sat over.
        var oldEditorStart: TimeInterval = 0
        for segment in old.segments {
            let oldEditorEnd = oldEditorStart + segment.editorDuration
            defer { oldEditorStart = oldEditorEnd }
            let low = max(clip.start, oldEditorStart)
            let high = min(clip.end, oldEditorEnd)
            guard high - low > epsilon else { continue }
            let sourceLow = segment.sourceStart + (low - oldEditorStart) * segment.speed
            let sourceHigh = segment.sourceStart + (high - oldEditorStart) * segment.speed
            let fileLow = clip.trimStart + (low - clip.start) * clipSpeed
            // File seconds per source second, which no retiming changes.
            let filePerSource = clipSpeed / segment.speed

            for slice in slices(
                of: new,
                overlapping: sourceLow,
                sourceHigh,
                matching: segment
            ) {
                let fileStart = fileLow + (slice.sourceStart - sourceLow) * filePerSource
                let fileEnd = fileLow + (slice.sourceEnd - sourceLow) * filePerSource
                let derivedSpeed = min(
                    max(filePerSource * slice.speed, RecordingAudioClip.derivedSpeedRange.lowerBound),
                    RecordingAudioClip.derivedSpeedRange.upperBound
                )
                append(
                    start: slice.editorStart,
                    fileStart: fileStart,
                    fileEnd: min(fileEnd, clip.trimEnd),
                    speed: derivedSpeed
                )
            }
        }

        // Past the end of the video: carried along behind it.
        let oldDuration = old.duration
        if clip.end > oldDuration + epsilon {
            let low = max(clip.start, oldDuration)
            append(
                start: new.duration + (low - oldDuration),
                fileStart: clip.trimStart + (low - clip.start) * clipSpeed,
                fileEnd: clip.trimEnd,
                speed: clipSpeed
            )
        }

        pieces = pieces.filter {
            $0.duration >= RecordingAudioClip.minimumPlayableDuration
                && $0.fileSpan >= RecordingAudioClip.minimumFileSpan
        }
        for index in pieces.indices {
            if index > 0 {
                pieces[index].id = UUID()
                pieces[index].originID = clip.lineageID
            }
            // A fade or explicit split flag belongs to the clip's own end, not to a video cut inside it.
            if abs(pieces[index].trimStart - clip.trimStart) > 0.002 {
                pieces[index].fadeIn = 0
                pieces[index].keepsLeadingSplit = false
            }
            if abs(pieces[index].trimEnd - clip.trimEnd) > 0.002 {
                pieces[index].fadeOut = 0
                pieces[index].keepsTrailingSplit = false
            }
        }
        return pieces
    }

    private struct Slice {
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var editorStart: TimeInterval
        var speed: Double
    }

    /// Where a range of `oldSegment`'s source plays in `timeline`, in playing
    /// order. Primary segments match any primary segment; imported segments
    /// match only segments sharing `effectiveOccurrenceID` so splitting one
    /// repeat never duplicates linked audio from another repeat of the same file.
    private static func slices(
        of timeline: RecordingClipTimeline,
        overlapping sourceStart: TimeInterval,
        _ sourceEnd: TimeInterval,
        matching oldSegment: RecordingClipSegment
    ) -> [Slice] {
        var result: [Slice] = []
        var editorStart: TimeInterval = 0
        for segment in timeline.segments {
            let matchesSource: Bool
            if oldSegment.isPrimaryRecording {
                matchesSource = segment.isPrimaryRecording
            } else {
                matchesSource = segment.mediaFileName == oldSegment.mediaFileName
                    && segment.effectiveOccurrenceID == oldSegment.effectiveOccurrenceID
            }
            if matchesSource {
                let low = max(sourceStart, segment.sourceStart)
                let high = min(sourceEnd, segment.sourceEnd)
                if high - low > epsilon {
                    result.append(Slice(
                        sourceStart: low,
                        sourceEnd: high,
                        editorStart: editorStart + (low - segment.sourceStart) / segment.speed,
                        speed: segment.speed
                    ))
                }
            }
            editorStart += segment.editorDuration
        }
        return result
    }

    // MARK: Lanes

    /// The most audio lanes the timeline shows. Past this, overlapping
    /// clips share the last lane (they still all play).
    static let maximumLanes = 8

    /// Clips on one lane never overlap: a clip that lands on another moves
    /// down to the first lane with room. Earlier clips keep their lane.
    /// `first` is placed before the others, so it gets the lane it asks
    /// for; `last` after them, so it is the one that gives way.
    static func resolvingLanes(
        _ clips: [RecordingAudioClip],
        first: UUID? = nil,
        last: UUID? = nil
    ) -> [RecordingAudioClip] {
        var occupied: [Int: [ClosedRange<TimeInterval>]] = [:]
        var result = clips
        func rank(_ clip: RecordingAudioClip) -> Int {
            clip.id == first ? 0 : clip.id == last ? 2 : 1
        }
        let order = clips.indices.sorted {
            let (a, b) = (clips[$0], clips[$1])
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.lane != b.lane { return a.lane < b.lane }
            return a.start < b.start
        }
        for index in order {
            let clip = clips[index]
            guard clip.end - clip.start > epsilon else { continue }
            let preferred = min(max(0, clip.lane), maximumLanes - 1)
            func isFree(_ candidate: Int) -> Bool {
                !(occupied[candidate] ?? []).contains(where: {
                    $0.lowerBound < clip.end - 0.001 && $0.upperBound > clip.start + 0.001
                })
            }
            let lane: Int
            if let downward = (preferred..<maximumLanes).first(where: isFree) {
                lane = downward
            } else if let upward = stride(from: preferred - 1, through: 0, by: -1).first(where: isFree) {
                lane = upward
            } else {
                lane = preferred
            }
            occupied[lane, default: []].append(clip.start...clip.end)
            result[index].lane = lane
        }
        return compactingLanes(result)
    }

    /// Inserts a newly imported audio clip targeting `preferredLane`, keeping it
    /// on that lane when free and giving way via the lane collision policy when
    /// another clip already occupies that time on that lane.
    static func inserting(
        _ clip: RecordingAudioClip,
        into existing: [RecordingAudioClip],
        preferredLane: Int = 0
    ) -> [RecordingAudioClip] {
        var placed = clip
        placed.lane = min(max(0, preferredLane), maximumLanes - 1)
        return resolvingLanes(existing + [placed], last: placed.id)
    }

    /// Closes up lanes nothing sits on, so there is never an empty lane
    /// between two used ones.
    private static func compactingLanes(_ clips: [RecordingAudioClip]) -> [RecordingAudioClip] {
        let used = Set(clips.map(\.lane)).sorted()
        guard used != Array(0..<used.count) else { return clips }
        let remap = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        return clips.map { clip in
            var clip = clip
            clip.lane = remap[clip.lane] ?? clip.lane
            return clip
        }
    }

    // MARK: Splitting

    /// Cuts a clip in two at a moment of the video. Nil when the moment is
    /// outside it or too close to an end.
    static func split(
        _ clip: RecordingAudioClip,
        at time: TimeInterval
    ) -> (leading: RecordingAudioClip, trailing: RecordingAudioClip)? {
        let minimum = RecordingAudioClip.minimumDuration
        guard time - clip.start >= minimum, clip.end - time >= minimum else { return nil }
        let fileTime = clip.trimStart + (time - clip.start) * max(clip.speed, 0.01)
        guard fileTime - clip.trimStart >= RecordingAudioClip.minimumFileSpan,
              clip.trimEnd - fileTime >= RecordingAudioClip.minimumFileSpan else { return nil }
        var leading = clip
        leading.trimEnd = fileTime
        leading.fadeOut = 0
        leading.keepsTrailingSplit = true
        var trailing = clip
        trailing.id = UUID()
        // Keep shared lineage for hidden-range coverage subtraction while
        // marking the split edges so auto-joining never erases the user split.
        trailing.originID = clip.lineageID
        trailing.start = time
        trailing.trimStart = fileTime
        trailing.fadeIn = 0
        trailing.keepsLeadingSplit = true
        return (leading, trailing)
    }

    // MARK: Snapping

    /// The moments worth snapping an audio edit to: the playhead, every
    /// cut of the video, and the ends of the other audio clips.
    static func snapPoints(
        timeline: RecordingClipTimeline,
        clips: [RecordingAudioClip],
        excluding id: UUID?,
        playhead: TimeInterval
    ) -> [TimeInterval] {
        var points = timeline.editPoints
        points.append(playhead)
        for clip in clips where clip.id != id {
            points.append(clip.start)
            points.append(clip.end)
        }
        return points
    }

    /// `time`, or the nearest snap point within `tolerance` of it.
    static func snapped(_ time: TimeInterval, to points: [TimeInterval], tolerance: TimeInterval) -> TimeInterval {
        var best = time
        var distance = tolerance
        for point in points where abs(point - time) <= distance {
            best = point
            distance = abs(point - time)
        }
        return best
    }
}

/// Pure lane-solo monitoring rules, kept separate from each clip's stored
/// `isMuted` flag so duplicating, editing, or saving during solo never
/// promotes a temporary solo silence into a persisted clip mute.
nonisolated enum StudioAudioLaneSolo {
    static func toggle(
        lane targetLane: Int,
        current: Int?
    ) -> (soloLane: Int?, actionName: String) {
        if current == targetLane { return (nil, "Unsolo Lane") }
        return (targetLane, "Solo Lane")
    }

    static func effectiveGain(for clip: RecordingAudioClip, soloLane: Int?) -> Double {
        if let soloLane, clip.lane != soloLane { return 0 }
        return clip.audibleVolume
    }

    static func isEffectivelyMuted(_ clip: RecordingAudioClip, soloLane: Int?) -> Bool {
        clip.isMuted || (soloLane.map { $0 != clip.lane } ?? false)
    }

    /// Ends solo automatically if an edit removes or moves every clip off the
    /// soloed lane. Underlying clip mutes were never altered, so surviving
    /// lanes immediately resume playing at their stored mute states.
    static func reconcile(clips: [RecordingAudioClip], soloLane: Int?) -> Int? {
        guard let soloLane else { return nil }
        return clips.contains(where: { $0.lane == soloLane }) ? soloLane : nil
    }
}
