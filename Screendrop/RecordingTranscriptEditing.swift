//
//  RecordingTranscriptEditing.swift
//  Screendrop
//
//  Planning for transcript-driven video edits: turns word selections,
//  filler words, and pauses into source-time cut ranges for
//  RecordingClipTimeline.removingSourceRanges. Pure functions over the
//  word list so the studio model stays the single place that mutates the
//  timeline.
//

import CoreGraphics
import Foundation
import NaturalLanguage

nonisolated enum TranscriptEditPlanner {
    /// Hesitation sounds safe to cut without changing meaning, per language,
    /// spelled with repeated letters collapsed ("ummm" is "um", "hmm" is "hm").
    /// Deliberately conservative: a word that often carries meaning stays out
    /// ("er" is "he" in German and "there" in Dutch, so only English has it).
    private static let fillerSpellings: [String: Set<String>] = [
        "en": ["um", "uh", "uhm", "erm", "er", "ah", "hm", "m"],
        "de": ["äh", "ähm", "öh", "öhm", "ehm", "hm", "m"],
        "fr": ["euh", "heu", "hum", "hm", "m"],
        "es": ["ehm", "em", "hm", "m"],
        "it": ["ehm", "uhm", "hm", "m"],
        "pt": ["hum", "hã", "ãh", "ehm", "hm", "m"],
        "nl": ["eh", "ehm", "uh", "uhm", "hm", "m"],
        "ja": ["えー", "えーと", "えっと", "えーっと", "あのー", "うーん", "んー", "あー"],
        "zh": ["嗯", "呃"],
    ]

    /// Words and phrases that are often filler but often meaningful too, so
    /// they're cut only when the user asks. Lowercased, punctuation stripped.
    private static let discourseFillers: [String: [[String]]] = [
        "en": [["like"], ["so"], ["basically"], ["you", "know"]],
        "de": [["also"], ["halt"], ["sozusagen"]],
        "fr": [["genre"], ["bah"], ["ben"], ["du", "coup"]],
        "es": [["pues"], ["este"], ["bueno"], ["o", "sea"]],
        "it": [["tipo"], ["cioè"], ["allora"], ["praticamente"]],
        "pt": [["tipo"], ["né"], ["então"]],
        "nl": [["dus"], ["zeg", "maar"]],
        "ja": [["あの"], ["まあ"]],
        "zh": [["那个"], ["就是"]],
    ]

    /// Languages with a filler list, for the Words panel.
    static var fillerLanguages: Set<String> { Set(fillerSpellings.keys) }

    /// A word cut bites up to this far into the silence around it, so the
    /// splice lands in the pause instead of clipping a neighboring word.
    private static let maximumWordPadding: TimeInterval = 0.12

    /// The transcript's language code ("en", "de"…), read from its words;
    /// `fallback` (the user's language) when the text is too short to tell.
    static func language(of words: [RecordingTranscriptWord], fallback: String? = Locale.current.language.languageCode?.identifier) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words.map(\.displayText).joined(separator: " "))
        let detected = recognizer.dominantLanguage.flatMap { $0 == .undetermined ? nil : $0.rawValue }
        return (detected ?? fallback).map { String($0.prefix { $0 != "-" && $0 != "_" }) }
    }

    /// Letters only, lowercased, with leading and trailing punctuation gone,
    /// so "Um," is "um". Punctuation inside ("um-hmm") stays, and won't match.
    static func core(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    /// "ummm" → "um", "hmmm" → "hm": runs of one letter count once.
    private static func collapsed(_ text: String) -> String {
        var result = ""
        for character in text where character != result.last { result.append(character) }
        return result
    }

    static func isFiller(_ word: RecordingTranscriptWord, language: String?) -> Bool {
        guard let language, let spellings = fillerSpellings[language] else { return false }
        let core = core(word.displayText)
        // "M" alone is a letter, not a hum; "mm" is.
        guard core.count >= 2 || core.unicodeScalars.contains(where: { $0.value > 0x2E80 }),
              core.allSatisfy(\.isLetter) else { return false }
        return spellings.contains(collapsed(core))
    }

    /// The words to cut as filler: pure fillers, plus the optional discourse
    /// words and phrases. Whole words only, never part of a longer one.
    static func fillerIndices(
        in words: [RecordingTranscriptWord],
        language: String?,
        includingDiscourse: Bool = false
    ) -> [Int] {
        var indices = Set(words.indices.filter { isFiller(words[$0], language: language) })
        if includingDiscourse, let language, let phrases = discourseFillers[language] {
            let cores = words.map { core($0.displayText) }
            for phrase in phrases {
                for start in cores.indices where start + phrase.count <= cores.count {
                    let span = start..<(start + phrase.count)
                    if Array(cores[span]) == phrase { indices.formUnion(span) }
                }
            }
        }
        return indices.sorted()
    }

    /// Source range that removes the words at `range`, biting into the
    /// surrounding silence but never into a neighboring word.
    static func cutRange(
        forWordsAt range: ClosedRange<Int>,
        in words: [RecordingTranscriptWord],
        sourceDuration: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard range.lowerBound >= 0, range.upperBound < words.count else { return nil }
        let first = words[range.lowerBound]
        let last = words[range.upperBound]

        let previousEnd = range.lowerBound > 0 ? words[range.lowerBound - 1].end : 0
        let nextStart = range.upperBound < words.count - 1
            ? words[range.upperBound + 1].start
            : sourceDuration

        let gapBefore = max(0, first.start - previousEnd)
        let gapAfter = max(0, nextStart - last.end)
        let start = max(0, first.start - min(maximumWordPadding, gapBefore / 2))
        let end = min(sourceDuration, last.end + min(maximumWordPadding, gapAfter / 2))
        guard end > start else { return nil }
        return start...end
    }

    /// Chapters that start inside a cut move to where the video picks up
    /// again, so cutting the "um" a chapter opens with doesn't drop it.
    static func chapters(_ chapters: [RecordingChapter], keptThrough cuts: [ClosedRange<TimeInterval>]) -> [RecordingChapter] {
        chapters.map { chapter in
            // The kept footage starts at a cut's upper bound, not its lower one.
            guard let cut = cuts.first(where: { $0.lowerBound <= chapter.start && chapter.start < $0.upperBound }) else { return chapter }
            var moved = chapter
            moved.start = cut.upperBound
            return moved
        }
    }

    /// One cut range per filler word; overlaps and repeats ("um, um")
    /// collapse when merged.
    static func fillerCutRanges(
        at indices: [Int],
        in words: [RecordingTranscriptWord],
        sourceDuration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        indices.compactMap {
            cutRange(forWordsAt: $0...$0, in: words, sourceDuration: sourceDuration)
        }
    }
}

/// Shorten Pauses: speech gaps longer than a threshold, cut down to a short
/// beat, but only where nothing happens on screen. A pause qualifies when
/// it's quiet (no surviving word in it) and still: no click, key, scroll or
/// pen stroke in it, the pointer moves no more than a few points, and its
/// frames don't change (checked by the caller with `isStill`, since plain
/// typing is never logged).
nonisolated enum PausePlanner {
    static let defaultThreshold: TimeInterval = 1.0
    static let defaultBeat: TimeInterval = 0.3
    static let thresholdRange: ClosedRange<TimeInterval> = 0.5...5
    static let beatRange: ClosedRange<TimeInterval> = 0.1...1
    /// Pointer travel within a pause up to this many points is a hand
    /// resting on the mouse, not a move.
    static let pointerTolerance: CGFloat = 4
    /// A click just before a pause is often answered on screen during it.
    static let responseMargin: TimeInterval = 0.3
    /// Frames are compared this often across a pause.
    static let frameInterval: TimeInterval = 0.2
    /// Frames are compared at this width, in grey.
    static let frameWidth = 320
    /// A pixel changes when its grey level moves more than this (of 255).
    static let pixelDelta = 24
    /// More changed pixels than this is a change on screen. A blinking text
    /// caret is about 4 at this size and a typed character about 3 (inferred
    /// from glyph sizes on a 2x screen), so two characters count.
    static let maximumChangedPixels = 6

    enum Activity: String, Sendable {
        case click, key, scroll, pen, pointer
    }

    struct Pause: Equatable, Sendable {
        /// The quiet stretch on the source timeline, between surviving words.
        var gap: ClosedRange<TimeInterval>
        /// What a shorten removes, on the source timeline.
        var cut: ClosedRange<TimeInterval>
        /// Seconds the edited video gets shorter.
        var saved: TimeInterval
        /// Why it stays, from the input log; nil when the log shows nothing.
        var activity: Activity?
    }

    /// Stretches with no surviving word, on the source timeline, including
    /// before the first word and after the last: the speech model the
    /// chapter suggestions use, a word counting while any of it survives.
    static func speechGaps(
        words: [RecordingTranscriptWord],
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        guard sourceDuration > 0, !words.isEmpty else { return [] }
        let speech = words.compactMap { word -> (TimeInterval, TimeInterval)? in
            guard word.start.isFinite, word.end.isFinite, word.end > word.start,
                  !timeline.slices(overlapping: word.start, sourceEnd: word.end).isEmpty else { return nil }
            return (word.start, word.end)
        }.sorted { $0.0 < $1.0 }
        guard !speech.isEmpty else { return [] }
        var gaps: [ClosedRange<TimeInterval>] = []
        var spokenEnd: TimeInterval = 0
        for (start, end) in speech {
            if start > spokenEnd { gaps.append(spokenEnd...start) }
            spokenEnd = max(spokenEnd, end)
        }
        if sourceDuration > spokenEnd { gaps.append(spokenEnd...sourceDuration) }
        return gaps
    }

    /// Every pause the edited video still holds for longer than `threshold`,
    /// with the cut that leaves `beat` of it, half on each side.
    static func pauses(
        words: [RecordingTranscriptWord],
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        threshold: TimeInterval = defaultThreshold,
        beat: TimeInterval = defaultBeat,
        capture: PointerCaptureFile = PointerCaptureFile(),
        pointSize: CGSize = CGSize(width: 1920, height: 1080)
    ) -> [Pause] {
        let beat = min(max(beat, 0), threshold)
        return speechGaps(words: words, timeline: timeline, sourceDuration: sourceDuration).compactMap { gap in
            let slices = timeline.slices(overlapping: gap.lowerBound, sourceEnd: gap.upperBound)
            let length = slices.reduce(0) { $0 + $1.editorEnd - $1.editorStart }
            guard length > threshold,
                  let start = sourceTime(after: beat / 2, in: slices),
                  let end = sourceTime(after: beat / 2, in: slices.reversed().map(reversed)),
                  end > start else { return nil }
            let cut = start...end
            let saved = timeline.slices(overlapping: start, sourceEnd: end).reduce(0) { $0 + $1.editorEnd - $1.editorStart }
            guard saved >= 0.05 else { return nil }
            return Pause(gap: gap, cut: cut, saved: saved,
                         activity: activity(in: gap, capture: capture, pointSize: pointSize))
        }
    }

    /// The source time `editorSeconds` into the slices' edited time.
    private static func sourceTime(after editorSeconds: TimeInterval, in slices: [RecordingClipTimeline.Slice]) -> TimeInterval? {
        var remaining = editorSeconds
        for slice in slices {
            let length = slice.editorEnd - slice.editorStart
            if remaining <= length, length > 0 {
                return slice.sourceStart + (slice.sourceEnd - slice.sourceStart) * remaining / length
            }
            remaining -= length
        }
        return nil
    }

    /// A slice read from its end, for walking a pause backwards: source ends
    /// swap and edited times negate, so `sourceTime(after:in:)` counts back
    /// from the slice's end and still answers in source time.
    private static func reversed(_ slice: RecordingClipTimeline.Slice) -> RecordingClipTimeline.Slice {
        RecordingClipTimeline.Slice(segmentID: slice.segmentID,
                                    sourceStart: slice.sourceEnd, sourceEnd: slice.sourceStart,
                                    editorStart: -slice.editorEnd, editorEnd: -slice.editorStart)
    }

    /// What the input log shows happening in `gap`, or nil when it's still.
    static func activity(
        in gap: ClosedRange<TimeInterval>,
        capture: PointerCaptureFile,
        pointSize: CGSize
    ) -> Activity? {
        let watched = (gap.lowerBound - responseMargin)...gap.upperBound
        if capture.presses.contains(where: { watched.contains($0.time) }) { return .click }
        if capture.keystrokes.contains(where: { watched.contains($0.time) }) { return .key }
        if capture.scrolls.contains(where: { watched.contains($0.time) }) { return .scroll }
        let penShows = capture.ink.contains { stroke in
            stroke.points.contains { watched.contains($0.t) }
                || stroke.hideTime.map { hide in
                    hide <= gap.upperBound && hide + RecordingInkTimeline.fadeDuration >= gap.lowerBound
                } == true
        }
        if penShows { return .pen }

        // The pointer's place as the pause starts, then everywhere it goes.
        // One pass, unsorted: a long recording has many samples and many pauses.
        var before: PointerTravelSample?
        var inside: [PointerTravelSample] = []
        for sample in capture.travel where sample.time.isFinite && sample.x.isFinite && sample.y.isFinite {
            if gap.contains(sample.time) {
                inside.append(sample)
            } else if sample.time < gap.lowerBound, sample.time > before?.time ?? -.infinity {
                before = sample
            }
        }
        let anchor = before ?? inside.min { $0.time < $1.time }
        if let anchor {
            let moved = inside.contains { sample in
                hypot((sample.x - anchor.x) * pointSize.width, (sample.y - anchor.y) * pointSize.height) > pointerTolerance
            }
            if moved { return .pointer }
        }
        return nil
    }

    /// Times to sample a pause's frames: its ends and every `frameInterval`.
    static func frameTimes(in gap: ClosedRange<TimeInterval>) -> [TimeInterval] {
        let count = max(1, Int(((gap.upperBound - gap.lowerBound) / frameInterval - 1e-9).rounded(.up)))
        return (0...count).map { gap.lowerBound + (gap.upperBound - gap.lowerBound) * Double($0) / Double(count) }
    }

    /// Pixels whose grey level differs by more than `pixelDelta` between two
    /// same-size grey frames.
    static func changedPixels(_ first: [UInt8], _ second: [UInt8]) -> Int {
        guard first.count == second.count else { return Int.max }
        var count = 0
        for index in first.indices where abs(Int(first[index]) - Int(second[index])) > pixelDelta { count += 1 }
        return count
    }

    /// Still when every frame matches the first, within a caret's blink.
    /// Comparing with the first, not the last, lets typing add up.
    static func isStill(_ frames: [[UInt8]]) -> Bool {
        guard let first = frames.first, frames.count >= 2 else { return false }
        return frames.dropFirst().allSatisfy { changedPixels(first, $0) <= maximumChangedPixels }
    }
}
