import Foundation

/// Chapter anchors stay on their source clip (primary recording when
/// `mediaFileName == nil`, or an imported sequence clip) so cuts and speed
/// changes are reversible.
nonisolated struct RecordingChapter: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var start: TimeInterval
    var autoTitle: Bool? = nil
    var mediaFileName: String? = nil
    var clipOccurrenceID: UUID? = nil

    init(
        id: UUID = UUID(),
        title: String,
        start: TimeInterval,
        autoTitle: Bool? = nil,
        mediaFileName: String? = nil,
        clipOccurrenceID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.autoTitle = autoTitle
        self.mediaFileName = mediaFileName
        self.clipOccurrenceID = clipOccurrenceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, start, autoTitle, mediaFileName, clipOccurrenceID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        start = try container.decode(TimeInterval.self, forKey: .start)
        autoTitle = try container.decodeIfPresent(Bool.self, forKey: .autoTitle)
        mediaFileName = try container.decodeIfPresent(String.self, forKey: .mediaFileName)
        clipOccurrenceID = try container.decodeIfPresent(UUID.self, forKey: .clipOccurrenceID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(start, forKey: .start)
        if let autoTitle { try container.encode(autoTitle, forKey: .autoTitle) }
        if let mediaFileName { try container.encode(mediaFileName, forKey: .mediaFileName) }
        if let clipOccurrenceID { try container.encode(clipOccurrenceID, forKey: .clipOccurrenceID) }
    }
}

nonisolated enum RecordingChapterPlanner {
    /// Chapters here are the sorted, visible chapters in edited timeline time.
    static func current(_ chapters: [RecordingChapter], at time: TimeInterval, duration: TimeInterval) -> RecordingChapter? {
        guard time.isFinite, duration.isFinite, time >= 0, time <= duration else { return nil }
        return chapters.last { $0.start <= time }
    }

    static func clampedStart(id: UUID, proposed: TimeInterval, chapters: [RecordingChapter], duration: TimeInterval) -> TimeInterval? {
        guard proposed.isFinite, duration.isFinite, duration > 0,
              let index = chapters.firstIndex(where: { $0.id == id }) else { return nil }
        // Stay above the mapper's 1 ms deduplication even after the fastest supported speed change.
        let gap = 0.002 * RecordingClipSegment.maximumSpeed
        let lower = index > 0 ? chapters[index - 1].start + gap : 0
        let upper = min(duration - 0.5 - gap,
                        index + 1 < chapters.count ? chapters[index + 1].start - gap : duration)
        guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        return min(max(proposed, lower), upper)
    }

    static func title(from text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sentence = clean.prefix { !".!?。！？".contains($0) }
        return String(sentence.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func openingSentenceTitle(cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord], through timeline: RecordingClipTimeline) -> String {
        title(from: survivingCues(cues, words: words, through: timeline).map(\.text).joined(separator: " "))
    }

    static func mapped(_ chapters: [RecordingChapter], through timeline: RecordingClipTimeline, cues: [RecordingSubtitleCue] = [], words: [RecordingTranscriptWord] = []) -> [RecordingChapter] {
        let candidates: [(chapter: RecordingChapter, time: TimeInterval)] = chapters
            .filter { $0.start.isFinite && $0.start >= 0 }
            .compactMap { chapter in
                guard let time = timeline.editorTime(
                    forSourceEventTime: chapter.start,
                    mediaFileName: chapter.mediaFileName,
                    occurrenceID: chapter.clipOccurrenceID
                ),
                      time < timeline.duration - 0.5 else { return nil }
                return (chapter, time)
            }
            .sorted { lhs, rhs in
                if abs(lhs.time - rhs.time) > 0.000_001 { return lhs.time < rhs.time }
                return lhs.chapter.start < rhs.chapter.start
            }
        var result: [RecordingChapter] = []
        for (chapter, time) in candidates {
            guard result.last.map({ time - $0.start > 0.001 }) ?? true else { continue }
            var mapped = chapter
            mapped.start = time
            mapped.title = String(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            result.append(mapped)
        }
        if result.contains(where: { $0.autoTitle == true }) {
            let readable = survivingCues(cues, words: words, through: timeline)
            for index in result.indices where result[index].autoTitle == true {
                let end = index + 1 < result.count ? result[index + 1].start : timeline.duration
                let text = chapterText(readable, through: timeline, start: result[index].start, end: end)
                let title = title(from: text)
                result[index].title = title.isEmpty ? "Chapter \(index + 1)" : title
            }
        }
        return result
    }

    /// Name Chapters: the model's titles replace the opening sentences, and
    /// stay through later cuts as a typed title does.
    static func named(_ chapters: [RecordingChapter], titles: [UUID: String]) -> [RecordingChapter] {
        chapters.map { chapter in
            guard let title = titles[chapter.id] else { return chapter }
            var named = chapter
            named.title = String(title.prefix(200))
            named.autoTitle = false
            return named
        }
    }

    static func chapterText(_ cues: [RecordingSubtitleCue], through timeline: RecordingClipTimeline, start: TimeInterval, end: TimeInterval) -> String {
        cues.compactMap { cue -> (editorStart: TimeInterval, text: String)? in
            let intersecting = timeline.slices(overlapping: cue.start, sourceEnd: cue.end)
                .filter { $0.editorEnd > start + 0.000_001 && $0.editorStart < end - 0.000_001 }
            guard let first = intersecting.first else { return nil }
            return (first.editorStart, cue.text)
        }
        .sorted { $0.editorStart < $1.editorStart }
        .map(\.text)
        .joined(separator: " ")
    }

    static func shareData(_ chapters: [RecordingChapter], through timeline: RecordingClipTimeline, cues: [RecordingSubtitleCue] = [], words: [RecordingTranscriptWord] = []) throws -> Data {
        struct WireChapter: Encodable {
            var title: String
            var start: TimeInterval
        }
        var mapped = mapped(chapters, through: timeline, cues: cues, words: words)
        if !mapped.isEmpty { mapped[0].start = 0 }
        return try JSONEncoder().encode(mapped.map {
            WireChapter(title: $0.title.isEmpty ? "Chapter" : $0.title, start: $0.start)
        })
    }

    static func survivingCues(_ cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord], through timeline: RecordingClipTimeline) -> [RecordingSubtitleCue] {
        cues.compactMap { cue -> (editorStart: TimeInterval, cue: RecordingSubtitleCue)? in
            let slices = timeline.slices(overlapping: cue.start, sourceEnd: cue.end)
            guard let first = slices.first, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let cueWords = words.filter { $0.midpoint >= cue.start && $0.midpoint < cue.end }
            let survivingWords = cueWords.filter { word in
                timeline.slices(overlapping: word.start, sourceEnd: word.end)
                    .reduce(0) { $0 + $1.sourceEnd - $1.sourceStart } >= word.end - word.start - 0.001
            }
            let covered = slices.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }
            if covered < cue.end - cue.start - 0.001 {
                // shortcut: partially cut corrected prose has no new word timings; omit it unless it matches surviving words.
                guard !cueWords.isEmpty, !survivingWords.isEmpty,
                      survivingWords.count == cueWords.count || cue.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        == survivingWords.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ") else { return nil }
            }
            var surviving = cue
            surviving.start = max(cue.start, first.sourceStart)
            return (first.editorStart, surviving)
        }
        .sorted { lhs, rhs in
            if abs(lhs.editorStart - rhs.editorStart) > 0.000_001 { return lhs.editorStart < rhs.editorStart }
            return lhs.cue.start < rhs.cue.start
        }
        .map(\.cue)
    }

    static func suggest(
        cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord],
        timeline: RecordingClipTimeline, keeping existing: [RecordingChapter]
    ) -> [RecordingChapter] {
        let speech = words.isEmpty
            ? cues.map { ($0.start, $0.end) }
            : words.map { ($0.start, $0.end) }
        // Measure silence and 20 s spacing on the edited timeline in playback
        // order, while retaining each surviving run's source anchor for storage.
        let surviving = speech.flatMap { interval -> [(editorStart: TimeInterval, editorEnd: TimeInterval, sourceStart: TimeInterval)] in
            guard interval.0.isFinite, interval.1.isFinite, interval.1 > interval.0 else { return [] }
            return timeline.editorRuns(overlapping: interval.0, sourceEnd: interval.1).compactMap { run in
                guard let firstSlice = run.slices.first, run.editorEnd > run.editorStart else { return nil }
                return (run.editorStart, run.editorEnd, firstSlice.sourceStart)
            }
        }
        .sorted { lhs, rhs in
            if abs(lhs.editorStart - rhs.editorStart) > 0.000_001 { return lhs.editorStart < rhs.editorStart }
            return lhs.editorEnd < rhs.editorEnd
        }
        let readableCues = survivingCues(cues, words: words, through: timeline)
        let existingMapped = mapped(existing, through: timeline)
        var result = existing
        var lastSuggestion: TimeInterval?
        for (index, interval) in surviving.enumerated() {
            let time = interval.editorStart
            guard index == 0 || interval.editorStart - surviving[index - 1].editorEnd >= 2 else { continue }
            guard lastSuggestion.map({ time - $0 >= 20 }) ?? true else { continue }
            guard !existingMapped.contains(where: { abs($0.start - time) < 20 }) else { continue }
            let text = chapterText(readableCues, through: timeline, start: time, end: time + 20)
            let name = title(from: text)
            result.append(RecordingChapter(title: name.isEmpty ? "Chapter \(result.count + 1)" : name, start: interval.sourceStart, autoTitle: true))
            lastSuggestion = time
        }
        return result.sorted { $0.start < $1.start }
    }
}
