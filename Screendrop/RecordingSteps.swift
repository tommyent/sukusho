import AVFoundation
import Foundation

/// Export Steps: the moments Agent Prompt finds (clicks, shortcuts, pointer rests, scrolls,
/// pen strokes and narration), written for people as a guide or a bug report, in Markdown
/// and a self-contained HTML page. Narration is used as transcribed; nothing is rewritten.
nonisolated struct RecordingSteps: Sendable {
    enum Format: String, CaseIterable, Sendable {
        case guide
        case bugReport

        var title: String { self == .guide ? "Guide" : "Bug Report" }
    }

    struct Step: Sendable, Equatable {
        var time: Double
        /// What was done, as one sentence ("Click, then press ⌘S"); empty when the moment is only narration.
        var action: String
        /// The same without pointer rests: what a bug report's Steps to reproduce lists.
        var reproduction: String
        /// What was said at the moment, as transcribed.
        var narration: String
    }

    let title: String
    let steps: [Step]
    let narration: [RecordingAgentPromptPlan.Text]
    let transcriptionFailure: String?
    let environment: [String]
    let logs: RecordingAppLogs?
    let timeline: RecordingClipTimeline
    /// Leads both formats under "Summary" when set. Hook for an on-device summary
    /// (gallery-app is adding one to Studio); nil writes none.
    let summary: String?

    /// `systemVersion` is the macOS the take was recorded on, when the manifest kept it.
    init(plan: RecordingAgentPromptPlan, systemVersion: String?, includesLogs: Bool = true, summary: String? = nil) {
        title = plan.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        steps = plan.moments.map { moment in
            var actions: [String] = [], reproduction: [String] = [], said: [String] = []
            for part in moment.parts {
                switch part {
                case .did(let action): actions.append(action); reproduction.append(action)
                case .rested(let action): actions.append(action)
                case .said(let text): said.append(text)
                }
            }
            return Step(time: moment.time, action: Self.sentence(actions), reproduction: Self.sentence(reproduction),
                        narration: said.joined(separator: " "))
        }
        narration = plan.transcript
        transcriptionFailure = plan.transcriptionFailure
        var environment: [String] = []
        if let source = plan.source {
            environment.append("App: \(source.appName)" + (source.appVersion.map { " \($0)" } ?? "")
                + (source.bundleIdentifier.map { " (\($0))" } ?? ""))
        } else {
            environment.append("App: not recorded")
        }
        environment.append("macOS: " + (systemVersion ?? "not recorded"))
        if let screen = plan.screen {
            environment.append(String(format: "Screen: %d × %d px at %gx", locale: Locale(identifier: "en_US_POSIX"),
                                      screen.width, screen.height, screen.scale))
        }
        self.environment = environment
        logs = includesLogs ? plan.logs : nil
        timeline = plan.timeline
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// One sentence for a moment's actions: repeats collapse ("Double-click", "Scroll down ×3"),
    /// and later ones follow "then".
    static func sentence(_ actions: [String]) -> String {
        var runs: [(action: String, count: Int)] = []
        for action in actions {
            if runs.last?.action == action { runs[runs.count - 1].count += 1 } else { runs.append((action, 1)) }
        }
        let phrases = runs.map { run in
            run.count == 1 ? run.action : run.action == "Click" && run.count == 2 ? "Double-click" : "\(run.action) ×\(run.count)"
        }
        return phrases.enumerated().map { index, phrase in
            index == 0 ? phrase : phrase.prefix(1).lowercased() + phrase.dropFirst()
        }.joined(separator: ", then ")
    }

    // MARK: - Content

    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case strong(String)
        case list([String], numbered: Bool)
        /// A listed step's still, by its place in `listed(format)`.
        case image(Int, alt: String)
        /// The whole log: inline in HTML, a pointer to `logs.txt` in Markdown.
        case log
    }

    private static func time(_ value: Double) -> String { RecordingAgentPromptPlan.timestamp(value) }

    /// The steps a format lists, each with the index of its still. A bug report words steps
    /// without pointer rests and leaves out the steps that were only a rest.
    func listed(_ format: Format) -> [(step: Step, still: Int)] {
        steps.indices.compactMap { index in
            var step = steps[index]
            if format == .bugReport {
                if step.reproduction.isEmpty, !step.action.isEmpty, step.narration.isEmpty { return nil }
                step.action = step.reproduction
            }
            return (step, index)
        }
    }

    func blocks(_ format: Format) -> [Block] {
        let steps = listed(format).map(\.step)
        var blocks: [Block] = []
        if let summary { blocks += [.heading("Summary"), .paragraph(summary)] }
        switch format {
        case .guide:
            for (index, step) in steps.enumerated() {
                blocks.append(.heading("Step \(index + 1) · \(Self.time(step.time))"))
                if !step.action.isEmpty { blocks.append(.strong(step.action + ".")) }
                if !step.narration.isEmpty { blocks.append(.paragraph(step.narration)) }
                blocks.append(.image(index, alt: "Step \(index + 1) at \(Self.time(step.time))"))
            }
        case .bugReport:
            blocks += [.heading("Environment"), .list(environment, numbered: false)]
            blocks += [.heading("Steps to reproduce"), .list(steps.enumerated().map { index, step in
                let what = step.action.isEmpty ? (step.narration.isEmpty ? "(nothing recorded)" : "“\(step.narration)”") : step.action
                return "\(what) (\(Self.time(step.time)); image \(index + 1))"
            }, numbered: true)]
            blocks.append(.heading("What happened"))
            if narration.isEmpty {
                blocks.append(.paragraph(transcriptionFailure.map { "The narration couldn't be transcribed: \($0)" } ?? "No narration was recorded."))
            } else {
                blocks.append(.list(narration.map { "\(Self.time($0.start))–\(Self.time($0.end)): \($0.text)" }, numbered: false))
            }
            if let logs {
                let summary = logs.summary(timeline: timeline)
                blocks += [.heading("Logs"), .paragraph(summary.text)]
                if !summary.firstProblems.isEmpty { blocks.append(.list(summary.firstProblems, numbered: false)) }
                blocks.append(.log)
            }
            blocks.append(.heading("Attachments"))
            blocks += steps.indices.map { .image($0, alt: "Image \($0 + 1): step \($0 + 1) at \(Self.time(steps[$0].time))") }
        }
        return blocks
    }

    static func imagePath(_ index: Int) -> String { "images/" + RecordingAgentPromptPlan.stillName(index) }

    /// `steps.md`. With `localFolder`, it's the text Copy as Markdown puts on the clipboard:
    /// images are named, not embedded, under a note that they're files in that folder.
    func markdown(_ format: Format, localFolder: URL? = nil) -> String {
        let escape = RecordingAgentPromptPlan.escape
        var text = "# \(escape(title))\n\n"
        if let localFolder {
            let files = logs != nil && format == .bugReport ? "The images and \(RecordingAppLogs.exportFileName) are" : "The images are"
            text += "> \(files) local files in `\(localFolder.path.replacingOccurrences(of: "`", with: "'"))`: attach them by hand.\n\n"
        }
        for block in blocks(format) {
            switch block {
            case .heading(let value): text += "## \(escape(value))\n\n"
            case .paragraph(let value): text += escape(value) + "\n\n"
            case .strong(let value): text += "**\(escape(value))**\n\n"
            case .list(let items, let numbered):
                text += items.enumerated().map { (numbered ? "\($0 + 1). " : "- ") + escape($1) }.joined(separator: "\n") + "\n\n"
            case .image(let index, let alt):
                text += localFolder == nil ? "![\(escape(alt))](\(Self.imagePath(index)))\n\n" : "\(escape(alt)): `\(Self.imagePath(index))`\n\n"
            case .log: text += "The whole log: `\(RecordingAppLogs.exportFileName)`.\n\n"
            }
        }
        return text
    }

    /// `steps.html`, which needs nothing beside it: `stills` (one JPEG per step) are embedded.
    func html(_ format: Format, stills: [Data]) -> String {
        let listed = listed(format)
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        var body = "<h1>\(escape(title))</h1>\n"
        for block in blocks(format) {
            switch block {
            case .heading(let value): body += "<h2>\(escape(value))</h2>\n"
            case .paragraph(let value): body += "<p>\(escape(value))</p>\n"
            case .strong(let value): body += "<p><strong>\(escape(value))</strong></p>\n"
            case .list(let items, let numbered):
                let tag = numbered ? "ol" : "ul"
                body += "<\(tag)>\n" + items.map { "<li>\(escape($0))</li>\n" }.joined() + "</\(tag)>\n"
            case .image(let index, let alt):
                guard listed.indices.contains(index), stills.indices.contains(listed[index].still) else {
                    body += "<p class=\"muted\">\(escape(alt)): frame unavailable.</p>\n"; continue
                }
                body += "<figure><img src=\"data:image/jpeg;base64,\(stills[listed[index].still].base64EncodedString())\" alt=\"\(escape(alt))\">"
                    + "<figcaption>\(escape(alt))</figcaption></figure>\n"
            case .log:
                guard let logs else { continue }
                body += "<details><summary>The whole log (\(escape(RecordingAppLogs.exportFileName)))</summary><pre>"
                    + escape(logs.text(timeline: timeline)) + "</pre></details>\n"
            }
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title)) · \(format.title)</title>
        <style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --line: #d2d2d7; }
        @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1c1c1e; --line: #3a3a3c; } }
        body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        main { max-width: 960px; margin: 0 auto; padding: 32px 16px 64px; }
        h1 { font-size: 28px; line-height: 1.2; margin: 0 0 8px; }
        h2 { font-size: 20px; margin: 32px 0 8px; }
        figure { margin: 12px 0 24px; }
        img { display: block; max-width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; }
        figcaption, .muted { color: var(--muted); font-size: 14px; margin-top: 6px; }
        pre { overflow: auto; font: 12px/1.45 ui-monospace, Menlo, monospace; padding: 12px; border: 1px solid var(--line); border-radius: 8px; }
        summary { cursor: pointer; }
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>

        """
    }

    // MARK: - Files

    enum ExportError: LocalizedError {
        case invalidMovie
        case unavailableFrame(Double)

        var errorDescription: String? {
            switch self {
            case .invalidMovie: "The screen recording could not be read."
            case .unavailableFrame(let time): "No frame could be extracted at \(RecordingAgentPromptPlan.timestamp(time))."
            }
        }
    }

    /// Each moment's still from the screen recording, pointer ringed and pen strokes drawn,
    /// as Agent Prompt makes them, without its strips.
    @concurrent
    static func stills(plan: RecordingAgentPromptPlan, master: URL,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Data] {
        guard let frames = await RecordingAgentPromptWriter.MasterFrames(url: master) else { throw ExportError.invalidMovie }
        defer { frames.stillGenerator.cancelAllCGImageGeneration() }
        var stills: [Data] = []
        for (index, moment) in plan.moments.enumerated() {
            try Task.checkCancellation()
            guard let image = await frames.still(for: moment, plan: plan) else { throw ExportError.unavailableFrame(moment.time) }
            stills.append(try RecordingAgentPromptWriter.Rendered(still: image, strip: nil).still)
            progress(Double(index + 1) / Double(plan.moments.count))
        }
        return stills
    }

    /// Writes `steps.md`, `steps.html`, `images/` and, for a bug report with logs, `logs.txt`
    /// into a new folder at `destination`, which must not exist yet. Nothing is left on failure.
    func write(_ format: Format, stills: [Data], to destination: URL) throws -> URL {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".steps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (index, item) in listed(format).enumerated() where stills.indices.contains(item.still) {
            try stills[item.still].write(to: staging.appendingPathComponent(Self.imagePath(index)))
        }
        try markdown(format).write(to: staging.appendingPathComponent("steps.md"), atomically: true, encoding: .utf8)
        try html(format, stills: stills).write(to: staging.appendingPathComponent("steps.html"), atomically: true, encoding: .utf8)
        if format == .bugReport, let logs {
            try logs.text(timeline: timeline).write(to: staging.appendingPathComponent(RecordingAppLogs.exportFileName),
                                                    atomically: true, encoding: .utf8)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
