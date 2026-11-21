import Foundation

/// One transcribed word on the source (unedited) timeline, in seconds.
/// `text` keeps the transcript's original trailing punctuation/spacing so
/// concatenating words reconstructs the transcript exactly.
nonisolated struct RecordingTranscriptWord: Codable, Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    /// Word as shown in the transcript editor, without the glued spacing.
    var displayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var midpoint: TimeInterval {
        (start + end) / 2
    }
}

/// A full transcription: the word-level timing (drives transcript-based
/// video editing) plus the readable cues derived from it (drive the
/// subtitle bar).
nonisolated struct RecordingTranscript: Sendable {
    var words: [RecordingTranscriptWord]
    var cues: [RecordingSubtitleCue]

    /// Keeps source times for the compositor, but never displays wording from a cut.
    func renderCaptions(in timeline: RecordingClipTimeline) -> RecordingTranscript {
        func isKept(_ start: TimeInterval, _ end: TimeInterval) -> Bool {
            guard start.isFinite, end.isFinite, end > start else { return false }
            let kept = timeline.slices(overlapping: start, sourceEnd: end)
                .reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }
            return abs(kept - (end - start)) < 0.000_001
        }

        var result = RecordingTranscript(words: [], cues: [])
        for var cue in cues where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start {
            let timed = words.filter { $0.start >= cue.start && $0.start < cue.end }
                .sorted { $0.start < $1.start }
            if isKept(cue.start, cue.end) {
                result.cues.append(cue)
                result.words += timed.filter { isKept($0.start, $0.end) }
                continue
            }
            let corrected = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            // A changed word count or invalid timing cannot safely locate corrected wording.
            guard !timed.isEmpty, timed.count == corrected.count,
                  timed.allSatisfy({ $0.end.isFinite && $0.end > $0.start && $0.end <= cue.end })
            else { continue }
            let surviving = zip(timed, corrected).filter { isKept($0.0.start, $0.0.end) }
            guard !surviving.isEmpty else { continue }
            cue.text = surviving.map { $0.1 }.joined(separator: " ")
            result.cues.append(cue)
            result.words += surviving.map { $0.0 }
        }
        return result
    }

    /// Maps cues and timed words onto editor-time touching runs in playback
    /// order for shared transcripts. A cue split across reordered clips emits
    /// separate runs rather than spanning unrelated footage in between, and
    /// rebuilds text from the timed words retained in each run.
    func sharedEntries(
        in timeline: RecordingClipTimeline
    ) -> (cues: [(start: Double, end: Double, text: String)], words: [(text: String, start: Double, end: Double)]) {
        func sliceCoverage(of start: TimeInterval, to end: TimeInterval, in slices: [RecordingClipTimeline.Slice]) -> TimeInterval {
            slices.reduce(0) { total, slice in
                let lo = max(start, slice.sourceStart)
                let hi = min(end, slice.sourceEnd)
                return total + max(0, hi - lo)
            }
        }

        var mappedCues: [(start: Double, end: Double, text: String)] = []
        for cue in cues where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start {
            let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let runs = timeline.editorRuns(overlapping: cue.start, sourceEnd: cue.end)
            guard !runs.isEmpty else { continue }

            let timed = words
                .filter { $0.start >= cue.start && $0.start < cue.end && $0.end.isFinite && $0.end > $0.start }
                .sorted { $0.start < $1.start }
            let corrected = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            let cueLength = cue.end - cue.start

            for run in runs where run.editorEnd > run.editorStart {
                let runCovered = sliceCoverage(of: cue.start, to: cue.end, in: run.slices)
                if abs(runCovered - cueLength) < 0.001 {
                    mappedCues.append((run.editorStart, run.editorEnd, trimmed))
                    continue
                }
                // Match export's rule: never substitute raw automatic words for a
                // corrected cue whose word count or timings no longer align.
                guard !timed.isEmpty,
                      timed.count == corrected.count,
                      timed.allSatisfy({ $0.end <= cue.end + 0.001 }) else {
                    continue
                }
                let surviving = zip(timed, corrected)
                    .compactMap { pair -> (editorStart: TimeInterval, text: String)? in
                        let covered = sliceCoverage(of: pair.0.start, to: pair.0.end, in: run.slices)
                        guard abs(covered - (pair.0.end - pair.0.start)) < 0.001,
                              let wordEditorStart = timeline.editorTime(forSourceEventTime: pair.0.start) else {
                            return nil
                        }
                        return (wordEditorStart, pair.1)
                    }
                    .sorted { $0.editorStart < $1.editorStart }
                let rebuilt = surviving.map(\.text).joined(separator: " ")
                if !rebuilt.isEmpty {
                    mappedCues.append((run.editorStart, run.editorEnd, rebuilt))
                }
            }
        }

        mappedCues.sort { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.000_001 { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }

        var mappedWords: [(text: String, start: Double, end: Double)] = []
        for word in words where word.start.isFinite && word.end.isFinite && word.end > word.start {
            for run in timeline.editorRuns(overlapping: word.start, sourceEnd: word.end)
            where run.editorEnd > run.editorStart {
                mappedWords.append((word.text, run.editorStart, run.editorEnd))
            }
        }
        mappedWords.sort { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.000_001 { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }

        return (mappedCues, mappedWords)
    }
}

/// One subtitle on the source (unedited) timeline, in seconds.
nonisolated struct RecordingSubtitleCue: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case text
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Cues saved before editing shipped carry no identity; mint one so
        // the editor's list rows stay stable for this session.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
    }
}
