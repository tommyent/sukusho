import Foundation
import FoundationModels

/// What Studio asks of Apple's on-device model. The app
/// uses `SystemTextModel`; tests use a fake.
nonisolated protocol OnDeviceTextModel: Sendable {
    /// Tokens a prompt and its answer share.
    var contextSize: Int { get }
    func tokenCount(_ text: String) async throws -> Int
    func reply(instructions: String, prompt: String) async throws -> String
}

/// Apple's on-device model. It runs on this Mac; nothing it's given or writes leaves it.
nonisolated struct SystemTextModel: OnDeviceTextModel {
    /// 8,192 on macOS 27.3 (measured 2026-11-09).
    var contextSize: Int { SystemLanguageModel.default.contextSize }

    func tokenCount(_ text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }

    /// One fresh session per prompt, so one recording never colours the next.
    func reply(instructions: String, prompt: String) async throws -> String {
        try await LanguageModelSession(instructions: instructions)
            .respond(to: prompt, options: GenerationOptions(temperature: 0.3)).content
    }
}

nonisolated enum OnDeviceText {
    /// Why the model can't write here, or nil when it can: the same
    /// availability and Settings switch the Library's titles use.
    @MainActor
    static func unavailableReason(
        _ availability: SystemLanguageModel.Availability = SystemLanguageModel.default.availability,
        settingOn: Bool = ScreendropPreferences.libraryUsesIntelligence
    ) -> String? {
        switch availability {
        case .available:
            return settingOn ? nil : "Turn on “Use Apple Intelligence” in Sukusho’s Settings › General to use this."
        case .unavailable(.deviceNotEligible):
            return "This Mac can’t run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Try again in a while."
        case .unavailable:
            return "Apple Intelligence isn’t available right now."
        }
    }

    /// What a failed request says; it never blocks anything else.
    static func message(for error: any Error) -> String {
        switch error as? LanguageModelError {
        case .rateLimited, .timeout: "Apple Intelligence is busy. Try again in a moment."
        case .guardrailViolation, .refusal: "Apple Intelligence declined to write this."
        case .unsupportedLanguageOrLocale: "Apple Intelligence doesn’t support this language yet."
        default: "Apple Intelligence couldn’t write this: \(error.localizedDescription)"
        }
    }

    /// Room left for the text itself: the context less the instructions, the
    /// prompt's framing and the answer.
    static func inputBudget(_ model: some OnDeviceTextModel, instructions: String) async throws -> Int {
        max(64, model.contextSize - (try await model.tokenCount(instructions)) - reservedTokens)
    }

    static let reservedTokens = 800

    /// Splits lines into runs whose text fits `budget` tokens, halving until
    /// each does; a single line too long is split between its words.
    static func chunks(of lines: [String], budget: Int, model: some OnDeviceTextModel) async throws -> [[String]] {
        guard !lines.isEmpty else { return [] }
        if try await model.tokenCount(lines.joined(separator: "\n")) <= budget { return [lines] }
        if lines.count == 1 {
            let words = lines[0].split(whereSeparator: \.isWhitespace)
            // shortcut: one word longer than the budget is cut by characters; real narration never has one.
            guard words.count > 1 else { return [[String(lines[0].prefix(budget * 2))]] }
            let half = words.count / 2
            return try await chunks(of: [words[..<half].joined(separator: " ")], budget: budget, model: model)
                + chunks(of: [words[half...].joined(separator: " ")], budget: budget, model: model)
        }
        let half = lines.count / 2
        return try await chunks(of: Array(lines[..<half]), budget: budget, model: model)
            + chunks(of: Array(lines[half...]), budget: budget, model: model)
    }

    /// One plain paragraph: no markdown, quotes or list markers.
    static func plain(_ text: String, limit: Int) -> String {
        let lines = text.components(separatedBy: .newlines).map { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#*-•>".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        }
        var joined = lines.split(separator: "", omittingEmptySubsequences: true)
            .map { $0.joined(separator: " ") }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = joined.first, let last = joined.last, joined.count > 1, "\"“'".contains(first), "\"”'".contains(last) {
            joined = String(joined.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Summary and chapter titles.
nonisolated enum RecordingTextIntelligence {
    /// The Worker takes up to 2,000 characters.
    static let summaryLimit = 2000

    static let summaryInstructions = """
        You write the short summary shown under a screen recording on its share page. \
        You are given what the narrator said, sometimes split into chapters, and sometimes the app it was recorded in. \
        Write two to four plain sentences saying what the recording shows and explains, in the language of the narration. \
        Describe only what the narration supports; never invent names, numbers or steps. No headings, lists, markdown or quotes.
        """

    static let notesInstructions = """
        You take notes on one part of a screen recording's narration, to be combined with notes on the other parts. \
        Write up to four plain sentences about what this part shows and explains, in the language of the narration. \
        Only what it says; never invent names, numbers or steps. No headings, lists or markdown.
        """

    static let chapterInstructions = """
        You name one chapter of a screen recording from what the narrator says in it. \
        Answer with the title only: two to six words saying what the chapter is about, in the language of the narration, \
        in sentence case (a capital first letter, and capitals for names), as in 'Exporting the quarterly report'. \
        No quotes or trailing period.
        """

    /// The narration as lines, a chapter's title before its first line.
    static func narrationLines(chapters: [RecordingChapter], cues: [RecordingSubtitleCue],
                               editorTime: (TimeInterval) -> TimeInterval?) -> [String] {
        var lines: [String] = []
        var next = 0
        let sorted = chapters.sorted { $0.start < $1.start }
        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = editorTime(cue.start) ?? cue.start
            while next < sorted.count, sorted[next].start <= time {
                lines.append("Chapter: \(sorted[next].title)")
                next += 1
            }
            lines.append(text)
        }
        return lines
    }

    /// Map, then reduce: a narration too long for one prompt is summarized
    /// part by part, and the parts' notes into the summary.
    static func summary(lines: [String], source: CaptureSource?, model: some OnDeviceTextModel) async throws -> String {
        // Parts go out with the notes' instructions and the last prompt with the summary's.
        let budget = min(try await OnDeviceText.inputBudget(model, instructions: summaryInstructions),
                         try await OnDeviceText.inputBudget(model, instructions: notesInstructions))
        var lines = lines
        var isNotes = false
        for _ in 0..<4 {
            let parts = try await OnDeviceText.chunks(of: lines, budget: budget, model: model)
            if parts.count <= 1 {
                return try await finalSummary(parts.first ?? [], isNotes: isNotes, source: source, model: model)
            }
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                let prompt = "Part \(index + 1) of \(parts.count) of the narration:\n" + part.joined(separator: "\n")
                notes.append(OnDeviceText.plain(try await model.reply(instructions: notesInstructions, prompt: prompt), limit: 800))
            }
            lines = notes.enumerated().map { "Part \($0.offset + 1): \($0.element)" }
            isNotes = true
        }
        // Notes that never shrink to one prompt: the first prompt's worth.
        let first = try await OnDeviceText.chunks(of: lines, budget: budget, model: model).first ?? []
        return try await finalSummary(first, isNotes: true, source: source, model: model)
    }

    private static func finalSummary(_ lines: [String], isNotes: Bool, source: CaptureSource?,
                                     model: some OnDeviceTextModel) async throws -> String {
        var parts: [String] = []
        if let source {
            parts.append("Recorded in: \(source.appName)" + (source.windowTitle.map { ", window “\($0)”" } ?? ""))
        }
        parts.append((isNotes ? "Notes on each part of the narration:\n" : "Narration:\n") + lines.joined(separator: "\n"))
        return OnDeviceText.plain(try await model.reply(instructions: summaryInstructions, prompt: parts.joined(separator: "\n\n")),
                                  limit: summaryLimit)
    }

    /// A title for each chapter's text; nil where a chapter has no narration
    /// or the model wrote nothing usable.
    static func chapterTitles(_ texts: [String], model: some OnDeviceTextModel) async throws -> [String?] {
        let budget = try await OnDeviceText.inputBudget(model, instructions: chapterInstructions)
        var titles: [String?] = []
        for text in texts {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { titles.append(nil); continue }
            // A long chapter is named from its opening prompt's worth.
            let opening = try await OnDeviceText.chunks(of: [text], budget: budget, model: model).first ?? [text]
            let reply = try await model.reply(instructions: chapterInstructions, prompt: "Chapter narration:\n" + opening.joined(separator: " "))
            titles.append(chapterTitle(reply))
        }
        return titles
    }

    static func chapterTitle(_ reply: String) -> String? {
        let line = reply.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var title = OnDeviceText.plain(line, limit: 400).trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'‘’."))
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces)
        // The model sometimes answers all in lowercase.
        return title.isEmpty ? nil : title.prefix(1).uppercased() + title.dropFirst()
    }
}
