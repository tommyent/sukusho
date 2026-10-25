import CoreGraphics
import Foundation

nonisolated struct RecordingAgentPromptPlan: Sendable {
    struct Text: Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    struct Moment: Sendable {
        var time: TimeInterval
        var evidence: [String]
        /// Where to look, normalized to the captured source: the moment's
        /// click, rest or scroll, else the pointer at that time.
        var focus: CGPoint? = nil
    }

    let title: String
    let duration: TimeInterval
    let transcript: [Text]
    let words: [Text]
    let moments: [Moment]
    let hasInput: Bool
    /// Maps the edited times above to the screen master's.
    let timeline: RecordingClipTimeline
    /// The input log's travel, by time, on the screen master's timeline.
    let pointer: [PointerTravelSample]
    /// Pen strokes drawn during the take, on the screen master's timeline;
    /// the screen recording leaves the pen out, so strips draw them in.
    let ink: [RecordingInkStroke]
    /// The recording's own files, for an agent to read beyond the prompt.
    let files: SourceFiles?

    struct SourceFiles: Sendable {
        var screen: URL
        var input: URL?
    }

    /// True when the recording left out Sukusho's own windows.
    let excludesAppWindows: Bool
    /// The app and window the recording started on, when known.
    let source: CaptureSource?
    /// The recorded area in pixels, and pixels per point.
    let screen: Screen?

    struct Screen: Sendable {
        var width: Int
        var height: Int
        var scale: Double
    }

    /// `cursorNames` names recorded cursor images by artwork ID.
    init(title: String, timeline: RecordingClipTimeline, cues: [RecordingSubtitleCue],
         words: [RecordingTranscriptWord], capture: PointerCaptureFile?,
         cursorNames: [String: String] = [:], files: SourceFiles? = nil, excludesAppWindows: Bool = false,
         source: CaptureSource? = nil, screen: Screen? = nil) {
        self.title = title
        duration = timeline.duration
        hasInput = capture != nil
        self.files = files
        self.excludesAppWindows = excludesAppWindows
        self.source = source
        self.screen = screen

        func mapped(_ start: Double, _ end: Double, text: String) -> Text? {
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let slices = timeline.slices(overlapping: start, sourceEnd: end)
            let kept = slices.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart }
            // Never quote words removed by a cut, including a word cut in half.
            guard abs(kept - (end - start)) < 0.000_001,
                  let first = slices.first, let last = slices.last else { return nil }
            return Text(start: first.editorStart, end: last.editorEnd, text: text)
        }

        self.words = words.compactMap { mapped($0.start, $0.end, text: $0.displayText) }
            .sorted { $0.start < $1.start }
        var narration: [Text] = []
        for cue in cues where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start {
            if let full = mapped(cue.start, cue.end, text: cue.text) {
                narration.append(full)
                continue
            }
            let slices = timeline.slices(overlapping: cue.start, sourceEnd: cue.end)
            guard let first = slices.first, let last = slices.last else { continue }
            let timed = words.filter { $0.start >= cue.start && $0.start < cue.end }
                .sorted { $0.start < $1.start }
            let corrected = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            if !timed.isEmpty, timed.count == corrected.count {
                narration += zip(timed, corrected).compactMap { word, text in
                    mapped(word.start, word.end, text: text)
                }
            } else {
                // shortcut: changed word counts have no reliable corrected timing; retain only surviving recognizer words until word-level corrections exist.
                let surviving = timed.compactMap { mapped($0.start, $0.end, text: $0.displayText) }
                let text = surviving.isEmpty
                    ? "[Partially cut caption: surviving wording unavailable without word timings.]"
                    : "[Partially cut caption: surviving recognizer wording; corrected word timing unavailable.] "
                        + surviving.map(\.text).joined(separator: " ")
                narration.append(Text(start: first.editorStart, end: last.editorEnd, text: text))
            }
        }
        transcript = narration.sorted { $0.start < $1.start }

        var evidence = transcript.map {
            (time: $0.start, text: "Narration \(Self.timestamp($0.start))–\(Self.timestamp($0.end)): \(Self.escape($0.text))",
             position: CGPoint?.none)
        }
        func actionTime(_ source: Double) -> Double? {
            guard source.isFinite,
                  timeline.segments.contains(where: { source >= $0.sourceStart && source < $0.sourceEnd }) else { return nil }
            return timeline.editorTime(forSourceTime: source)
        }
        let artwork = Dictionary((capture?.artwork ?? []).map { ($0.artworkID, $0) }, uniquingKeysWith: { first, _ in first })
        // The cursor shows what the app under it offered: a grab, a draw, a text caret.
        func cursor(_ id: String?) -> String {
            guard let id else { return "" }
            if let name = cursorNames[id] { return "; cursor: \(name)" }
            guard let image = artwork[id] else { return "" }
            return String(format: "; cursor: custom, %.0f × %.0f pt, hot spot %.0f, %.0f", locale: Locale(identifier: "en_US_POSIX"),
                          image.referenceSize.width, image.referenceSize.height, image.anchorPoint.x, image.anchorPoint.y)
        }
        for click in capture?.presses ?? [] where click.phase == .down {
            guard click.x.isFinite, click.y.isFinite,
                  (0...1).contains(click.x), (0...1).contains(click.y),
                  let time = actionTime(click.time) else { continue }
            let button = click.button == 0 ? "left" : click.button == 1 ? "right" : "button \(click.button)"
            evidence.append((time, "Click \(Self.timestamp(time)): \(button); source position \(Self.position(click.x, click.y))\(Self.escape(cursor(click.artworkID))).",
                             CGPoint(x: click.x, y: click.y)))
        }
        for key in capture?.keystrokes ?? [] {
            guard let time = actionTime(key.time) else { continue }
            evidence.append((time, "Shortcut \(Self.timestamp(time)): \(Self.escape(Self.shortcutLabel(key))).", nil))
        }
        // Where the pointer rested or scrolled shows hover and scroll bugs that clicks miss.
        func editorSpan(_ start: Double, _ end: Double) -> (start: Double, end: Double)? {
            let slices = timeline.slices(overlapping: start, sourceEnd: end)
            guard let first = slices.first, let last = slices.last, abs(first.sourceStart - start) < 0.000_001 else { return nil }
            return (first.editorStart, last.editorEnd)
        }
        let ink = RecordingInkStroke.sanitized(capture?.ink ?? [])
        for stroke in ink {
            guard let last = stroke.points.last,
                  let span = editorSpan(stroke.startTime, max(last.t, stroke.startTime + 0.001)) else { continue }
            let xs = stroke.points.map { min(max($0.x, 0), 1) }, ys = stroke.points.map { min(max($0.y, 0), 1) }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            let shape = maxX - minX < 0.005 && maxY - minY < 0.005
                ? "a dot at source position \(Self.position(center.x, center.y))"
                : String(format: "a pen stroke over source x=%.3f–%.3f, y=%.3f–%.3f", locale: Locale(identifier: "en_US_POSIX"), minX, maxX, minY, maxY)
            let hidden = stroke.hideTime.flatMap(actionTime).map { (stroke.fadesOut ? "; it fades out at " : "; undone at ") + Self.timestamp($0) } ?? ""
            evidence.append((span.start, "Drew on screen \(Self.timestamp(span.start))–\(Self.timestamp(span.end)): \(shape)\(hidden).", center))
        }
        var motion: [(time: Double, text: String, position: CGPoint?, score: Double)] = []
        for rest in Self.rests(in: capture?.travel ?? [], until: timeline.segments.map(\.sourceEnd).max() ?? 0) {
            guard let span = editorSpan(rest.start, rest.end) else { continue }
            motion.append((span.start, "Pointer rested \(Self.timestamp(span.start))–\(Self.timestamp(span.end)) at source position \(Self.position(rest.x, rest.y)).",
                           CGPoint(x: rest.x, y: rest.y), span.end - span.start))
        }
        for run in Self.scrollRuns(capture?.scrolls ?? []) {
            guard let span = editorSpan(run.start, max(run.end, run.start + 0.001)) else { continue }
            let vertical = abs(run.dy) >= abs(run.dx)
            let direction = vertical ? (run.dy > 0 ? "up" : "down") : (run.dx > 0 ? "left" : "right")
            // input.json is read as written; Int() traps on a corrupt amount that doesn't fit.
            let amount = abs(vertical ? run.dy : run.dx)
            let distance = Int((amount < 1e9 ? amount : 1e9).rounded())
            let end = run.end > run.start ? span.end : span.start
            motion.append((span.start, "Scroll \(Self.timestamp(span.start))–\(Self.timestamp(end)): \(direction) \(distance) pt over \(run.count) events at source position \(Self.position(run.x, run.y)).",
                           CGPoint(x: run.x, y: run.y), end - span.start + 1))
        }
        // A long recording keeps its longest rests and scrolls, not one per pause.
        let motionLimit = min(24, max(6, Int(timeline.duration / 10)))
        evidence += motion.sorted { $0.score == $1.score ? $0.time < $1.time : $0.score > $1.score }
            .prefix(motionLimit).map { (time: $0.time, text: $0.text, position: $0.position) }
        let sorted = evidence.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        var grouped: [Moment] = []
        for event in sorted {
            if let last = grouped.last, event.time - last.time <= 0.5 {
                grouped[grouped.count - 1].evidence.append(event.text)
                grouped[grouped.count - 1].focus = last.focus ?? event.position
            } else {
                grouped.append(Moment(time: event.time, evidence: [event.text], focus: event.position))
            }
        }
        self.timeline = timeline
        let pointer = (capture?.travel ?? []).filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
        self.pointer = pointer
        self.ink = ink
        // A moment with no position of its own looks where the pointer was.
        moments = (grouped.isEmpty ? [Moment(time: 0, evidence: ["No timed narration or actions available."])] : grouped).map {
            var moment = $0
            moment.focus = moment.focus ?? Self.pointerPosition(in: pointer, at: timeline.sourceTime(at: moment.time))
            return moment
        }
    }

    /// `strips` holds each moment's strip span, nil where none was written.
    /// `sourceStills`: the stills came from the screen recording, not the edited movie.
    func markdown(frameTimes: [TimeInterval], strips: [ClosedRange<TimeInterval>?] = [], sourceStills: Bool = false) -> String {
        var text = "# \(Self.escape(title.split(whereSeparator: \.isWhitespace).joined(separator: " ")))\n\n"
        text += "Use this recorded walkthrough and its evidence as task context.\n\n"
        if let recorded = recordedLine { text += recorded + "\n\n" }
        text += "Times refer to the edited recording (\(Self.timestamp(duration))). Click coordinates are normalized to the captured source, with a top-left origin; "
            + (sourceStills ? "they match the stills." : "crop and zoom can move them in the stills.") + " Plain typing and control names were not recorded.\n\n"
        text += "Pointer rests of 0.7 s or more and scrolls come from the input log; a long recording lists only the longest ones.\n\n"
        let marks = ink.isEmpty ? "a red ring marks the pointer, which the screen recording doesn't show"
            : "a red ring marks the pointer and the pen's strokes are drawn in, since the screen recording shows neither"
        let hasStrips = strips.contains(where: { $0 != nil })
        let stripSpan = "\(Self.stripFrames) frames of the unedited screen recording, from \(Self.stripLead) s before the moment to \(Self.stripSpan - Self.stripLead) s after it, around where it happened"
        if sourceStills {
            text += "Each still shows the whole screen at its moment, from the unedited screen recording: cuts and speed changes apply, Studio's zoom, crop, background, camera and redactions don't; \(marks)."
                + (hasStrips ? " Each strip shows \(stripSpan).\n\n" : "\n\n")
        } else if hasStrips {
            text += "Each still shows the edited recording. Each strip shows \(stripSpan); \(marks).\n\n"
        }
        if !hasInput { text += "No input log is available for this recording.\n\n" }
        if excludesAppWindows {
            text += "Sukusho's own windows (Library, editor, Studio, preview cards, recording controls) were left out of this recording, so the frames show what was behind them.\n\n"
        }
        if let files {
            func code(_ url: URL) -> String { "`" + url.path.replacingOccurrences(of: "`", with: "'") + "`" }
            text += "## Source files\n\n"
            text += "- Screen recording: \(code(files.screen)): the unedited screen at full resolution, with no zoom, crop or style, and no pointer. It runs on the recording's own clock; cuts and speed changes in the edited recording shift the times above.\n"
            if let input = files.input {
                text += "- Input log: \(code(input)): JSON on the screen recording's clock, with pointer moves and drags (travel), clicks (presses), shortcuts (keystrokes), scrolls (scrolls), pen strokes drawn on screen (ink) and cursor images (artwork, base-64 PNG). Positions are normalized 0–1 from the top left.\n"
            }
            text += "\n"
        }
        for (index, moment) in moments.enumerated() {
            text += "## Moment \(index + 1) — \(Self.timestamp(moment.time))\n\n"
            text += moment.evidence.joined(separator: "\n\n") + "\n\n"
            if frameTimes.indices.contains(index) {
                text += "![Frame at \(Self.timestamp(frameTimes[index]))](stills/\(Self.stillName(index)))\n\n"
            } else {
                text += "Frame unavailable.\n\n"
            }
            if strips.indices.contains(index), let span = strips[index] {
                text += "![Frames \(Self.timestamp(span.lowerBound))–\(Self.timestamp(span.upperBound)) of the unedited screen recording](strips/\(Self.stillName(index)))\n\n"
            }
        }
        text += "## Transcript\n\n"
        text += transcript.isEmpty ? "No narration available.\n" : transcript.map {
            "- \(Self.timestamp($0.start))–\(Self.timestamp($0.end)): \(Self.escape($0.text))"
        }.joined(separator: "\n") + "\n"
        if !words.isEmpty {
            text += "\n## Word Timings\n\nOriginal recognizer wording and timing, mapped to the edited recording. Caption corrections may differ. Words intersected by cuts are omitted.\n\n| Start | End | Word |\n| --- | --- | --- |\n"
            text += words.map {
                "| \(Self.timestamp($0.start)) | \(Self.timestamp($0.end)) | \(Self.escape($0.text)) |"
            }.joined(separator: "\n") + "\n"
        }
        return text
    }

    /// Where the recording was made, for an agent to know the app and the pixel scale.
    /// For a screen or area it's the app in front at the start, so it says so.
    private var recordedLine: String? {
        var sentences: [String] = []
        if let source {
            let window = source.windowTitle.flatMap { $0.isEmpty ? nil : ", window \"\(Self.escape($0))\"" } ?? ""
            sentences.append("At the start, \(Self.escape(source.appName))"
                + (source.bundleIdentifier.map { " (\(Self.escape($0)))" } ?? "") + " was in front\(window).")
        }
        if let screen {
            sentences.append(String(format: "The recording is %d × %d px at %gx, so one point is %g pixels.", locale: Locale(identifier: "en_US_POSIX"),
                                    screen.width, screen.height, screen.scale, screen.scale))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    static func stillName(_ index: Int) -> String { String(format: "%04d.jpg", index + 1) }

    /// A strip's frames, evenly spaced over `stripSpan` seconds starting
    /// `stripLead` seconds before its moment: what follows an action matters more.
    static let stripFrames = 8
    static let stripLead = 0.25
    static let stripSpan = 1.0

    /// The edited times of a moment's strip, kept inside the recording.
    func stripTimes(for moment: Moment) -> [TimeInterval] {
        let start = min(max(0, moment.time - Self.stripLead), max(0, duration - Self.stripSpan))
        let last = max(0, duration - 0.001)
        return (0..<Self.stripFrames).map {
            min(start + Self.stripSpan * Double($0) / Double(Self.stripFrames - 1), last)
        }
    }

    /// Spans of at least `minimum` seconds where the pointer stayed within
    /// `radius` of where it stopped, on the source timeline. Travel has a
    /// sample per move and a slow heartbeat while still, so a rest ends at the
    /// first sample that moved away, or at `end`. Moving off starts with a
    /// small step (under 0.024 in two real recordings); a stop that ends more
    /// than `jump` away is a gap in the log, not a rest.
    static func rests(in travel: [PointerTravelSample], until end: TimeInterval, minimum: TimeInterval = 0.7,
                      radius: Double = 0.003, jump: Double = 0.05) -> [(start: Double, end: Double, x: Double, y: Double)] {
        let samples = travel.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
        guard var anchor = samples.first else { return [] }
        var result: [(start: Double, end: Double, x: Double, y: Double)] = []
        for sample in samples.dropFirst() {
            let step = hypot(sample.x - anchor.x, sample.y - anchor.y)
            guard step > radius else { continue }
            if sample.time - anchor.time >= minimum, step <= jump { result.append((anchor.time, sample.time, anchor.x, anchor.y)) }
            anchor = sample
        }
        if end - anchor.time >= minimum { result.append((anchor.time, end, anchor.x, anchor.y)) }
        return result
    }

    /// Scrolling with no pause longer than `gap`, summed, at its first position.
    static func scrollRuns(_ scrolls: [PointerScrollEvent], gap: TimeInterval = 0.35)
        -> [(start: Double, end: Double, count: Int, dx: Double, dy: Double, x: Double, y: Double)] {
        var runs: [(start: Double, end: Double, count: Int, dx: Double, dy: Double, x: Double, y: Double)] = []
        for scroll in scrolls.filter({ $0.time.isFinite }).sorted(by: { $0.time < $1.time }) {
            // A corrupt count would overflow the sum; a real one is a few dozen events.
            let count = min(max(scroll.count, 1), 10_000)
            if let last = runs.last, scroll.time - last.end <= gap {
                runs[runs.count - 1].end = scroll.time
                runs[runs.count - 1].count += count
                runs[runs.count - 1].dx += scroll.dx
                runs[runs.count - 1].dy += scroll.dy
            } else {
                runs.append((scroll.time, scroll.time, count, scroll.dx, scroll.dy, scroll.x, scroll.y))
            }
        }
        return runs
    }

    /// Where the pointer was at `time` on the source timeline: its last sample by then.
    static func pointerPosition(in travel: [PointerTravelSample], at time: TimeInterval) -> CGPoint? {
        var low = 0, high = travel.count
        while low < high {
            let middle = (low + high) / 2
            if travel[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        return CGPoint(x: travel[low - 1].x, y: travel[low - 1].y)
    }

    /// Modifiers then the key. Recordings made before keys were named by key
    /// code kept the character Shift typed; on the number row that maps back.
    // shortcut: assumes a US-style number row for those older recordings; other layouts keep their recorded character.
    static func shortcutLabel(_ key: RecordingKeystrokeEvent) -> String {
        let shifted: [String: String] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
                                         "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"]
        let name = key.modifiers.contains("\u{21E7}") ? shifted[key.key] ?? key.key : key.key
        return key.modifiers.joined() + name
    }

    static func position(_ x: Double, _ y: Double) -> String {
        String(format: "x=%.3f, y=%.3f", locale: Locale(identifier: "en_US_POSIX"), x, y)
    }

    static func timestamp(_ time: TimeInterval) -> String {
        let ms = Int((max(0, time.isFinite ? time : 0) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", ms / 60_000, ms / 1000 % 60, ms % 1000)
    }

    private static func escape(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "[", "]", "|", "#", "!"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result.components(separatedBy: .newlines).joined(separator: " ")
    }
}
