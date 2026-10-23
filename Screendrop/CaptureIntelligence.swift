import CoreGraphics
import Foundation
import FoundationModels

/// Asks Apple's on-device model for a short title, a category and a few
/// keywords for one capture whose text has been read. It runs on this Mac;
/// nothing it's given or writes leaves it. Adapted from upstream Screendrop's
/// CaptureLibraryAnalyzer (CC0).
nonisolated enum CaptureIntelligence {
    enum Outcome: Sendable {
        case insight(CaptureInsight)
        /// Busy, rate limited or still downloading: asked again next launch.
        case later
    }

    static var isModelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    private static let textLimit = 1800
    private static let transcriptLimit = 600
    private static let instructions = """
        You name screenshots and screen recordings in a person's capture library so they can find them later. \
        You are given the app a capture came from, its window title and the text recognized in it, and sometimes the image. \
        A title says what a capture is about, the way a person would name the file, not just the heading on screen. \
        Describe only what the details support; never invent names, numbers or products.
        """

    @Generable
    struct Answer {
        @Guide(description: "What the capture is about in two to six words: its subject and the specific name it belongs to (a product, company, site, project, place or person) from the text, the window title or the app. A heading alone isn't enough when it's one word or generic; add what it belongs to. In the form of 'Wedding venue shortlist', 'Kyoto ryokan reservation' or 'Postgres replication lag alert'. Never just the window title, never one word. Sentence case, no quotes or trailing period.")
        var title: String
        @Guide(description: "The one category that best describes what the capture shows.")
        var category: Category
        @Guide(description: "Tags someone would file this capture under, most specific first: the products, companies, apps or websites, places and projects it is about, and people's names when they are the subject, spelled as written, names in the window title included. Add a general topic word only when nothing specific fits. Never dates, times or amounts, the whole window title, or the app it was taken in. One or two words each, lowercase unless a proper name.", .maximumCount(5))
        var keywords: [String]
    }

    @Generable
    enum Category {
        case code, design, website, document, chat, email, data, error, receipt, social, media, settings, other
    }

    static func describe(paragraphs: [String], transcript: String?, source: CaptureSource?, isVideo: Bool,
                         image: CGImage?) async -> Outcome {
        let prompt = prompt(paragraphs: paragraphs, transcript: transcript, source: source, isVideo: isVideo)
        let seen = SystemLanguageModel.default.capabilities.contains(.vision) ? image : nil
        let lines = paragraphs + [source?.windowTitle, transcript].compactMap { $0 }
        do {
            return .insight(insight(from: try await respond(prompt, image: seen), lines: lines, source: source))
        } catch where seen != nil && isContextOverflow(error) {
            // An image can overflow the context window; the text alone may fit.
            do { return .insight(insight(from: try await respond(prompt, image: nil), lines: lines, source: source)) } catch { return outcome(for: error) }
        } catch {
            return outcome(for: error)
        }
    }

    /// A refusal, a guardrail or an answer that doesn't fit is final for this
    /// prompt version, so the capture isn't asked again in a loop; a busy or
    /// still-downloading model is asked again next launch.
    static func outcome(for error: any Error) -> Outcome {
        switch error {
        case is CancellationError, is SystemLanguageModel.Error, is LanguageModelSession.Error:
            return .later
        case let error as LanguageModelError:
            switch error {
            case .rateLimited, .timeout: return .later
            default: return .insight(CaptureInsight(declined: true))
            }
        default:
            return .insight(CaptureInsight(declined: true))
        }
    }

    private static func isContextOverflow(_ error: any Error) -> Bool {
        if case .contextSizeExceeded = error as? LanguageModelError { return true }
        return false
    }

    /// `lines` is the text the model was given, for names it lowercased.
    private static func insight(from answer: Answer, lines: [String], source: CaptureSource?) -> CaptureInsight {
        var seen = Set<String>()
        let keywords = answer.keywords.map { CaptureInsightRules.spelling(of: $0.trimmingCharacters(in: .whitespacesAndNewlines), in: lines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let category = String(describing: answer.category)
        return CaptureInsight(title: CaptureInsightRules.cleanTitle(answer.title, windowTitle: source?.windowTitle, appName: source?.appName), keywords: keywords,
                              category: category == "other" ? nil : category.capitalized)
    }

    private static func prompt(paragraphs: [String], transcript: String?, source: CaptureSource?, isVideo: Bool) -> String {
        var parts = ["Capture: \(isVideo ? "screen recording" : "screenshot")"]
        if let source {
            parts.append("App: \(source.appName)")
            if let window = source.windowTitle { parts.append("Window title: \(window)") }
        }
        let text = paragraphs.joined(separator: "\n")
        parts.append(text.isEmpty ? "Text in the capture: none" : "Text in the capture, possibly partial:\n\(text.prefix(textLimit))")
        if let transcript { parts.append("Narration: \(transcript.prefix(transcriptLimit))") }
        return parts.joined(separator: "\n\n")
    }

    /// One fresh session per capture, so one capture never colours the next.
    private static func respond(_ prompt: String, image: CGImage?) async throws -> Answer {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2)
        if let image {
            return try await session.respond(generating: Answer.self, options: options) {
                prompt
                Attachment(image).label("The capture")
            }.content
        }
        return try await session.respond(to: prompt, generating: Answer.self, options: options).content
    }
}
