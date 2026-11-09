import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Export Steps: a guide or a bug report from Agent Prompt's moments.
struct RecordingStepsTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// Over the 3 s red/blue movie, 0.6 s apart: a click and ⌘S, a 0.8 s rest, a double-click, a scroll, then narration.
    private func plan(narration: String = "The dialog stays empty", logs: RecordingAppLogs? = nil,
                      timeline: RecordingClipTimeline = .full(sourceDuration: 3)) -> RecordingAgentPromptPlan {
        RecordingAgentPromptPlan(
            title: "Save fails", timeline: timeline,
            cues: [.init(start: 2.5, end: 2.9, text: narration)], words: [],
            capture: PointerCaptureFile(
                // Steps of 0.04 every 0.3 s are moves; 0.7–1.5 s holds still.
                travel: [(0, 0.25), (0.3, 0.29), (0.7, 0.33), (1.5, 0.34), (1.8, 0.38), (2.1, 0.42), (2.4, 0.46), (2.7, 0.5)]
                    .map { PointerTravelSample(time: $0.0, x: $0.1, y: 0.5) },
                presses: [
                    .init(time: 0.1, x: 0.25, y: 0.5, button: 0, phase: .down),
                    .init(time: 1.3, x: 0.5, y: 0.5, button: 0, phase: .down),
                    .init(time: 1.45, x: 0.5, y: 0.5, button: 0, phase: .down),
                ],
                keystrokes: [.init(time: 0.2, modifiers: ["⌘"], key: "S")],
                scrolls: [PointerScrollEvent(time: 1.9, x: 0.5, y: 0.5, dx: 0, dy: -20)]),
            source: CaptureSource(bundleIdentifier: "com.example.Notes", appName: "Notes", windowTitle: "Draft", appVersion: "2.1 (210)"),
            screen: .init(width: 96, height: 64, scale: 2), logs: logs)
    }

    private func logs(_ entries: [RecordingAppLogs.Entry]) -> RecordingAppLogs { RecordingAppLogsTests.logs(entries) }

    @Test func eachMomentBecomesAStepWordedForPeople() {
        let steps = RecordingSteps(plan: plan(), systemVersion: "Version 27.3 (Build 27D60)")
        #expect(steps.steps.map(\.action) == ["Click, then press ⌘S", "Hover for 0.8 s", "Double-click", "Scroll down", ""])
        #expect(steps.steps.map(\.time) == [0.1, 0.7, 1.3, 1.9, 2.5])
        // A bug report leaves out the step that was only a rest, and keeps each step's own still.
        #expect(steps.listed(.bugReport).map(\.step.action) == ["Click, then press ⌘S", "Double-click", "Scroll down", ""])
        #expect(steps.listed(.bugReport).map(\.still) == [0, 2, 3, 4])
        #expect(steps.listed(.guide).map(\.still) == [0, 1, 2, 3, 4])
        #expect(steps.steps.last?.narration == "The dialog stays empty")
        #expect(RecordingSteps.sentence(["Right-click", "Scroll up", "Scroll up", "Scroll up"]) == "Right-click, then scroll up ×3")
        #expect(steps.environment == ["App: Notes 2.1 (210) (com.example.Notes)", "macOS: Version 27.3 (Build 27D60)", "Screen: 96 × 64 px at 2x"])
        let unknown = RecordingSteps(plan: RecordingAgentPromptPlan(title: "Bare", timeline: .full(sourceDuration: 3), cues: [], words: [], capture: nil),
                                     systemVersion: nil)
        #expect(unknown.environment == ["App: not recorded", "macOS: not recorded"])
    }

    /// Like a real take: a click, Pause on the bar, narration over a rest, then a rest on Stop and its click,
    /// released as the take ends. The Stop click isn't marked, as in recordings made before the mark.
    @Test func recordingBarClicksAndTheStopClickAreNotSteps() {
        let plan = RecordingAgentPromptPlan(
            title: "Bar", timeline: .full(sourceDuration: 12),
            cues: [.init(start: 7.8, end: 9.3, text: "It should be this")], words: [],
            capture: PointerCaptureFile(
                travel: [(0, 0.2, 0.5), (7.9, 0.28, 0.37), (9.4, 0.29, 0.37), (11.3, 0.56, 0.94)]
                    .map { PointerTravelSample(time: $0.0, x: $0.1, y: $0.2) },
                presses: [
                    .init(time: 2, x: 0.2, y: 0.5, button: 0, phase: .down),
                    .init(time: 2.1, x: 0.2, y: 0.5, button: 0, phase: .up),
                    .init(time: 5, x: 0.6, y: 0.94, button: 0, phase: .down, onRecordingBar: true),
                    .init(time: 11.9, x: 0.56, y: 0.936, button: 0, phase: .down),
                    .init(time: 11.96, x: 0.56, y: 0.936, button: 0, phase: .up),
                ]))
        let prompt = plan.markdown(frameTimes: [])
        #expect(prompt.contains("Click 00:02.000"))
        #expect(!prompt.contains("Click 00:05.000") && !prompt.contains("Click 00:11.900"))
        #expect(prompt.contains("Pointer rested 00:07.900"))
        #expect(!prompt.contains("Pointer rested 00:11.300"))
        // The bug report words the rest under narration as the narration alone.
        let report = RecordingSteps(plan: plan, systemVersion: nil).markdown(.bugReport)
        #expect(report.contains("## Steps to reproduce\n\n1. Click (00:02.000; image 1)\n2. “It should be this” (00:07.800; image 2)\n\n"))
        // A click released early is still a step, whatever comes last.
        let early = RecordingAgentPromptPlan(title: "Early", timeline: .full(sourceDuration: 12), cues: [], words: [],
            capture: PointerCaptureFile(presses: [.init(time: 11, x: 0.5, y: 0.5, button: 0, phase: .down),
                                                  .init(time: 11.1, x: 0.5, y: 0.5, button: 0, phase: .up)]))
        #expect(early.markdown(frameTimes: []).contains("Click 00:11.000"))
    }

    @Test func bothFormatsWriteMarkdownHTMLAndOneStillPerStep() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await RecordingAgentPromptTests().makeMovie(at: movie)
        let plan = plan()
        let stills = try await RecordingSteps.stills(plan: plan, master: movie)
        #expect(stills.count == plan.moments.count)
        let steps = RecordingSteps(plan: plan, systemVersion: "Version 27.3 (Build 27D60)")

        let guide = try steps.write(.guide, stills: stills, to: directory.appendingPathComponent("Guide"))
        let guideText = try String(contentsOf: guide.appendingPathComponent("steps.md"), encoding: .utf8)
        #expect(guideText.hasPrefix("# Save fails\n\n## Step 1 · 00:00.100\n\n**Click, then press ⌘S.**\n\n![Step 1 at 00:00.100](images/0001.jpg)"))
        #expect(guideText.contains("## Step 5 · 00:02.500\n\nThe dialog stays empty\n\n![Step 5 at 00:02.500](images/0005.jpg)"))
        let images = try FileManager.default.contentsOfDirectory(atPath: guide.appendingPathComponent("images").path).sorted()
        #expect(images == (0..<5).map(RecordingAgentPromptPlan.stillName))
        let first = try Data(contentsOf: guide.appendingPathComponent("images/0001.jpg"))
        let image = try #require(CGImageSourceCreateWithData(first as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 96 && image.height == 64)
        #expect(try FileManager.default.contentsOfDirectory(atPath: guide.path).sorted() == ["images", "steps.html", "steps.md"])

        let report = try steps.write(.bugReport, stills: stills, to: directory.appendingPathComponent("Report"))
        let reportText = try String(contentsOf: report.appendingPathComponent("steps.md"), encoding: .utf8)
        #expect(reportText.contains("## Environment\n\n- App: Notes 2.1 (210) (com.example.Notes)\n- macOS: Version 27.3 (Build 27D60)\n- Screen: 96 × 64 px at 2x"))
        #expect(reportText.contains("## Steps to reproduce\n\n1. Click, then press ⌘S (00:00.100; image 1)\n2. Double-click (00:01.300; image 2)"))
        #expect(reportText.contains("4. “The dialog stays empty” (00:02.500; image 4)"))
        #expect(!reportText.contains("Hover"))
        #expect(reportText.contains("![Image 2: step 2 at 00:01.300](images/0002.jpg)"))
        let reportImages = try FileManager.default.contentsOfDirectory(atPath: report.appendingPathComponent("images").path).sorted()
        #expect(reportImages == (0..<4).map(RecordingAgentPromptPlan.stillName))
        // Image 2 is the double-click's still, the third moment's.
        #expect(try Data(contentsOf: report.appendingPathComponent("images/0002.jpg")) == stills[2])
        #expect(reportText.contains("## What happened\n\n- 00:02.500–00:02.900: The dialog stays empty"))
        #expect(reportText.contains("## Attachments\n\n![Image 1: step 1 at 00:00.100](images/0001.jpg)"))
        #expect(!reportText.contains("## Logs") && !FileManager.default.fileExists(atPath: report.appendingPathComponent("logs.txt").path))
        // Nothing staged is left beside the folders.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["Guide", "Report", "fixture.mov"])
        do { _ = try steps.write(.guide, stills: stills, to: guide); Issue.record("Wrote over an existing folder") } catch { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["Guide", "Report", "fixture.mov"])
    }

    @Test func theHTMLPageNeedsNothingBesideIt() throws {
        let stills = (0..<5).map { Data("jpeg \($0)".utf8) }
        let steps = RecordingSteps(plan: plan(logs: logs([.init(time: 1, level: .error, subsystem: "com.example", category: "io", message: "Disk full")])),
                                   systemVersion: nil)
        for format in RecordingSteps.Format.allCases {
            let html = steps.html(format, stills: stills)
            for reference in ["src=\"http", "href=", "<script", "<link", "url(", "@import", "<iframe"] {
                #expect(!html.contains(reference), "\(format): \(reference)")
            }
            let sources = html.components(separatedBy: "src=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
            let shown = steps.listed(format).map { stills[$0.still] }
            #expect(sources.count == shown.count)
            #expect(sources.allSatisfy { $0.hasPrefix("data:image/jpeg;base64,") })
            #expect(sources.compactMap { Data(base64Encoded: String($0.dropFirst("data:image/jpeg;base64,".count))) } == shown)
        }
        // The bug report carries the whole log inline, too.
        #expect(steps.html(.bugReport, stills: stills).contains("<details><summary>The whole log (logs.txt)</summary><pre>Notes (com.example.Notes), process 42"))
        #expect(!steps.html(.guide, stills: stills).contains("<details>"))
    }

    @Test func narrationIsEscapedForMarkdownAndHTML() {
        let tricky = "Click *Save* <script>alert(1)</script> | # [link](x) _now_ & `code`\nnext"
        let steps = RecordingSteps(plan: plan(narration: tricky), systemVersion: nil)
        let markdown = steps.markdown(.guide)
        #expect(markdown.contains("Click \\*Save\\* &lt;script&gt;alert(1)&lt;/script&gt; \\| \\# \\[link\\](x) \\_now\\_ &amp; \\`code\\` next"))
        #expect(!markdown.contains("<script>"))
        let html = steps.html(.bugReport, stills: [])
        #expect(html.contains("Click *Save* &lt;script&gt;alert(1)&lt;/script&gt; | # [link](x) _now_ &amp; `code`"))
        #expect(!html.contains("<script>"))
        let titled = RecordingSteps(plan: RecordingAgentPromptPlan(title: "A <b>\"title\"</b>\n#1", timeline: .full(sourceDuration: 3),
                                                                  cues: [], words: [], capture: nil), systemVersion: nil)
        #expect(titled.markdown(.guide).hasPrefix("# A &lt;b&gt;\"title\"&lt;/b&gt; \\#1\n\n"))
        #expect(titled.html(.guide, stills: []).contains("<title>A &lt;b&gt;&quot;title&quot;&lt;/b&gt; #1 · Guide</title>"))
    }

    @Test func copyAsMarkdownNamesTheLocalFilesAndAHookedSummaryLeads() {
        let folder = URL(fileURLWithPath: "/tmp/Save fails Bug Report", isDirectory: true)
        let steps = RecordingSteps(plan: plan(logs: logs([])), systemVersion: nil, summary: "  Saving shows an empty dialog.  ")
        let copied = steps.markdown(.bugReport, localFolder: folder)
        #expect(copied.hasPrefix("# Save fails\n\n> The images and logs.txt are local files in `/tmp/Save fails Bug Report`: attach them by hand.\n\n## Summary\n\nSaving shows an empty dialog.\n\n"))
        #expect(!copied.contains("!["))
        #expect(copied.contains("Image 1: step 1 at 00:00.100: `images/0001.jpg`"))
        #expect(RecordingSteps(plan: plan(), systemVersion: nil).markdown(.guide, localFolder: folder).contains("> The images are local files"))
        #expect(!RecordingSteps(plan: plan(), systemVersion: nil).markdown(.guide).contains("## Summary"))
    }

    @Test func theBugReportAttachesTheTakesLogAndTheGuideDoesNot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("fixture.mov")
        try await RecordingAgentPromptTests().makeMovie(at: movie)
        let captured = logs([.init(time: 2, level: .error, subsystem: "com.example.Notes", category: "store", message: "Save failed")])
        let withLogs = plan(logs: captured)
        let stills = try await RecordingSteps.stills(plan: withLogs, master: movie)
        let report = try RecordingSteps(plan: withLogs, systemVersion: nil).write(.bugReport, stills: stills, to: directory.appendingPathComponent("Report"))
        #expect(try String(contentsOf: report.appendingPathComponent("logs.txt"), encoding: .utf8) == captured.text(timeline: withLogs.timeline))
        let text = try String(contentsOf: report.appendingPathComponent("steps.md"), encoding: .utf8)
        #expect(text.contains("## Logs\n\nNotes's unified log while the recording ran (process 42): 1 line: 1 error, 0 faults, 0 default-level."))
        #expect(text.contains("- 00:02.000 \\[00:02.000\\]: error, com.example.Notes: Save failed\n\nThe whole log: `logs.txt`.\n\n## Attachments"))
        // Left out in the sheet, or a guide: no section and no file.
        let leftOut = try RecordingSteps(plan: withLogs, systemVersion: nil, includesLogs: false)
            .write(.bugReport, stills: stills, to: directory.appendingPathComponent("No logs"))
        #expect(!FileManager.default.fileExists(atPath: leftOut.appendingPathComponent("logs.txt").path))
        #expect(!(try String(contentsOf: leftOut.appendingPathComponent("steps.md"), encoding: .utf8)).contains("## Logs"))
        let guide = try RecordingSteps(plan: withLogs, systemVersion: nil).write(.guide, stills: stills, to: directory.appendingPathComponent("Guide"))
        #expect(!FileManager.default.fileExists(atPath: guide.appendingPathComponent("logs.txt").path))
        #expect(!(try String(contentsOf: guide.appendingPathComponent("steps.md"), encoding: .utf8)).contains("## Logs"))
    }
}

