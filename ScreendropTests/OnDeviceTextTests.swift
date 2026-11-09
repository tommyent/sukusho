import Foundation
import FoundationModels
import Testing

/// Apple's model as the tests see it: a token per word, and answers from the test, every prompt kept.
actor FakeTextModel: OnDeviceTextModel {
    nonisolated let contextSize: Int
    private let answer: @Sendable (_ instructions: String, _ prompt: String) -> String
    private(set) var prompts: [(instructions: String, prompt: String)] = []

    init(contextSize: Int = 8192, answer: @escaping @Sendable (_ instructions: String, _ prompt: String) -> String) {
        self.contextSize = contextSize
        self.answer = answer
    }

    func tokenCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    func reply(instructions: String, prompt: String) -> String {
        prompts.append((instructions, prompt))
        return answer(instructions, prompt)
    }
}

private func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

struct OnDeviceTextTests {
    // MARK: Summary

    @Test func aLongNarrationIsSummarizedPartByPartThenFromThePartsNotes() async throws {
        let model = FakeTextModel(contextSize: 1200) { instructions, prompt in
            instructions == RecordingTextIntelligence.notesInstructions
                ? "Notes on " + (prompt.components(separatedBy: "\n").first ?? "")
                : "**The recording** sets up a Worker."
        }
        let lines = (0..<80).map { "line \($0) where the narrator explains one more step of it" }
        let summary = try await RecordingTextIntelligence.summary(lines: lines, source: nil, model: model)
        #expect(summary == "The recording sets up a Worker.")

        let budget = 1200 - max(words(RecordingTextIntelligence.summaryInstructions), words(RecordingTextIntelligence.notesInstructions))
            - OnDeviceText.reservedTokens
        let prompts = await model.prompts
        let parts = prompts.filter { $0.instructions == RecordingTextIntelligence.notesInstructions }
        #expect(parts.count >= 3)
        var sent: [String] = []
        for part in parts {
            let body = part.prompt.components(separatedBy: "\n").dropFirst()
            #expect(words(body.joined(separator: " ")) <= budget)
            sent += body
        }
        // Every line goes to the model once, in order.
        #expect(sent == lines)
        let last = try #require(prompts.last)
        #expect(last.instructions == RecordingTextIntelligence.summaryInstructions)
        #expect(last.prompt.contains("Notes on each part of the narration:"))
        for index in parts.indices { #expect(last.prompt.contains("Part \(index + 1): Notes on Part \(index + 1) of \(parts.count)")) }
    }

    @Test func aShortNarrationIsOnePromptWithTheAppItCameFrom() async throws {
        let model = FakeTextModel { _, _ in "  \u{201C}A short tour of the Cloud settings.\u{201D}  " }
        let source = CaptureSource(bundleIdentifier: "com.example.app", appName: "Example", windowTitle: "Settings")
        let lines = ["Chapter: Settings", "Here I open the settings.", "Then I paste the token."]
        let summary = try await RecordingTextIntelligence.summary(lines: lines, source: source, model: model)
        #expect(summary == "A short tour of the Cloud settings.")
        let prompts = await model.prompts
        #expect(prompts.count == 1)
        #expect(prompts[0].prompt == "Recorded in: Example, window “Settings”\n\nNarration:\nChapter: Settings\nHere I open the settings.\nThen I paste the token.")
    }

    @Test func aSummaryKeepsToTheWorkersLimitAndPlainText() async throws {
        let model = FakeTextModel { _, _ in "# Summary\n- " + String(repeating: "é", count: 2500) }
        let summary = try await RecordingTextIntelligence.summary(lines: ["one line"], source: nil, model: model)
        #expect(summary.count == RecordingTextIntelligence.summaryLimit)
        #expect(summary.hasPrefix("Summary éé"))
        #expect(OnDeviceText.plain("- First point\n- **Second**\n\nNew paragraph", limit: 100) == "First point Second\n\nNew paragraph")
    }

    @Test func narrationLinesPutEachChapterBeforeItsFirstLine() {
        let chapters = [RecordingChapter(title: "Intro", start: 0), RecordingChapter(title: "Setup", start: 10)]
        let cues = [RecordingSubtitleCue(start: 1, end: 2, text: "Hello."), RecordingSubtitleCue(start: 12, end: 13, text: " Paste it. "),
                    RecordingSubtitleCue(start: 14, end: 15, text: "  ")]
        // A 3 s cut moves the source's 12 s to 9 s, still before the chapter at 10 s; a blank cue brings no header.
        let lines = RecordingTextIntelligence.narrationLines(chapters: chapters, cues: cues) { $0 > 5 ? $0 - 3 : $0 }
        #expect(lines == ["Chapter: Intro", "Hello.", "Paste it."])
        let later = RecordingTextIntelligence.narrationLines(chapters: chapters, cues: cues) { $0 }
        #expect(later == ["Chapter: Intro", "Hello.", "Chapter: Setup", "Paste it."])
    }

    @Test func aLineLongerThanThePromptIsSplitBetweenWords() async throws {
        let model = FakeTextModel { _, _ in "" }
        let line = (0..<500).map { "w\($0)" }.joined(separator: " ")
        let chunks = try await OnDeviceText.chunks(of: [line], budget: 100, model: model)
        #expect(chunks.count >= 5)
        #expect(chunks.allSatisfy { words($0.joined(separator: " ")) <= 100 })
        #expect(chunks.flatMap { $0 }.joined(separator: " ") == line)
        #expect(try await OnDeviceText.chunks(of: [], budget: 100, model: model).isEmpty)
    }

    // MARK: Chapter titles

    @Test func chapterTitlesSkipSilentChaptersAndCleanTheModelsReply() async throws {
        let model = FakeTextModel { _, prompt in
            prompt.contains("worker") ? "\"Setting up the Worker.\"" : "Title: Pasting the token\nBecause the narrator pastes it."
        }
        let titles = try await RecordingTextIntelligence.chapterTitles(["", "we set up the worker", "now paste the token"], model: model)
        #expect(titles == [nil, "Setting up the Worker", "Pasting the token"])
        #expect(await model.prompts.count == 2)
        #expect(RecordingTextIntelligence.chapterTitle("  ") == nil)
        #expect(RecordingTextIntelligence.chapterTitle(String(repeating: "a", count: 120))?.count == 80)
    }

    @Test func namedChaptersKeepTheirTitlesAndUndoGetsTheOpeningSentencesBack() {
        let timeline = RecordingClipTimeline.full(sourceDuration: 60)
        let cues = [RecordingSubtitleCue(start: 1, end: 3, text: "First we open the app. Then more."),
                    RecordingSubtitleCue(start: 31, end: 33, text: "Now the token goes in.")]
        let original = [RecordingChapter(title: "", start: 0, autoTitle: true), RecordingChapter(title: "", start: 30, autoTitle: true),
                        RecordingChapter(title: "Typed by hand", start: 45)]
        let named = RecordingChapterPlanner.named(original, titles: [original[0].id: "Opening the app", original[1].id: "Adding the token"])
        #expect(named.map(\.autoTitle) == [false, false, nil])
        #expect(RecordingChapterPlanner.mapped(named, through: timeline, cues: cues).map(\.title)
                == ["Opening the app", "Adding the token", "Typed by hand"])
        // Undo puts the chapters back as they were, and they title themselves from the narration again.
        #expect(RecordingChapterPlanner.mapped(original, through: timeline, cues: cues).map(\.title)
                == ["First we open the app", "Now the token goes in", "Typed by hand"])
        #expect(RecordingChapterPlanner.named(original, titles: [:]) == original)
    }

    @Test @MainActor func theModelExplainsWhyItCantRun() {
        #expect(OnDeviceText.unavailableReason(.available, settingOn: true) == nil)
        #expect(OnDeviceText.unavailableReason(.available, settingOn: false)?.contains("Settings › General") == true)
        #expect(OnDeviceText.unavailableReason(.unavailable(.modelNotReady), settingOn: true)?.contains("downloading") == true)
        #expect(OnDeviceText.unavailableReason(.unavailable(.appleIntelligenceNotEnabled), settingOn: true)?.contains("System Settings") == true)
        #expect(OnDeviceText.unavailableReason(.unavailable(.deviceNotEligible), settingOn: true) == "This Mac can’t run Apple Intelligence.")
    }

    @Test func aRecordingsSummaryAndTranslationsSaveInItsProject() throws {
        var metadata = RecordingProjectMetadata(displayName: "Tour")
        metadata.summary = "A tour."
        metadata.captionTracks = [RecordingCaptionTrack(lang: "es", label: "Español", cues: [RecordingSubtitleCue(start: 1, end: 2, text: "Hola")])]
        let decoded = try JSONDecoder().decode(RecordingProjectMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded == metadata)
        let older = try JSONDecoder().decode(RecordingProjectMetadata.self, from: Data(#"{"version":1,"displayName":"Old"}"#.utf8))
        #expect(older.summary == nil && older.captionTracks == nil)
    }
}

struct CaptionTranslationTests {
    @Test func aTranslationKeepsEveryCuesIdStartAndEnd() {
        let cues = [RecordingSubtitleCue(start: 0.5, end: 2.25, text: "Open the settings."),
                    RecordingSubtitleCue(start: 2.25, end: 4, text: "Paste the token."),
                    RecordingSubtitleCue(start: 4.1, end: 6.8, text: "It turns green.")]
        let track = RecordingCaptionTranslation.track(lang: "es", cues: cues, translations: [
            cues[0].id.uuidString: "Abre los ajustes.", cues[1].id.uuidString: "  ",
            cues[2].id.uuidString: " Se pone verde. ", "unknown": "Nada",
        ])
        #expect(track.lang == "es" && track.label == "Español")
        #expect(track.cues.map(\.id) == cues.map(\.id))
        #expect(track.cues.map(\.start) == cues.map(\.start))
        #expect(track.cues.map(\.end) == cues.map(\.end))
        // A cue the translation left blank keeps the original rather than going silent.
        #expect(track.cues.map(\.text) == ["Abre los ajustes.", "Paste the token.", "Se pone verde."])
    }

    @Test func languagesGetShortTagsAndTheirOwnNames() {
        #expect(RecordingCaptionTranslation.tag(Locale.Language(identifier: "es-Latn-ES")) == "es")
        #expect(RecordingCaptionTranslation.tag(Locale.Language(identifier: "es-Latn-MX")) == "es-MX")
        #expect(RecordingCaptionTranslation.tag(Locale.Language(identifier: "pt-Latn-PT")) == "pt-PT")
        #expect(RecordingCaptionTranslation.tag(Locale.Language(identifier: "zh-Hant-TW")) == "zh-TW")
        #expect(RecordingCaptionTranslation.label(for: "de") == "Deutsch")
        #expect(RecordingCaptionTranslation.label(for: "pt-PT").hasPrefix("Português"))
    }

    @Test func translatingALanguageAgainReplacesItsTrack() {
        let first = RecordingCaptionTrack(lang: "es", label: "Español", cues: [])
        let french = RecordingCaptionTrack(lang: "fr", label: "Français", cues: [])
        let again = RecordingCaptionTrack(lang: "es", label: "Español", cues: [RecordingSubtitleCue(start: 0, end: 1, text: "Hola")])
        #expect(RecordingCaptionTranslation.merging(again, into: [first, french]) == [again, french])
        let full = (0..<10).map { RecordingCaptionTrack(lang: "x\($0)", label: "", cues: []) }
        #expect(RecordingCaptionTranslation.merging(french, into: full).count == 10)
    }

    @Test func theCaptionsLanguageIsReadFromTheirText() {
        let cues = ["Hoy vamos a abrir los ajustes de la aplicación", "y pegar el token que copiamos antes"]
            .enumerated().map { RecordingSubtitleCue(start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) }
        #expect(RecordingCaptionTranslation.sourceLanguage(of: cues)?.languageCode?.identifier == "es")
        #expect(RecordingCaptionTranslation.sourceLanguage(of: []) == nil)
    }
}

struct CloudShareTextTests {
    private func cues(_ texts: [(Double, Double, String)]) -> [RecordingSubtitleCue] {
        texts.map { RecordingSubtitleCue(start: $0.0, end: $0.1, text: $0.2) }
    }

    @Test func theTracksFieldIsTheContractsJSON() throws {
        let payload = CloudShareText.payload(summary: "  A tour.\nTwo lines.  ", tracks: [
            RecordingCaptionTrack(lang: "es", label: "Español", cues: cues([(0.5, 2, "Hola"), (2, 3.5, "Adiós")])),
            RecordingCaptionTrack(lang: "pt-BR", label: "Português (Brasil)", cues: cues([(0.5, 2, "Olá")])),
        ], transcriptLang: "en") { ($0, $1) }
        let fields = CloudShareText.fields(payload, workerVersion: "2.1.0", sealed: false)
        #expect(fields.map(\.name) == ["summary", "caption_tracks", "transcript_lang"])
        #expect(fields[0].value == "A tour.\nTwo lines.")
        #expect(fields[2].value == "en")
        let tracks = try #require(JSONSerialization.jsonObject(with: Data(fields[1].value.utf8)) as? [[String: Any]])
        #expect(tracks.map { $0["lang"] as? String } == ["es", "pt-BR"])
        #expect(tracks.map { $0["label"] as? String } == ["Español", "Português (Brasil)"])
        let first = try #require(tracks[0]["cues"] as? [[String: Any]])
        #expect(first.count == 2)
        #expect(Set(first[0].keys) == ["start", "end", "text"])
        #expect(first[0]["start"] as? Double == 0.5 && first[0]["end"] as? Double == 2 && first[0]["text"] as? String == "Hola")
        #expect(Set(tracks[0].keys) == ["lang", "label", "cues"])
    }

    @Test func nothingEmptyIsSentSinceReplaceClearsItOnTheWorker() throws {
        let empty = CloudShareText.payload(summary: "  ", tracks: [], transcriptLang: nil) { ($0, $1) }
        #expect(CloudShareText.fields(empty, workerVersion: "2.1.0", sealed: false).isEmpty)
        let summaryOnly = CloudShareText.payload(summary: "A tour.", tracks: []) { ($0, $1) }
        #expect(CloudShareText.fields(summaryOnly, workerVersion: "2.1.0", sealed: false).map(\.name) == ["summary"])
    }

    @Test func tracksTheWorkerWouldRefuseAreLeftOut() {
        let one = cues([(0, 1, "x")])
        let payload = CloudShareText.payload(summary: nil, tracks: [
            RecordingCaptionTrack(lang: "es", label: "Español", cues: one),
            RecordingCaptionTrack(lang: "ES", label: "Español", cues: one),
            RecordingCaptionTrack(lang: "es_MX", label: "Español", cues: one),
            RecordingCaptionTrack(lang: "e", label: "E", cues: one),
            RecordingCaptionTrack(lang: "de-toolongsubtag", label: "Deutsch", cues: one),
            RecordingCaptionTrack(lang: "fr", label: "  ", cues: one),
            RecordingCaptionTrack(lang: "it", label: String(repeating: "I", count: 101), cues: one),
            RecordingCaptionTrack(lang: "zh-Hant-TW", label: " 中文（台灣） ", cues: one),
        ], transcriptLang: "en_US") { ($0, $1) }
        #expect(payload.tracks.map(\.lang) == ["es", "zh-Hant-TW"])
        #expect(payload.tracks.last?.label == "中文（台灣）")
        #expect(payload.transcriptLang == nil)
        #expect(CloudShareText.isValidTag("pt-BR") && CloudShareText.isValidTag("yue") && !CloudShareText.isValidTag("pt BR"))
    }

    @Test func cutCuesDropAndTheRestFollowTheSharedCut() {
        // The shared cut drops 2–4 s of the source and plays the rest 2 s earlier.
        let map: (TimeInterval, TimeInterval) -> (Double, Double)? = { start, end in
            if start >= 2 && end <= 4 { return nil }
            return start >= 4 ? (start - 2, end - 2) : (start, end)
        }
        let payload = CloudShareText.payload(summary: nil, tracks: [
            RecordingCaptionTrack(lang: "es", label: "Español", cues: cues([(0, 2, "Uno"), (2, 4, "Dos"), (4, 6, "Tres"), (6, 7, " ")])),
            RecordingCaptionTrack(lang: "es", label: "Español", cues: cues([(0, 1, "Otra vez")])),
            RecordingCaptionTrack(lang: "fr", label: "Français", cues: cues([(2.5, 3.5, "Coupé")])),
        ], map: map)
        #expect(payload.tracks == [CloudShareText.Track(lang: "es", label: "Español",
                                                        cues: [.init(start: 0, end: 2, text: "Uno"), .init(start: 2, end: 4, text: "Tres")])])
    }

    @Test func tracksStayWithinTheWorkersLimits() {
        let big = RecordingCaptionTrack(lang: "de", label: "Deutsch",
                                        cues: (0..<600).map { RecordingSubtitleCue(start: Double($0), end: Double($0) + 1, text: String(repeating: "Wort ", count: 200)) })
        let small = (0..<12).map { RecordingCaptionTrack(lang: "a" + String(UnicodeScalar(98 + UInt8($0))), label: "L", cues: cues([(0, 1, "x")])) }
        let payload = CloudShareText.payload(summary: nil, tracks: [big] + small) { ($0, $1) }
        #expect(payload.tracks.count == RecordingCaptionTranslation.maximumTracks)
        #expect(!payload.tracks.contains { $0.lang == "de" })
        #expect(payload.tracks.allSatisfy { ((try? JSONEncoder().encode($0))?.count ?? .max) <= CloudShareText.maximumTrackBytes })
    }

    @Test func aSummaryIsCutToTheWorkersLimitBetweenCharacters() {
        let emoji = String(repeating: "👋", count: 1500)
        let trimmed = CloudShareText.trimmedSummary(emoji)
        #expect(trimmed.utf16.count <= CloudShareText.summaryLimit && trimmed.utf16.count >= CloudShareText.summaryLimit - 1)
        #expect(trimmed.allSatisfy { $0 == "👋" })
        #expect(CloudShareText.trimmedSummary("  \n ") == "")
        #expect(CloudShareText.trimmedSummary(nil) == "")
    }

    @Test func olderWorkersAndSealedSharesNeverGetTheFields() {
        let payload = CloudShareText.payload(summary: "A tour.", tracks: [RecordingCaptionTrack(lang: "es", label: "Español", cues: cues([(0, 1, "Hola")]))],
                                             transcriptLang: "en") { ($0, $1) }
        #expect(CloudShareText.fields(payload, workerVersion: nil, sealed: false).isEmpty)
        #expect(CloudShareText.fields(payload, workerVersion: "2.0.0", sealed: false).isEmpty)
        #expect(CloudShareText.fields(payload, workerVersion: "2.0.9", sealed: false).isEmpty)
        #expect(CloudShareText.fields(payload, workerVersion: "2.1.0", sealed: true).isEmpty)
        #expect(CloudShareText.fields(nil, workerVersion: "2.1.0", sealed: false).isEmpty)
        #expect(CloudShareText.fields(payload, workerVersion: "2.1.0", sealed: false).count == 3)
        #expect(CloudShareText.fields(payload, workerVersion: "2.10.0", sealed: false).count == 3)
        #expect(CloudShareText.fields(payload, workerVersion: "3.0.0", sealed: false).count == 3)
    }
}
