import AppKit
import AVFoundation

@MainActor
enum RecordingAgentPromptExport {
    /// Uses the same on-device narration service as Studio's Transcribe Narration action.
    static func transcript(cues: [RecordingSubtitleCue], words: [RecordingTranscriptWord],
                           screenURL: URL, canTranscribe: Bool) async throws -> RecordingTranscript {
        guard cues.isEmpty, words.isEmpty, canTranscribe else { return RecordingTranscript(words: words, cues: cues) }
        do {
            return try await RecordingTranscriptionService.transcribe(screenMovieURL: screenURL)
        } catch RecordingTranscriptionService.TranscriptionError.noSpeechDetected {
            return RecordingTranscript(words: [], cues: [])
        }
    }

    /// What Agent Prompt writes for a session, from its input log and capture manifest.
    static func plan(for session: RecordingSession, timeline: RecordingClipTimeline,
                     transcript: RecordingTranscript) -> RecordingAgentPromptPlan {
        let capture = session.loadPointerCapture()
        let input = FileManager.default.fileExists(atPath: session.pointerCaptureURL.path) ? session.pointerCaptureURL : nil
        return RecordingAgentPromptPlan(title: session.displayName, timeline: timeline, cues: transcript.cues, words: transcript.words,
                                        capture: capture, cursorNames: PointerArtworkCapture.names(for: capture?.artwork ?? []),
                                        files: .init(screen: session.screenURL, input: input),
                                        excludesAppWindows: session.loadCaptureManifest()?.includesAppWindows == false)
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
        let transcript = try await transcript(cues: document?.subtitleCues ?? [], words: document?.subtitleWords ?? [],
                                              screenURL: session.screenURL, canTranscribe: session.loadCaptureManifest()?.includesMicrophone == true)
        try Task.checkCancellation()
        let plan = plan(for: session, timeline: timeline, transcript: transcript)
        let movie = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: document) { progress($0 * 0.8) }
        try Task.checkCancellation()
        // Studio can invalidate its cached movie while still extraction is suspended.
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(movie.pathExtension)
        try FileManager.default.copyItem(at: movie, to: snapshot)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        // Named after the package, which a rename doesn't change, so each recording keeps one folder.
        let folder = try await RecordingAgentPromptWriter.write(movie: snapshot, plan: plan, to: directory, name: session.packageName,
                                                                master: session.screenURL) { progress(0.8 + $0 * 0.2) }
        // A cancelled export (Studio closed) doesn't become the one Rex sends.
        try Task.checkCancellation()
        try RecordingAgentPromptWriter.recordLatest(folder, title: plan.title, recording: session.packageName)
        return folder
    }

    /// After a successful export: the path for an agent outside Rex (Rex's
    /// Insert Sukusho Prompt reads latest.json), the Glass chime, and the
    /// Library's card marks. Finder stays put.
    static func finished(_ folder: URL) {
        copyPath(folder)
        if ScreendropPreferences.playSounds { NSSound(named: "Glass")?.play() }
        AccessibilityNotification.Announcement("Agent Prompt saved").post()
        AgentPromptIndex.shared.reload()
    }

    static func copyPath(_ directory: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
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

    /// When each folder's prompt.md was written, by folder name.
    private(set) var written: [String: Date] = [:]
    private(set) var latestPath: String?

    func reload() {
        let directory = RecordingAgentPromptWriter.directoryURL()
        var written: [String: Date] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasSuffix(RecordingAgentPromptWriter.folderSuffix) {
            let prompt = directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("prompt.md")
            if let date = Self.modified(prompt) { written[name] = date }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let latest = (try? Data(contentsOf: directory.appendingPathComponent("latest.json")))
            .flatMap { try? decoder.decode(RecordingAgentPromptWriter.Latest.self, from: $0) }?.path
        // Only real changes, so cards don't redraw on every Library refresh.
        if written != self.written { self.written = written }
        if latest != latestPath { latestPath = latest }
    }

    func folder(for session: RecordingSession) -> URL {
        RecordingAgentPromptWriter.directoryURL().appendingPathComponent(RecordingAgentPromptWriter.folderName(session.packageName), isDirectory: true)
    }

    /// Nil when the capture has no prompt. Reads no files: cells call it, and
    /// the scanner has already read when the recording was last edited.
    func state(for item: CaptureLibraryItem) -> State? {
        guard let session = item.session else { return nil }
        let folder = folder(for: session)
        guard let written = written[folder.lastPathComponent] else { return nil }
        if let edited = item.editedAt, edited > written { return .stale }
        return latestPath == folder.path ? .current : .available
    }

    /// Makes this recording's prompt the one ⌃⌥⌘P sends, with no new export.
    func makeCurrent(_ session: RecordingSession) throws {
        let folder = folder(for: session)
        try RecordingAgentPromptWriter.recordLatest(folder, title: session.displayName, recording: session.packageName)
        RecordingAgentPromptExport.copyPath(folder)
        reload()
    }

    /// The recording went to the Trash; its prompt follows it there.
    func trash(for session: RecordingSession) {
        let folder = folder(for: session)
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
