import Foundation
import OSLog

/// A Bug report take's log of the app it recorded: the errors, faults and default-level
/// messages that app's own process wrote while the screen recording ran, on the recording's
/// clock. Read from the system log store after Stop, which needs no prompt and no admin
/// password for an admin account. It goes into the package as `app-logs.json` only once the
/// user has seen it and chosen to include it, and from there into Agent Prompts and Bug report
/// steps as `logs.txt`. Logs can hold personal data: this never goes into an upload.
nonisolated struct RecordingAppLogs: Codable, Sendable, Equatable {
    static let fileName = "app-logs.json"
    static let exportFileName = "logs.txt"
    /// Every error and fault up to `maxProblems`, default-level lines up to `maxDefault`, each message cut at `maxMessage` characters.
    static let maxProblems = 2_000
    static let maxDefault = 1_000
    static let maxMessage = 1_000

    enum Level: String, Codable, Sendable {
        case `default`, error, fault
    }

    struct Entry: Codable, Sendable, Equatable {
        /// Seconds on the screen recording's own clock.
        var time: Double
        var level: Level
        var subsystem: String
        var category: String
        var message: String
    }

    /// One message as the log store gives it, before it's placed on the recording.
    struct Line: Sendable {
        var date: Date
        var level: Level
        var subsystem: String
        var category: String
        var message: String
    }

    /// Whose log a take asked for, and when its screen recording ran.
    struct Span: Codable, Sendable, Equatable {
        var processIdentifier: Int32
        var appName: String
        var bundleIdentifier: String?
        /// Unix time of the screen recording's first frame. Seconds, not a Date:
        /// the capture manifest writes ISO dates, which drop fractions of a second.
        var start: Double
        var duration: Double
        /// Unix times of the pauses, in order; the screen recording leaves them out.
        var pauses: [ClosedRange<Double>] = []

        var end: Double { start + duration + pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

        /// Where `date` falls on the screen recording; nil before or after it, or in a pause.
        func sourceTime(of date: Date) -> Double? {
            let unix = date.timeIntervalSince1970
            var paused = 0.0
            for pause in pauses where pause.lowerBound < unix {
                if unix < pause.upperBound { return nil }
                paused += pause.upperBound - pause.lowerBound
            }
            let time = unix - start - paused
            return time >= 0 && time <= duration ? time : nil
        }
    }

    var appName: String
    var bundleIdentifier: String?
    var processIdentifier: Int32
    var entries: [Entry]
    /// Lines past the limits, left out.
    var omitted = 0
    /// Why the log couldn't be read, when it couldn't.
    var failure: String?

    /// Places `lines` on the recording and keeps what the limits allow, in time order.
    init(span: Span, lines: some Sequence<Line>, failure: String? = nil) {
        appName = span.appName
        bundleIdentifier = span.bundleIdentifier
        processIdentifier = span.processIdentifier
        self.failure = failure
        var entries: [Entry] = [], problems = 0, defaults = 0, omitted = 0
        for line in lines {
            guard let time = span.sourceTime(of: line.date) else { continue }
            let isDefault = line.level == .default
            guard isDefault ? defaults < Self.maxDefault : problems < Self.maxProblems else {
                omitted += 1
                continue
            }
            if isDefault { defaults += 1 } else { problems += 1 }
            let message = line.message.count > Self.maxMessage ? String(line.message.prefix(Self.maxMessage)) + "…" : line.message
            entries.append(Entry(time: time, level: line.level, subsystem: line.subsystem, category: line.category, message: message))
        }
        self.entries = entries.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        self.omitted = omitted
    }

    /// Reads the span's process from the system log store, from the recording's first frame to its end.
    /// A store that can't be opened or read gives an empty log with the reason.
    @concurrent
    static func collect(_ span: Span) async -> RecordingAppLogs {
        do {
            let store = try OSLogStore(scope: .system)
            let all = try store.getEntries(at: store.position(date: Date(timeIntervalSince1970: span.start)),
                                           matching: NSPredicate(format: "processIdentifier == %d", span.processIdentifier))
            let end = Date(timeIntervalSince1970: span.end)
            let lines = all.lazy.compactMap { $0 as? OSLogEntryLog }.prefix { $0.date <= end }.compactMap { entry -> Line? in
                let level: Level
                switch entry.level {
                case .notice: level = .default
                case .error: level = .error
                case .fault: level = .fault
                default: return nil
                }
                return Line(date: entry.date, level: level, subsystem: entry.subsystem, category: entry.category, message: entry.composedMessage)
            }
            return RecordingAppLogs(span: span, lines: lines)
        } catch {
            return RecordingAppLogs(span: span, lines: [], failure: error.localizedDescription)
        }
    }

    static func load(fromPackage directory: URL) -> RecordingAppLogs? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(RecordingAppLogs.self, from: data)
    }

    func write(toPackage directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    func count(_ level: Level) -> Int { entries.reduce(0) { $1.level == level ? $0 + 1 : $0 } }

    /// "42 lines: 3 errors, 1 fault, 38 default-level."
    var countsLine: String {
        func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
        var text = "\(plural(entries.count, "line")): \(plural(count(.error), "error")), \(plural(count(.fault), "fault")), \(count(.default)) default-level."
        if omitted > 0 { text += " \(omitted) more over the limits were left out." }
        return text
    }

    /// The edited time of a source time, or "cut" when an edit removed it; then the source time.
    private static func stamp(_ time: Double, timeline: RecordingClipTimeline?) -> String {
        let source = RecordingAgentPromptPlan.timestamp(time)
        guard let timeline else { return source }
        let kept = timeline.segments.contains { time >= $0.sourceStart && time < $0.sourceEnd }
        let edited = kept ? timeline.editorTime(forSourceTime: time).map(RecordingAgentPromptPlan.timestamp) : nil
        return "\(edited ?? "cut      ") [\(source)]"
    }

    /// `logs.txt`: a header, then one line per entry. With a timeline, times are the edited
    /// recording's, then the screen recording's own in brackets; without, the screen recording's.
    func text(timeline: RecordingClipTimeline?) -> String {
        var text = "\(appName)\(bundleIdentifier.map { " (\($0))" } ?? ""), process \(processIdentifier): its unified log while the recording ran.\n"
        if let failure { text += "The log couldn't be read: \(failure)\n" }
        text += countsLine + " Info and debug messages aren't included.\n"
        text += timeline == nil ? "Times are on the screen recording.\n\n"
            : "Times are on the edited recording, then the screen recording's own clock in brackets; \"cut\" marks a part that was cut.\n\n"
        for entry in entries {
            let source = entry.subsystem.isEmpty ? "-" : entry.subsystem + (entry.category.isEmpty ? "" : " (\(entry.category))")
            let message = entry.message.components(separatedBy: .newlines).joined(separator: "\n    ")
            text += "\(Self.stamp(entry.time, timeline: timeline))  \(entry.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(source)  \(message)\n"
        }
        return text
    }

    /// The Logs section of a prompt or bug report, as plain text: a sentence, then the first errors and faults.
    func summary(timeline: RecordingClipTimeline) -> (text: String, firstProblems: [String]) {
        if let failure, entries.isEmpty {
            return ("App logs were on for this take, but macOS didn't return \(appName)'s log: \(failure)", [])
        }
        guard !entries.isEmpty else {
            return ("\(appName) logged nothing at default level or above while the recording ran (process \(processIdentifier)).", [])
        }
        let text = "\(appName)'s unified log while the recording ran (process \(processIdentifier)): \(countsLine) Info and debug messages aren't included. "
            + "The whole log is in \(Self.exportFileName) beside this file, with times on the edited recording and the screen recording's own clock."
        let problems = entries.filter { $0.level != .default }.prefix(5).map { entry in
            let message = entry.message.count > 300 ? String(entry.message.prefix(300)) + "…" : entry.message
            return "\(Self.stamp(entry.time, timeline: timeline)): \(entry.level.rawValue), \(entry.subsystem.isEmpty ? "-" : entry.subsystem): \(message)"
        }
        return (text, problems.isEmpty ? ["No errors or faults were logged."] : problems)
    }
}
