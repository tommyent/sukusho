import AppKit
import AVFoundation

@MainActor
enum RecordingAgentPromptExport {
    /// Uses the same on-device narration service as Studio's Transcribe Narration action.
    /// A transcription that fails (an unsupported language, no speech model, an
    /// unreadable track) leaves the prompt without narration and says why, rather
    /// than losing the whole prompt.
    static func transcript(cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord],
                           screenURL: URL, canTranscribe: Bool) async throws -> (transcript: RecordingTranscript, failure: String?) {
        let none = RecordingTranscript(words: [], cues: [])
        guard cues.isEmpty, words.isEmpty, canTranscribe else { return (RecordingTranscript(words: words, cues: cues), nil) }
        do {
            return (try await RecordingTranscriptionService.transcribe(screenMovieURL: screenURL), nil)
        } catch RecordingTranscriptionService.TranscriptionError.noSpeechDetected {
            return (none, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (none, error.localizedDescription)
        }
    }

    /// The name the Library card shows (the user's, a model's, else the date), never the package name.
    static func title(for session: RecordingSession) -> String {
        guard let created = session.loadCaptureManifest()?.createdAt else { return session.displayName }
        let modelTitle = CaptureLibraryIndex.shared.visibleInsight("recording:" + session.directoryURL.standardizedFileURL.path)?.title
        return CaptureInsightRules.title(customName: session.customName, modelTitle: modelTitle, dateTitle: CaptureLibraryItem.dateTitle(created))
    }

    /// What Agent Prompt writes for a session, from its input log and capture manifest.
    static func plan(for session: RecordingSession, document: RecordingEditDocument? = nil, timeline: RecordingClipTimeline,
                     transcript: RecordingTranscript, transcriptionFailure: String? = nil) -> RecordingAgentPromptPlan {
        var capture = session.loadPointerCapture()
        // Pen strokes the edit hides stay out of the prompt, as they do in its stills.
        let hidden = Set(document?.hiddenInkStrokeIDs ?? [])
        capture?.ink.removeAll { document?.showsInk == false || hidden.contains($0.id) }
        let input = FileManager.default.fileExists(atPath: session.pointerCaptureURL.path) ? session.pointerCaptureURL : nil
        let manifest = session.loadCaptureManifest()
        return RecordingAgentPromptPlan(title: title(for: session), timeline: timeline, cues: transcript.cues, words: transcript.words,
                                        capture: capture, cursorNames: PointerArtworkCapture.names(for: capture?.artwork ?? []),
                                        files: .init(screen: session.screenURL, input: input),
                                        excludesAppWindows: manifest?.includesAppWindows == false,
                                        source: session.loadProjectMetadata()?.source, transcriptionFailure: transcriptionFailure,
                                        screen: manifest.flatMap { $0.pixelWidth > 0 ? .init(width: $0.pixelWidth, height: $0.pixelHeight, scale: $0.pixelScale) : nil })
    }

    static func write(session: RecordingSession, document: RecordingEditDocument?, to directory: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let duration = try await AVURLAsset(url: session.screenURL).load(.duration).seconds
        let timeline: RecordingClipTimeline
        if let clips = document?.clips, !clips.isEmpty {
            timeline = RecordingClipTimeline(segments: clips).normalized(to: duration)
        } else {
            timeline = .legacyTrim(start: document?.trimStart, end: document?.trimEnd, sourceDuration: duration)
        }
        let narration = try await transcript(cues: document?.subtitleCues ?? [], words: document?.subtitleWords ?? [],
                                             screenURL: session.screenURL, canTranscribe: session.loadCaptureManifest()?.includesMicrophone == true)
        try Task.checkCancellation()
        let plan = plan(for: session, document: document, timeline: timeline, transcript: narration.transcript,
                        transcriptionFailure: narration.failure)
        // Stills come from the screen recording itself, not a styled render: an agent wants the
        // whole screen at its real size, and the export takes seconds instead of a transcode.
        // Named after the card, then the package's ID, which keeps one folder per recording through renames.
        let id = AgentPromptIndex.recordingID(session)
        let folder = try await RecordingAgentPromptWriter.write(movie: nil, plan: plan, to: directory, name: String(plan.title.prefix(80)) + "_" + id,
                                                                master: session.screenURL, progress: progress)
        // A cancelled export (Studio closed) doesn't become the one Rex sends.
        try Task.checkCancellation()
        // One folder per recording: one under an earlier name (renamed since, or named after its package) goes.
        for other in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where other != folder.lastPathComponent && RecordingAgentPromptWriter.recordingID(ofFolder: other) == id {
            try? FileManager.default.trashItem(at: directory.appendingPathComponent(other, isDirectory: true), resultingItemURL: nil)
        }
        try RecordingAgentPromptWriter.recordLatest(folder, title: plan.title, recording: session.packageName)
        return folder
    }

    /// After a successful export: the Read line for an agent outside Rex (Rex's
    /// Insert Sukusho Prompt reads latest.json), the Glass chime, and the
    /// Library's card marks. Finder stays put.
    static func finished(_ folder: URL) {
        copyReadLine(folder)
        if ScreendropPreferences.playSounds { NSSound(named: "Glass")?.play() }
        AccessibilityNotification.Announcement("Agent Prompt saved").post()
        AgentPromptIndex.shared.reload()
    }

    /// The line people paste to an agent, as Rex types it.
    static func copyReadLine(_ directory: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Read \"\(directory.appendingPathComponent("prompt.md").path)\" and follow it.", forType: .string)
    }
}

/// Which recordings have an Agent Prompt in `~/Agent Prompts`, and which one
/// latest.json names, for the circle on Library cards.
@Observable
final class AgentPromptIndex {
    static let shared = AgentPromptIndex()

    enum State: Equatable {
        /// latest.json names it, so Rex's ⌃⌥⌘P sends it.
        case current
        /// Another recording's prompt is current.
        case available
        /// The recording was edited after this prompt was written.
        case stale
    }

    struct Folder: Equatable {
        let name: String
        /// When its prompt.md was written.
        let written: Date
    }

    /// Each recording's prompt folder, by recording ID.
    private(set) var folders: [String: Folder] = [:]
    private(set) var latestPath: String?

    /// The short random ID that ends a recording's package name ("20F562"); its
    /// prompt's folder ends with it too. shortcut: two recordings share a folder if
    /// their 6 hex digits match (1 in 16.7 million a pair), give folders the full
    /// package name if that ever happens.
    static func recordingID(_ session: RecordingSession) -> String {
        let name = session.packageName
        return name.lastIndex(of: "_").map { String(name[name.index(after: $0)...]) } ?? name
    }

    func reload() {
        let directory = RecordingAgentPromptWriter.directoryURL()
        var folders: [String: Folder] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard let id = RecordingAgentPromptWriter.recordingID(ofFolder: name),
                  let date = Self.modified(directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("prompt.md")),
                  date > folders[id]?.written ?? .distantPast else { continue }
            folders[id] = Folder(name: name, written: date)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let latest = (try? Data(contentsOf: directory.appendingPathComponent("latest.json")))
            .flatMap { try? decoder.decode(RecordingAgentPromptWriter.Latest.self, from: $0) }?.path
        // Only real changes, so cards don't redraw on every Library refresh.
        if folders != self.folders { self.folders = folders }
        if latest != latestPath { latestPath = latest }
    }

    /// The recording's prompt folder, nil when it has none.
    func folder(for session: RecordingSession) -> URL? {
        folders[Self.recordingID(session)].map {
            RecordingAgentPromptWriter.directoryURL().appendingPathComponent($0.name, isDirectory: true)
        }
    }

    /// Nil when the capture has no prompt. Reads no files: cells call it, and
    /// the scanner has already read when the recording was last edited.
    func state(for item: CaptureLibraryItem) -> State? {
        guard let session = item.session, let folder = folder(for: session),
              let written = folders[Self.recordingID(session)]?.written else { return nil }
        if let edited = item.editedAt, edited > written { return .stale }
        return latestPath == folder.path ? .current : .available
    }

    /// Makes this recording's prompt the one ⌃⌥⌘P sends, with no new export.
    func makeCurrent(_ session: RecordingSession) throws {
        guard let folder = folder(for: session) else { return }
        try RecordingAgentPromptWriter.recordLatest(folder, title: RecordingAgentPromptExport.title(for: session), recording: session.packageName)
        RecordingAgentPromptExport.copyReadLine(folder)
        reload()
    }

    /// The recording went to the Trash; its prompt follows it there.
    func trash(for session: RecordingSession) {
        guard let folder = folder(for: session) else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        // Without latest.json, Rex says there's no prompt yet rather than typing a path that's gone.
        if latestPath == folder.path {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().appendingPathComponent("latest.json"))
        }
        reload()
    }

    private nonisolated static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
