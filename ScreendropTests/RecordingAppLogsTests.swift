import Foundation
import Testing

/// A Bug report take's app log: placed on the recording, bounded, and written into its Agent Prompt.
struct RecordingAppLogsTests {
    /// Notes' log, process 42, with `entries` as given.
    static func logs(_ entries: [RecordingAppLogs.Entry]) -> RecordingAppLogs {
        var logs = RecordingAppLogs(span: .init(processIdentifier: 42, appName: "Notes", bundleIdentifier: "com.example.Notes", start: 0, duration: 3),
                                    lines: [RecordingAppLogs.Line]())
        logs.entries = entries
        return logs
    }

    @Test func logLinesArePlacedOnTheRecordingWithoutPausesOrOutsideTime() {
        // First frame at Unix 1000; a 2 s pause from 1003 to 1005; 10 s of recording, so the take ends at 1012.
        let span = RecordingAppLogs.Span(processIdentifier: 7, appName: "Notes", bundleIdentifier: nil, start: 1000, duration: 10,
                                         pauses: [1003...1005])
        #expect(span.end == 1012)
        let logs = RecordingAppLogs(span: span, lines: [999.5, 1002, 1004, 1006.5, 1012.5].map {
            RecordingAppLogs.Line(date: Date(timeIntervalSince1970: $0), level: .error, subsystem: "s", category: "c", message: "m\($0)")
        })
        #expect(logs.entries.map(\.time) == [2, 4.5])
        #expect(logs.entries.map(\.message) == ["m1002.0", "m1006.5"])
    }

    @Test func logLimitsKeepProblemsAndCapDefaultLinesAndLongMessages() {
        let span = RecordingAppLogs.Span(processIdentifier: 7, appName: "Notes", bundleIdentifier: nil, start: 0, duration: 100)
        let chatter = (0..<(RecordingAppLogs.maxDefault + 500)).map {
            RecordingAppLogs.Line(date: Date(timeIntervalSince1970: Double($0) / 100), level: .default, subsystem: "s", category: "", message: "line \($0)")
        }
        let late = [RecordingAppLogs.Line(date: Date(timeIntervalSince1970: 50), level: .fault, subsystem: "s", category: "", message: String(repeating: "x", count: 5_000)),
                    RecordingAppLogs.Line(date: Date(timeIntervalSince1970: 1), level: .error, subsystem: "s", category: "", message: "early error")]
        let logs = RecordingAppLogs(span: span, lines: chatter + late)
        #expect(logs.count(.default) == RecordingAppLogs.maxDefault)
        #expect(logs.count(.fault) == 1 && logs.count(.error) == 1)
        #expect(logs.omitted == 500)
        #expect(logs.entries.first { $0.level == .fault }?.message.count == RecordingAppLogs.maxMessage + 1)
        #expect(logs.entries.map(\.time) == logs.entries.map(\.time).sorted())
        #expect(logs.countsLine == "1002 lines: 1 error, 1 fault, 1000 default-level. 500 more over the limits were left out.")
        let problems = (0..<(RecordingAppLogs.maxProblems + 3)).map {
            RecordingAppLogs.Line(date: Date(timeIntervalSince1970: 1), level: .error, subsystem: "s", category: "", message: "\($0)")
        }
        #expect(RecordingAppLogs(span: span, lines: problems).entries.count == RecordingAppLogs.maxProblems)
    }

    @Test func thePromptGetsALogsSectionAndLogsTxtOnTheEditedTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await RecordingAgentPromptTests().makeMovie(at: movie)
        // 0.5–1.5 s is cut, so source 2 s is edited 1 s and source 1 s has no edited time.
        let timeline = RecordingClipTimeline(segments: [.init(sourceStart: 0, sourceEnd: 0.5), .init(sourceStart: 1.5, sourceEnd: 3)])
        let captured = Self.logs([
            .init(time: 0.2, level: .default, subsystem: "com.example.Notes", category: "ui", message: "Opened\nthe sheet"),
            .init(time: 1, level: .fault, subsystem: "com.example.Notes", category: "store", message: "Cut fault"),
            .init(time: 2, level: .error, subsystem: "com.example.Notes", category: "store", message: "Save failed: <disk> *full*"),
        ])
        func plan(logs: RecordingAppLogs?) -> RecordingAgentPromptPlan {
            RecordingAgentPromptPlan(title: "Save fails", timeline: timeline, cues: [], words: [],
                                     capture: PointerCaptureFile(presses: [.init(time: 2, x: 0.5, y: 0.5, button: 0, phase: .down)]), logs: logs)
        }
        let markdown = plan(logs: captured).markdown(frameTimes: [])
        #expect(markdown.contains("## Logs\n\nNotes's unified log while the recording ran (process 42): 3 lines: 1 error, 1 fault, 1 default-level."))
        let cut = "cut" + String(repeating: " ", count: 7)
        #expect(markdown.contains("- \(cut)\\[00:01.000\\]: fault, com.example.Notes: Cut fault\n- 00:01.000 \\[00:02.000\\]: error, com.example.Notes: Save failed: &lt;disk&gt; \\*full\\*"))
        let folder = try await RecordingAgentPromptWriter.write(movie: nil, plan: plan(logs: captured), to: directory, master: movie)
        let text = try String(contentsOf: folder.appendingPathComponent("logs.txt"), encoding: .utf8)
        #expect(text == captured.text(timeline: timeline))
        #expect(text.hasPrefix("Notes (com.example.Notes), process 42: its unified log while the recording ran.\n"))
        #expect(text.contains("00:00.200 [00:00.200]  default  com.example.Notes (ui)  Opened\n    the sheet\n"))
        #expect(text.contains("\(cut)[00:01.000]  fault    com.example.Notes (store)  Cut fault\n"))
        #expect(text.contains("00:01.000 [00:02.000]  error    com.example.Notes (store)  Save failed: <disk> *full*\n"))
        // With logs off there's no section and no file.
        let without = try await RecordingAgentPromptWriter.write(movie: nil, plan: plan(logs: nil), to: directory, name: "Off", master: movie)
        #expect(!(try String(contentsOf: without.appendingPathComponent("prompt.md"), encoding: .utf8)).contains("## Logs"))
        #expect(!FileManager.default.fileExists(atPath: without.appendingPathComponent("logs.txt").path))
    }

    @Test func anEmptyOrUnreadableLogSaysSo() {
        let span = RecordingAppLogs.Span(processIdentifier: 9, appName: "Notes", bundleIdentifier: nil, start: 0, duration: 3)
        let failed = RecordingAppLogs(span: span, lines: [RecordingAppLogs.Line](), failure: "Operation not permitted")
        #expect(failed.summary(timeline: .full(sourceDuration: 3)).text
                == "App logs were on for this take, but macOS didn't return Notes's log: Operation not permitted")
        #expect(failed.text(timeline: nil).contains("The log couldn't be read: Operation not permitted\n"))
        let quiet = RecordingAppLogs(span: span, lines: [RecordingAppLogs.Line]())
        #expect(quiet.summary(timeline: .full(sourceDuration: 3)).text == "Notes logged nothing at default level or above while the recording ran (process 9).")
        let calm = Self.logs([.init(time: 1, level: .default, subsystem: "s", category: "", message: "fine")])
        #expect(calm.summary(timeline: .full(sourceDuration: 3)).firstProblems == ["No errors or faults were logged."])
    }

    @Test func logsRoundTripThroughThePackage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(RecordingAppLogs.load(fromPackage: directory) == nil)
        let captured = Self.logs([.init(time: 1.25, level: .error, subsystem: "s", category: "c", message: "é ✓")])
        try captured.write(toPackage: directory)
        #expect(RecordingAppLogs.load(fromPackage: directory) == captured)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("app-logs.json").path))
    }

    @Test func includeAppLogsIsOffUntilChosen() {
        // Nothing in this process's defaults has chosen it.
        #expect(UserDefaults.standard.object(forKey: ScreendropPreferences.recordingAppLogsKey) == nil)
        #expect(!ScreendropPreferences.recordingAppLogs)
    }

    /// Logs leave the Mac only when the user shares an export: upload, share and agent code never reads them.
    /// A guard on the sources, since uploads can't run here: only these files may name the app log.
    @Test func noUploadOrShareCodeTouchesTheAppLog() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Screendrop", isDirectory: true)
        let names = try #require(FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String]).filter { $0.hasSuffix(".swift") }
        #expect(names.count > 100)
        let readers = try names.filter {
            let text = try String(contentsOf: sources.appendingPathComponent($0), encoding: .utf8)
            return text.contains("RecordingAppLogs") || text.contains("app-logs.json") || text.contains("appLogSpan")
        }.sorted()
        #expect(readers == ["RecordingAgentPromptExport.swift", "RecordingAgentPromptPlan.swift", "RecordingAgentPromptWriter.swift",
                            "RecordingAppLogs.swift", "RecordingAppLogsReview.swift", "RecordingSession.swift", "RecordingSteps.swift",
                            "ScreenRecordingManager.swift", "ScreendropApp.swift"])
    }
}
