import CoreGraphics
import Foundation
import Testing

/// Remove Filler Words and Shorten Pauses: the pure planning behind them.
struct StudioCleanupTests {
    /// Words spaced 0.5 s apart, 0.3 s long, starting at `start`.
    private func words(_ texts: [String], start: TimeInterval = 0) -> [RecordingTranscriptWord] {
        texts.enumerated().map { index, text in
            let at = start + Double(index) * 0.5
            return RecordingTranscriptWord(text: " " + text, start: at, end: at + 0.3)
        }
    }

    private func fillers(_ texts: [String], language: String?, discourse: Bool = false) -> [String] {
        let list = words(texts)
        return TranscriptEditPlanner.fillerIndices(in: list, language: language, includingDiscourse: discourse)
            .map { texts[$0] }
    }

    // MARK: Filler words

    @Test func englishFillersMatchWholeWordsWithRepeatsAndPunctuation() {
        let texts = ["Um,", "so", "umbrella", "uh...", "Hmmm", "M", "mm", "um-hmm", "er", "error", "Ahh!", "UMMM", "erm,", "summer", "huh"]
        #expect(fillers(texts, language: "en") == ["Um,", "uh...", "Hmmm", "mm", "er", "Ahh!", "UMMM", "erm,"])
    }

    @Test func repeatedFillersCutAsOneStretch() {
        let list = words(["well", "um", "um,", "uh", "right"])
        let indices = TranscriptEditPlanner.fillerIndices(in: list, language: "en")
        #expect(indices == [1, 2, 3])
        let cuts = RecordingClipTimeline.mergedRanges(
            TranscriptEditPlanner.fillerCutRanges(at: indices, in: list, sourceDuration: 3))
        #expect(cuts.count == 1)
        // Bites into the silence around, never into "well" or "right".
        #expect(cuts[0].lowerBound > list[0].end && cuts[0].upperBound < list[4].start)
    }

    @Test func meaningfulWordsAreFillerOnlyWhenAskedFor() {
        let texts = ["I", "like", "it,", "you", "know,", "so", "basically", "do", "you", "knowledge"]
        #expect(fillers(texts, language: "en").isEmpty)
        #expect(fillers(texts, language: "en", discourse: true) == ["like", "you", "know,", "so", "basically"])
    }

    @Test func otherLanguagesUseTheirOwnLists() {
        // "er" is "he" in German and "there" in Dutch.
        #expect(fillers(["Äh,", "er", "kommt", "ähm", "gleich"], language: "de") == ["Äh,", "ähm"])
        #expect(fillers(["Er", "is", "eh", "een", "uh", "probleem"], language: "nl") == ["eh", "uh"])
        #expect(fillers(["Euh", "je", "pense,", "heu,", "que"], language: "fr") == ["Euh", "heu,"])
        #expect(fillers(["eh", "ehm", "pues"], language: "es") == ["ehm"])
        #expect(fillers(["えーと", "これは", "えーー", "です"], language: "ja") == ["えーと", "えーー"])
        #expect(fillers(["嗯", "这个", "呃"], language: "zh") == ["嗯", "呃"])
        #expect(fillers(["um", "uh"], language: "xx").isEmpty)
        #expect(fillers(["um"], language: nil).isEmpty)
        #expect(fillers(["also", "das", "ist", "halt", "so"], language: "de", discourse: true) == ["also", "halt"])
    }

    @Test func theTranscriptsLanguageComesFromItsWords() {
        let english = words("So today I want to show you how the new export settings work in the app".split(separator: " ").map(String.init))
        let german = words("Heute möchte ich euch zeigen wie die neuen Einstellungen für den Export funktionieren".split(separator: " ").map(String.init))
        #expect(TranscriptEditPlanner.language(of: english, fallback: "fr") == "en")
        #expect(TranscriptEditPlanner.language(of: german, fallback: "fr") == "de")
        #expect(TranscriptEditPlanner.language(of: [], fallback: "fr") == "fr")
    }

    // MARK: Pauses

    /// "Hello" 0–1 s, then 3 s of quiet, then "world" 4–5 s, in a 6 s recording.
    private let speech = [RecordingTranscriptWord(text: "Hello", start: 0, end: 1),
                          RecordingTranscriptWord(text: " world", start: 4, end: 5)]
    private let full = RecordingClipTimeline.full(sourceDuration: 6)
    private let screen = CGSize(width: 1000, height: 600)

    private func pauses(threshold: TimeInterval = PausePlanner.defaultThreshold, beat: TimeInterval = PausePlanner.defaultBeat,
                        timeline: RecordingClipTimeline? = nil, capture: PointerCaptureFile = PointerCaptureFile()) -> [PausePlanner.Pause] {
        PausePlanner.pauses(words: speech, timeline: timeline ?? full, sourceDuration: 6, threshold: threshold,
                            beat: beat, capture: capture, pointSize: screen)
    }

    @Test func aLongQuietStillPauseIsCutDownToTheBeat() throws {
        // The 1 s after "world" is not over 1.0 s, so only the middle pause qualifies.
        let found = pauses()
        #expect(found.count == 1)
        let pause = try #require(found.first)
        #expect(pause.gap == 1...4 && pause.activity == nil)
        #expect(abs(pause.cut.lowerBound - 1.15) < 1e-9 && abs(pause.cut.upperBound - 3.85) < 1e-9)
        #expect(abs(pause.saved - 2.7) < 1e-9)
        let shortened = try #require(full.removingSourceRanges([pause.cut]))
        #expect(abs(shortened.duration - 3.3) < 1e-9)
        // Shortened once, it's under the threshold and isn't offered again.
        #expect(pauses(timeline: shortened).isEmpty)
    }

    @Test func theThresholdAndTheBeatAreAdjustable() throws {
        #expect(pauses(threshold: 3.5).isEmpty)
        let longer = try #require(pauses(beat: 0.5).first)
        #expect(abs(longer.cut.lowerBound - 1.25) < 1e-9 && abs(longer.cut.upperBound - 3.75) < 1e-9)
        // A lower threshold also takes the 1 s after the last word.
        #expect(pauses(threshold: 0.8).map(\.gap) == [1...4, 5...6])
    }

    @Test func aPauseWithAClickOrPointerMovementStays() {
        func capture(_ change: (inout PointerCaptureFile) -> Void) -> PointerCaptureFile {
            var file = PointerCaptureFile()
            file.travel = [PointerTravelSample(time: 0.5, x: 0.5, y: 0.5)]
            change(&file)
            return file
        }
        #expect(pauses(capture: capture { _ in }).first?.activity == nil)
        let click = capture { $0.presses = [PointerPressEvent(time: 2.5, x: 0.5, y: 0.5, button: 0, phase: .down)] }
        #expect(pauses(capture: click).first?.activity == .click)
        // A click just before the pause is answered on screen during it.
        let justBefore = capture { $0.presses = [PointerPressEvent(time: 0.8, x: 0.5, y: 0.5, button: 0, phase: .up)] }
        #expect(pauses(capture: justBefore).first?.activity == .click)
        let earlier = capture { $0.presses = [PointerPressEvent(time: 0.5, x: 0.5, y: 0.5, button: 0, phase: .up)] }
        #expect(pauses(capture: earlier).first?.activity == nil)
        // 0.1 of a 1000 pt screen is 100 pt: a move. 0.003 is 3 pt: a hand resting on the mouse.
        let moved = capture { $0.travel.append(PointerTravelSample(time: 2, x: 0.6, y: 0.5)) }
        #expect(pauses(capture: moved).first?.activity == .pointer)
        let jitter = capture { $0.travel.append(PointerTravelSample(time: 2, x: 0.503, y: 0.5)) }
        #expect(pauses(capture: jitter).first?.activity == nil)
    }

    @Test func keysScrollsAndPenKeepAPause() {
        var keys = PointerCaptureFile()
        keys.keystrokes = [RecordingKeystrokeEvent(time: 3, modifiers: ["⌘"], key: "C")]
        #expect(pauses(capture: keys).first?.activity == .key)
        var scroll = PointerCaptureFile()
        scroll.scrolls = [PointerScrollEvent(time: 2, x: 0.5, y: 0.5, dx: 0, dy: -40)]
        #expect(pauses(capture: scroll).first?.activity == .scroll)
        var pen = PointerCaptureFile()
        pen.ink = [RecordingInkStroke(width: 0.01, points: [RecordingInkPoint(t: 2, x: 0.2, y: 0.2)])]
        #expect(pauses(capture: pen).first?.activity == .pen)
        // A stroke drawn earlier that fades out during the pause changes the screen too.
        var fading = PointerCaptureFile()
        fading.ink = [RecordingInkStroke(width: 0.01, points: [RecordingInkPoint(t: 0.1, x: 0.2, y: 0.2)], hideTime: 2)]
        #expect(pauses(capture: fading).first?.activity == .pen)
    }

    @Test func aChapterInsideACutMovesToWhereTheVideoPicksUp() {
        let cuts: [ClosedRange<TimeInterval>] = [1.15...3.85]
        let chapters = [RecordingChapter(title: "Start", start: 0), RecordingChapter(title: "Mid", start: 2),
                        RecordingChapter(title: "Edge", start: 1.15), RecordingChapter(title: "World", start: 4)]
        let kept = TranscriptEditPlanner.chapters(chapters, keptThrough: cuts)
        #expect(kept.map(\.start) == [0, 3.85, 3.85, 4])
        #expect(kept.map(\.id) == chapters.map(\.id))
        // A chapter suggested at the first word after a pause starts after the cut.
        let shortened = full.removingSourceRanges(cuts)!
        let mapped = RecordingChapterPlanner.mapped([chapters[0], chapters[3]], through: shortened)
        #expect(mapped.map(\.title) == ["Start", "World"])
    }

    @Test func cutFillersJoinTheQuietAroundThem() throws {
        // "so" 0–0.5, "um" 1.1–1.4, "then" 2.3–2.8: 0.6 s and 0.9 s of quiet,
        // neither over 1 s, until "um" goes and they become one.
        let list = [RecordingTranscriptWord(text: "so", start: 0, end: 0.5),
                    RecordingTranscriptWord(text: " um", start: 1.1, end: 1.4),
                    RecordingTranscriptWord(text: " then", start: 2.3, end: 2.8)]
        let timeline = RecordingClipTimeline.full(sourceDuration: 2.8)
        #expect(PausePlanner.pauses(words: list, timeline: timeline, sourceDuration: 2.8).isEmpty)
        let cut = try #require(TranscriptEditPlanner.cutRange(forWordsAt: 1...1, in: list, sourceDuration: 2.8))
        let withoutUm = try #require(timeline.removingSourceRanges([cut]))
        #expect(PausePlanner.speechGaps(words: list, timeline: withoutUm, sourceDuration: 2.8) == [0.5...2.3])
        let pause = try #require(PausePlanner.pauses(words: list, timeline: withoutUm, sourceDuration: 2.8).first)
        // The edited pause is 1.8 s less what was already cut with "um", less the beat.
        #expect(abs(pause.saved - (1.8 - (cut.upperBound - cut.lowerBound) - 0.3)) < 1e-9)
    }

    @Test func aSpedUpPauseIsMeasuredAsItPlays() throws {
        // The pause plays at 2×, so its 3 s last 1.5 s on screen.
        let timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1),
            RecordingClipSegment(sourceStart: 1, sourceEnd: 4, speed: 2),
            RecordingClipSegment(sourceStart: 4, sourceEnd: 6),
        ])
        let pause = try #require(pauses(timeline: timeline).first)
        #expect(abs(pause.saved - 1.2) < 1e-9)
        // 0.15 s kept on each side is 0.3 s of source at 2×.
        #expect(abs(pause.cut.lowerBound - 1.3) < 1e-9 && abs(pause.cut.upperBound - 3.7) < 1e-9)
        #expect(pauses(threshold: 1.6, timeline: timeline).isEmpty)
    }

    @Test func captionsAndChaptersFollowAShortenedPause() throws {
        let pause = try #require(pauses().first)
        let shortened = try #require(full.removingSourceRanges([pause.cut]))
        // A caption across the pause keeps its words.
        let cue = RecordingSubtitleCue(start: 0, end: 5, text: "Hello world")
        let captions = RecordingTranscript(words: speech, cues: [cue]).renderCaptions(in: shortened)
        #expect(captions.cues.map(\.text) == ["Hello world"] && captions.words.count == 2)
        // A chapter at "world" moves up by the time saved; a later one too.
        let chapters = [RecordingChapter(title: "One", start: 0), RecordingChapter(title: "Two", start: 4)]
        let mapped = RecordingChapterPlanner.mapped(chapters, through: shortened)
        #expect(mapped.map(\.title) == ["One", "Two"])
        #expect(abs(mapped[1].start - (4 - 2.7)) < 1e-9)
        // The Agent Prompt's word times move with it.
        let plan = RecordingAgentPromptPlan(title: "Pause", timeline: shortened, cues: [cue], words: speech, capture: nil)
        #expect(plan.words.map(\.text) == ["Hello", "world"])
        #expect(abs((plan.words.last?.start ?? 0) - 1.3) < 1e-9)
    }

    // MARK: Frames

    private func frame(_ changed: Int = 0) -> [UInt8] {
        var pixels = [UInt8](repeating: 200, count: PausePlanner.frameWidth * 180)
        for index in 0..<changed { pixels[index * 37] = 20 }
        return pixels
    }

    @Test func framesAreStillWithinACaretBlinkButNotThroughTyping() {
        #expect(PausePlanner.isStill([frame(), frame(), frame()]))
        // A caret's blink, about 4 pixels at this size, comes and goes.
        #expect(PausePlanner.isStill([frame(), frame(4), frame(), frame(4)]))
        #expect(!PausePlanner.isStill([frame(), frame(), frame(10)]))
        // Typing adds up against the first frame even when each step is small.
        #expect(!PausePlanner.isStill([frame(), frame(4), frame(8)]))
        #expect(!PausePlanner.isStill([frame()]))
        // A faint change below the grey threshold isn't a change.
        var faint = frame()
        for index in faint.indices { faint[index] = 210 }
        #expect(PausePlanner.isStill([frame(), faint]))
        #expect(PausePlanner.changedPixels(frame(), [0]) == Int.max)
    }

    @Test func framesAreSampledAcrossTheWholePause() {
        let times = PausePlanner.frameTimes(in: 1...2)
        #expect(times.first == 1 && times.last == 2 && times.count == 6)
        #expect(PausePlanner.frameTimes(in: 1...1.05).count == 2)
    }
}
