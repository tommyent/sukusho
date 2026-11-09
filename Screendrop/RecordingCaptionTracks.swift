import Foundation
import NaturalLanguage

/// One language's captions, translated on this Mac. Each cue keeps the
/// original cue's id, start and end; only its text is translated.
nonisolated struct RecordingCaptionTrack: Codable, Sendable, Equatable, Identifiable {
    /// BCP 47, e.g. es or pt-BR.
    var lang: String
    /// The language's name in itself, e.g. Español.
    var label: String
    var cues: [RecordingSubtitleCue]

    var id: String { lang }
}

nonisolated enum RecordingCaptionTranslation {
    /// The Worker keeps up to 10.
    static let maximumTracks = 10

    /// Pairs each cue with its translation by the cue's id (the request's
    /// client identifier). A cue the translation skipped keeps its text.
    static func track(lang: String, cues: [RecordingSubtitleCue], translations: [String: String]) -> RecordingCaptionTrack {
        RecordingCaptionTrack(lang: lang, label: label(for: lang), cues: cues.map { cue in
            var translated = cue
            let text = translations[cue.id.uuidString]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { translated.text = text }
            return translated
        })
    }

    /// Short BCP 47: es, es-MX, pt-PT. Translation lists languages in full
    /// (es-Latn-ES), which the share page's menu would show as is.
    static func tag(_ language: Locale.Language) -> String {
        language.minimalIdentifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The language's name in itself: Español, Português (Brasil).
    static func label(for tag: String) -> String {
        let locale = Locale(identifier: tag)
        let name = locale.localizedString(forIdentifier: tag) ?? tag
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The captions' language, read from their text; nil leaves it to Translation.
    static func sourceLanguage(of cues: [RecordingSubtitleCue]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cues.prefix(200).map(\.text).joined(separator: " "))
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// Adds or replaces the track for its language, keeping the order they were made in.
    static func merging(_ track: RecordingCaptionTrack, into tracks: [RecordingCaptionTrack]) -> [RecordingCaptionTrack] {
        guard let index = tracks.firstIndex(where: { $0.lang == track.lang }) else { return Array((tracks + [track]).prefix(maximumTracks)) }
        var tracks = tracks
        tracks[index] = track
        return tracks
    }
}

/// The share page's summary and translated captions: the `summary` and
/// `caption_tracks` fields of POST /api/assets/<id>, for Worker 2.1.0 and later.
nonisolated enum CloudShareText {
    static let minimumWorkerVersion = "2.1.0"
    static let summaryLimit = 2000
    static let maximumTrackBytes = 512 * 1024

    struct Cue: Codable, Sendable, Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Track: Codable, Sendable, Equatable {
        let lang: String
        let label: String
        let cues: [Cue]
    }

    /// Frozen when the upload starts, like the transcript.
    struct Payload: Sendable, Equatable {
        var summary: String
        var tracks: [Track]
        /// The original transcript's language, which names its track on the share page.
        var transcriptLang: String? = nil
    }

    /// The Worker's own tag rule: what `Intl.getCanonicalLocales` takes, letters, digits and hyphens.
    static func isValidTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard tag.count <= 35, let first = parts.first, (2...3).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    /// A Worker that doesn't say its version counts as older.
    static func supported(version: String?) -> Bool {
        guard let version else { return false }
        return version.compare(minimumWorkerVersion, options: .numeric) != .orderedAscending
    }

    /// `map` moves a cue onto the shared video's timeline, or returns nil
    /// when it was cut, as the transcript's cues are. A track the Worker
    /// would refuse is left out, since one bad field costs the whole request
    /// its poster and transcript too.
    static func payload(summary: String?, tracks: [RecordingCaptionTrack], transcriptLang: String? = nil,
                        map: (TimeInterval, TimeInterval) -> (Double, Double)?) -> Payload {
        var seen = Set<String>()
        var wire: [Track] = []
        for track in tracks {
            let cues = track.cues.compactMap { cue -> Cue? in
                let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let (start, end) = map(cue.start, cue.end),
                      start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                return Cue(start: start, end: end, text: text)
            }
            let label = track.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let shared = Track(lang: track.lang, label: label, cues: cues)
            let problem: String? =
                if !isValidTag(track.lang) { "not a tag the Worker takes" }
                else if !seen.insert(track.lang.lowercased()).inserted { "a second track in the same language" }
                else if !(1...100).contains(label.unicodeScalars.count) { "its label isn't 1–100 characters" }
                else if cues.isEmpty { "no cue left in the shared video" }
                else if (try? JSONEncoder().encode(shared).count).map({ $0 > maximumTrackBytes }) ?? true { "over 512 KB" }
                else if wire.count == RecordingCaptionTranslation.maximumTracks { "past the 10 the Worker keeps" }
                else { nil }
            if let problem {
                print("Translated captions “\(track.lang)” left out of the upload: \(problem)")
                continue
            }
            wire.append(shared)
        }
        return Payload(summary: trimmedSummary(summary), tracks: wire,
                       transcriptLang: transcriptLang.flatMap { isValidTag($0) ? $0 : nil })
    }

    /// At most 2,000 UTF-16 units, as the Worker counts them, cut between characters.
    static func trimmedSummary(_ summary: String?) -> String {
        var text = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf16.count > summaryLimit { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sent on upload and again on Replace, which clears them on the Worker
    /// first, so an empty one is left out. Never to an older Worker or for a sealed upload.
    static func fields(_ payload: Payload?, workerVersion: String?, sealed: Bool) -> [(name: String, value: String)] {
        guard let payload, !sealed, supported(version: workerVersion) else { return [] }
        var fields: [(name: String, value: String)] = []
        if !payload.summary.isEmpty { fields.append(("summary", payload.summary)) }
        if !payload.tracks.isEmpty, let tracks = try? JSONEncoder().encode(payload.tracks) {
            fields.append(("caption_tracks", String(decoding: tracks, as: UTF8.self)))
        }
        if let lang = payload.transcriptLang { fields.append(("transcript_lang", lang)) }
        return fields
    }
}
