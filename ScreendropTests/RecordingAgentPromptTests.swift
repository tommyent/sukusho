import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

struct RecordingAgentPromptTests {
    private let cut = RecordingClipTimeline(segments: [
        .init(sourceStart: 0, sourceEnd: 2),
        .init(sourceStart: 4, sourceEnd: 8, speed: 2),
    ])

    @Test func cutsAndSpeedMapAllEvidenceWithoutLeakingRemovedSpeech() {
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: cut, cues: [
            .init(start: 0, end: 1, text: "Corrected caption"),
            .init(start: 2, end: 4, text: "Removed secret"),
            .init(start: 4, end: 6, text: "Fast caption"),
        ], words: [
            .init(text: "Original", start: 0, end: 1),
            .init(text: "Removed secret", start: 2, end: 4),
            .init(text: "Fast", start: 4, end: 6),
        ], capture: PointerCaptureFile(presses: [
            .init(time: 2, x: 0.1, y: 0.2, button: 0, phase: .down),
            .init(time: 3, x: 0.1, y: 0.2, button: 0, phase: .down),
            .init(time: 5, x: 0.72, y: 0.28, button: 0, phase: .down),
            .init(time: 5.1, x: 0.72, y: 0.28, button: 0, phase: .up),
        ], keystrokes: [.init(time: 5.3, modifiers: ["⌘"], key: "E")]))
        #expect(plan.duration == 4)
        #expect(plan.transcript.map(\.text) == ["Corrected caption", "Fast caption"])
        #expect(plan.transcript[1].start == 2 && plan.transcript[1].end == 3)
        let markdown = plan.markdown(frameTimes: plan.moments.map(\.time))
        #expect(!markdown.contains("Removed secret"))
        #expect(markdown.contains("Click 00:02.500: left; source position x=0.720, y=0.280"))
        #expect(markdown.contains("Shortcut 00:02.650: ⌘E"))
        #expect(markdown.components(separatedBy: "Click 00:").count == 2)
        #expect(markdown.contains("Original recognizer wording"))
        #expect(plan.words.map(\.text) == ["Original", "Fast"])
    }

    @Test func partialCueKeepsCorrectedSurvivingWords() {
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: cut,
            cues: [.init(start: 1, end: 5, text: "Fixed private finish")], words: [
                .init(text: "wrong ", start: 1, end: 2),
                .init(text: "secret ", start: 2, end: 4),
                .init(text: "finish", start: 4, end: 5),
            ], capture: nil)
        #expect(plan.transcript.map(\.text) == ["Fixed", "finish"])
        #expect(plan.transcript.map(\.start) == [1, 2])
        #expect(!plan.markdown(frameTimes: []).contains("private"))
    }

    @Test func partialCueWithoutReliableCorrectedTimingDoesNotDumpWholeCaption() {
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: cut,
            cues: [.init(start: 1, end: 5, text: "Removed secret and surviving speech")], words: [], capture: nil)
        #expect(plan.transcript.count == 1)
        #expect(plan.transcript[0].text.contains("wording unavailable"))
        #expect(!plan.markdown(frameTimes: []).contains("Removed secret"))
    }

    @Test func groupingPreservesEveryActionAndDoesNotChainOrCapMoments() {
        let keys = (0..<200).map { RecordingKeystrokeEvent(time: Double($0), modifiers: ["⌘"], key: "K") }
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 201), cues: [], words: [],
                                           capture: PointerCaptureFile(keystrokes: keys))
        #expect(plan.moments.count == 200)
        let close = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 2), cues: [], words: [],
            capture: PointerCaptureFile(keystrokes: [0.0, 0.4, 0.8].map { .init(time: $0, key: "⇥") }))
        #expect(close.moments.count == 2)
        #expect(close.moments[0].evidence.count == 2)
        #expect(close.moments[1].evidence.count == 1)
    }

    @Test func cueOnlySilentAndLiteralMarkdownRemainUsable() {
        let silent = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 1), cues: [], words: [], capture: nil)
        #expect(silent.moments.count == 1 && silent.moments[0].time == 0)
        #expect(silent.markdown(frameTimes: [0]).contains("No input log"))
        #expect(silent.markdown(frameTimes: [0]).contains("No narration available"))
        let plan = RecordingAgentPromptPlan(title: "Title\n# injected", timeline: .full(sourceDuration: 1),
            cues: [.init(start: 0, end: 0.5, text: "![link](file) <script> | **text**")], words: [], capture: nil)
        let markdown = plan.markdown(frameTimes: [0.025])
        #expect(markdown.contains("# Title \\# injected\n"))
        #expect(markdown.contains("\\!\\[link\\](file) &lt;script&gt; \\| \\*\\*text\\*\\*"))
        #expect(markdown.contains("![Frame at 00:00.025](stills/0001.jpg)"))
        #expect(!markdown.contains("## Word Timings"))
    }

    @Test func invalidEventsAndFinalBoundaryAreExcluded() {
        let capture = PointerCaptureFile(presses: [
            .init(time: .nan, x: 0, y: 0, button: 0, phase: .down),
            .init(time: 0, x: .infinity, y: 0, button: 0, phase: .down),
            .init(time: 1, x: 0, y: 0, button: 0, phase: .down),
        ])
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 1), cues: [], words: [], capture: capture)
        #expect(plan.moments[0].evidence == ["No timed narration or actions available."])
    }

    @Test func restsAndScrollRunsBecomeMomentsInTimeOrder() {
        let travel: [PointerTravelSample] = [
            .init(time: 0, x: 0.1, y: 0.1), .init(time: 0.5, x: 0.1, y: 0.1), // heartbeat while still
            .init(time: 1.98, x: 0.11, y: 0.1), // moving off starts with a small step
            .init(time: 2, x: 0.5, y: 0.5), .init(time: 2.02, x: 0.501, y: 0.5), .init(time: 3.5, x: 0.501, y: 0.5),
            .init(time: 4, x: 0.51, y: 0.5), .init(time: 4.02, x: 0.9, y: 0.9), .init(time: 4.3, x: 0.2, y: 0.2), // too short a stop at 0.9
        ]
        let scrolls = [5.0, 5.1, 5.2].map { PointerScrollEvent(time: $0, x: 0.3, y: 0.4, dx: 0, dy: -10) }
            + [PointerScrollEvent(time: 8, x: 0.6, y: 0.6, dx: 0, dy: 25, count: 2)]
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 10), cues: [], words: [],
                                           capture: PointerCaptureFile(travel: travel, scrolls: scrolls))
        let markdown = plan.markdown(frameTimes: [])
        #expect(markdown.contains("Pointer rested 00:00.000–00:01.980 at source position x=0.100, y=0.100."))
        #expect(markdown.contains("Pointer rested 00:02.000–00:04.000 at source position x=0.500, y=0.500."))
        #expect(markdown.contains("Pointer rested 00:04.300–00:10.000 at source position x=0.200, y=0.200."))
        #expect(!markdown.contains("x=0.900"))
        #expect(markdown.contains("Scroll 00:05.000–00:05.200: down 30 pt over 3 events at source position x=0.300, y=0.400."))
        #expect(markdown.contains("Scroll 00:08.000–00:08.000: up 25 pt over 2 events at source position x=0.600, y=0.600."))
        #expect(plan.moments.map(\.time) == [0, 2, 4.3, 5, 8])
    }

    @Test func aStopThatEndsInAJumpIsAGapInTheLogNotARest() {
        // A real recording's log went 0.83 s without a sample, then the pointer was 0.17 away.
        let travel: [PointerTravelSample] = [
            .init(time: 0, x: 0.735, y: 0.668), .init(time: 0.833, x: 0.729, y: 0.499), .init(time: 2, x: 0.735, y: 0.499),
        ]
        #expect(RecordingAgentPromptPlan.rests(in: travel, until: 2).map(\.start) == [0.833])
    }

    @Test func restsAndScrollsFollowCutsAndSpeed() {
        let capture = PointerCaptureFile(travel: [
            .init(time: 2.5, x: 0.2, y: 0.2), .init(time: 4.98, x: 0.21, y: 0.2), .init(time: 5, x: 0.4, y: 0.4),
            .init(time: 7, x: 0.41, y: 0.4), .init(time: 7.02, x: 0.8, y: 0.8),
        ], scrolls: [.init(time: 3, x: 0.1, y: 0.1, dx: 5, dy: 0), .init(time: 6, x: 0.1, y: 0.1, dx: -40, dy: 2)])
        let markdown = RecordingAgentPromptPlan(title: "Fixture", timeline: cut, cues: [], words: [], capture: capture)
            .markdown(frameTimes: [])
        #expect(!markdown.contains("x=0.200")) // its rest starts inside the cut
        #expect(markdown.contains("Pointer rested 00:02.500–00:03.500 at source position x=0.400, y=0.400."))
        #expect(markdown.contains("Scroll 00:03.000–00:03.000: right 40 pt over 1 events"))
        #expect(!markdown.contains(": left"))
    }

    @Test func manyRestsAndScrollsAreCappedToTheLongest() {
        let travel = (0..<60).map { PointerTravelSample(time: Double($0), x: Double($0 % 2) * 0.02, y: 0.5) }
            + [PointerTravelSample(time: 60, x: 0.9, y: 0.9), PointerTravelSample(time: 70, x: 0.91, y: 0.9)]
        let markdown = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 71), cues: [], words: [],
                                               capture: PointerCaptureFile(travel: travel)).markdown(frameTimes: [])
        #expect(markdown.components(separatedBy: "Pointer rested").count - 1 == 7) // 71 s: up to 7
        #expect(markdown.contains("Pointer rested 01:00.000–01:10.000"))
        #expect(markdown.contains("Pointer rested 00:00.000–00:01.000"))
        #expect(!markdown.contains("Pointer rested 00:06.000"))
        let long = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 3_000), cues: [], words: [],
            capture: PointerCaptureFile(travel: (0..<1_000).map { .init(time: Double($0) * 3, x: Double($0 % 2) * 0.02, y: 0.5) }))
        #expect(long.moments.count == 24)
    }

    @Test func clicksNameTheirCursorAndThePromptLinksTheRecordingsFiles() {
        let shape = PointerArtwork(artworkID: "custom", imageData: Data([1]), anchorPoint: .init(x: 15, y: 15),
                                   referenceSize: .init(width: 64, height: 40))
        let capture = PointerCaptureFile(presses: [
            .init(time: 1, x: 0.1, y: 0.1, button: 0, phase: .down, artworkID: "grab"),
            .init(time: 3, x: 0.2, y: 0.2, button: 0, phase: .down, artworkID: "custom"),
            .init(time: 5, x: 0.3, y: 0.3, button: 0, phase: .down),
        ], artwork: [shape])
        let files = RecordingAgentPromptPlan.SourceFiles(screen: URL(fileURLWithPath: "/tmp/A b.screendroprec/screen.mov"),
                                                         input: URL(fileURLWithPath: "/tmp/A b.screendroprec/input.json"))
        let markdown = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 6), cues: [], words: [],
            capture: capture, cursorNames: ["grab": "open hand (can grab)"], files: files).markdown(frameTimes: [])
        #expect(markdown.contains("Click 00:01.000: left; source position x=0.100, y=0.100; cursor: open hand (can grab)."))
        #expect(markdown.contains("Click 00:03.000: left; source position x=0.200, y=0.200; cursor: custom, 64 × 40 pt, hot spot 15, 15."))
        #expect(markdown.contains("Click 00:05.000: left; source position x=0.300, y=0.300."))
        #expect(markdown.contains("- Screen recording: `/tmp/A b.screendroprec/screen.mov`: the unedited screen"))
        #expect(markdown.contains("- Input log: `/tmp/A b.screendroprec/input.json`: JSON on the screen recording's clock"))
        let bare = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 1), cues: [], words: [], capture: nil)
        #expect(!bare.markdown(frameTimes: []).contains("## Source files"))
    }

    @MainActor @Test func recordedCursorsAreNamedWhenTheyAreAppKitsOwnOrTheEditorsPlus() throws {
        _ = NSApplication.shared // AppKit draws its cursors only once there's an app
        let iBeam = try #require(PointerArtworkCapture.capture(.iBeam, id: "text"))
        let plus = try #require(PointerArtworkCapture.capture(.annotationPlus, id: "draw"))
        var other = iBeam
        other.artworkID = "other"
        other.imageData = Data([1, 2, 3])
        // A recording's plus had the same pixels in different PNG bytes.
        var recoded = plus
        recoded.artworkID = "recoded"
        recoded.imageData = try #require(NSBitmapImageRep(data: plus.imageData)?.representation(using: .png, properties: [.interlaced: true]))
        #expect(recoded.imageData != plus.imageData)
        #expect(PointerArtworkCapture.names(for: [iBeam, plus, other, recoded])
            == ["text": "I-beam (text)", "draw": "plus (Sukusho's drawing cursor)", "recoded": "plus (Sukusho's drawing cursor)"])
    }

    @MainActor @Test func shortcutsReadByKeyNotByTheCharacterShiftTypes() throws {
        func threeKey(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 20))
        }
        let shifted = try RecordingKeystrokeRecorder.keyLabel(for: threeKey("#", [.shift, .command]))
        #expect(shifted == RecordingKeystrokeRecorder.keyLabel(for: try threeKey("3", [.command])))
        #expect(shifted != "#")
        // Recordings made before kept the character Shift typed.
        #expect(RecordingAgentPromptPlan.shortcutLabel(.init(time: 0, modifiers: ["⇧", "⌘"], key: "#")) == "⇧⌘3")
        #expect(RecordingAgentPromptPlan.shortcutLabel(.init(time: 0, modifiers: ["⌘"], key: "#")) == "⌘#")
        #expect(RecordingAgentPromptPlan.shortcutLabel(.init(time: 0, modifiers: ["⇧", "⌘"], key: "C")) == "⇧⌘C")
    }

    @Test func thePromptWarnsOnlyWhenSukushosWindowsWereLeftOut() {
        func markdown(excluding: Bool) -> String {
            RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 1), cues: [], words: [], capture: nil,
                                     excludesAppWindows: excluding).markdown(frameTimes: [])
        }
        #expect(markdown(excluding: true).contains("Sukusho's own windows (Library, editor, Studio, preview cards, recording controls) were left out of this recording"))
        #expect(!markdown(excluding: false).contains("left out"))
    }

    @Test func scrollsCoalesceSanitizeAndDecode() throws {
        let raw = [0.0, 0.03, 0.09, 0.12].map { PointerScrollEvent(time: $0, x: 0.5, y: 0.5, dx: 1, dy: -4) }
        let coalesced = PointerScrollEvent.coalesced(raw)
        #expect(coalesced.count == 2 && coalesced[0].count == 3 && coalesced[0].dy == -12 && coalesced[1].time == 0.12)
        let capture = PointerCaptureFile(scrolls: coalesced + [PointerScrollEvent(time: .nan, x: 0.5, y: 0.5, dx: 0, dy: 1)])
        let sanitized = PointerStreamSanitizer.sanitize(
            capture, options: PointerSanitizeOptions(recordingSizeInPoints: CGSize(width: 800, height: 600))
        ).sanitizedCapture
        #expect(sanitized.scrolls == coalesced)
        #expect(try JSONDecoder().decode(PointerCaptureFile.self, from: JSONEncoder().encode(sanitized)).scrolls == coalesced)
        #expect(try JSONDecoder().decode(PointerCaptureFile.self, from: Data(#"{"travel":[]}"#.utf8)).scrolls.isEmpty)
    }

    @Test func scrollsOutsideTheFrameNeitherSwallowNorJoinOnesInside() {
        // An area recording: scrolling outside it starts a group, and later joins one inside.
        let raw = [
            PointerScrollEvent(time: 0, x: 1.5, y: 0.5, dx: 0, dy: -100),
            PointerScrollEvent(time: 0.03, x: 0.5, y: 0.5, dx: 0, dy: -4),
            PointerScrollEvent(time: 0.05, x: 0.5, y: 0.5, dx: 0, dy: -4),
            PointerScrollEvent(time: 0.25, x: 1.0005, y: 0.5, dx: 0, dy: -4),
            PointerScrollEvent(time: 0.3, x: 0.5, y: -0.2, dx: 0, dy: -100),
        ]
        #expect(PointerScrollEvent.coalesced(raw) == [
            PointerScrollEvent(time: 0.03, x: 0.5, y: 0.5, dx: 0, dy: -8, count: 2),
            PointerScrollEvent(time: 0.25, x: 1, y: 0.5, dx: 0, dy: -4),
        ])
    }

    @Test func extractedSchemasStillDecodeLegacyInputAndCueOnlyTranscripts() throws {
        let capture = try JSONDecoder().decode(PointerCaptureFile.self, from: Data(#"{"travel":[{"time":0,"x":0.5,"y":0.25}],"presses":[]}"#.utf8))
        #expect(capture.keystrokes.isEmpty && capture.artwork.isEmpty && !capture.isSanitized)
        #expect(capture.travel.first?.kind == .move)
        let decoded = try JSONDecoder().decode(PointerCaptureFile.self, from: JSONEncoder().encode(capture))
        #expect(decoded == capture)
        let cue = try JSONDecoder().decode(RecordingSubtitleCue.self, from: Data(#"{"start":0,"end":1,"text":"Legacy cue"}"#.utf8))
        #expect(cue.text == "Legacy cue")
    }

    @Test func stripsShowTheMasterAroundEachMomentWithThePointerRinged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await makeMovie(at: movie) // red until 1 s, then blue
        let plan = RecordingAgentPromptPlan(title: "Strip", timeline: .full(sourceDuration: 3), cues: [], words: [],
            capture: PointerCaptureFile(travel: [.init(time: 0, x: 0.25, y: 0.5), .init(time: 0.88, x: 0.26, y: 0.5),
                                                 .init(time: 0.9, x: 0.75, y: 0.5)],
                                        presses: [.init(time: 0.9, x: 0.75, y: 0.5, button: 0, phase: .down)]))
        #expect(plan.moments.map(\.time) == [0, 0.9])
        #expect(plan.moments.map(\.focus) == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5)])
        let folder = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory, master: movie)
        let markdown = try String(contentsOf: folder.appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(markdown.contains("![Frames 00:00.650–00:01.650 of the unedited screen recording](strips/0002.jpg)"))
        #expect(markdown.contains("a red ring marks the pointer"))
        let data = try Data(contentsOf: folder.appendingPathComponent("strips/0002.jpg"))
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 4 * 96 && image.height == 2 * 64) // a small master is used whole, never enlarged
        let first = try pixel(image, x: 48, y: 32), last = try pixel(image, x: 3 * 96 + 48, y: 64 + 32)
        #expect(first[0] > 200 && first[2] < 60)
        #expect(last[2] > 200 && last[0] < 60)
        // The master has no pointer; the ring around x 0.75 in the last frame stands out from the blue.
        #expect(try pixel(image, x: 3 * 96 + 72 + 9, y: 64 + 32)[0] > 150)
        #expect(try pixel(image, x: 3 * 96 + 24 + 9, y: 64 + 32)[0] < 60)
    }

    @Test func generatedFolderContainsMatchingStillsAndPreservesPriorExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await makeMovie(at: movie)
        let plan = RecordingAgentPromptPlan(title: "Fixture/path", timeline: .full(sourceDuration: 3),
            cues: [.init(start: 0, end: 0.5, text: "Red"), .init(start: 2, end: 2.5, text: "Blue")], words: [], capture: nil)
        let first = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory)
        let markdown = try String(contentsOf: first.appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(markdown.contains("stills/0001.jpg") && markdown.contains("stills/0002.jpg"))
        #expect(!markdown.contains("strips/") && !FileManager.default.fileExists(atPath: first.appendingPathComponent("strips").path))
        #expect(first.lastPathComponent == "Fixture-path_agent-prompt")
        let firstData = try Data(contentsOf: first.appendingPathComponent("stills/0001.jpg"))
        let lastData = try Data(contentsOf: first.appendingPathComponent("stills/0002.jpg"))
        #expect(firstData != lastData)
        let red = try sample(firstData), blue = try sample(lastData)
        #expect(red[0] > 200 && red[2] < 50)
        #expect(blue[2] > 200 && blue[0] < 50)
        let again = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory)
        #expect(again.lastPathComponent == "Fixture-path_agent-prompt_2")
        let third = try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory)
        #expect(third.lastPathComponent == "Fixture-path_agent-prompt_3")
        #expect(try String(contentsOf: first.appendingPathComponent("prompt.md"), encoding: .utf8) == markdown)
        let invalid = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 99), cues: [], words: [], capture: nil)
        do { _ = try await RecordingAgentPromptWriter.write(movie: movie, plan: invalid, to: directory); Issue.record("Mismatched movie accepted") }
        catch RecordingAgentPromptWriter.ExportError.invalidMovie { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".agent-prompt-") })
    }

    @Test func cancellationRemovesStagingAndKeepsExistingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prior = directory.appendingPathComponent("prior.txt")
        try "keep".write(to: prior, atomically: true, encoding: .utf8)
        let movie = directory.appendingPathComponent("fixture.mov")
        try await makeMovie(at: movie)
        let plan = RecordingAgentPromptPlan(title: "Fixture", timeline: .full(sourceDuration: 3),
            cues: [0.0, 0.6, 1.2, 1.8, 2.4].map { .init(start: $0, end: $0 + 0.1, text: "Frame") }, words: [], capture: nil)
        let (updates, continuation) = AsyncStream<Double>.makeStream()
        let task = Task { try await RecordingAgentPromptWriter.write(movie: movie, plan: plan, to: directory) { continuation.yield($0) } }
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled export completed") }
        catch is CancellationError { }
        continuation.finish()
        #expect(try String(contentsOf: prior, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["fixture.mov", "prior.txt"])
    }

    private func sample(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96 && image.height == 64)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let one = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB), size: .init(width: 96, height: 64))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            var pixels = try CVMutablePixelBuffer(attributes)
            try pixels.accessUnsafeMutableRawPlaneBytes { planes in
                let plane = try #require(planes.first)
                let context = try #require(CGContext(data: plane.bytes.baseAddress, width: 96, height: 64,
                    bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
                context.setFillColor(frame < 10 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
