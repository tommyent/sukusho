import AppKit

/// The How-To Guide for a recording, from Studio or the Library: one click writes a folder to
/// the export location, copies its Markdown and shows it in Finder. The bug report is written
/// with the Agent Prompt (RecordingAgentPromptExport).
@MainActor
enum RecordingStepsExport {
    /// The recording's summary as Studio saved it (Summarize, or typed), never a new model call.
    /// When there is one, it leads both formats under "Summary"; narration is never rewritten.
    static var summary: (@MainActor (RecordingSession) async -> String?)? = { $0.loadProjectMetadata()?.summary }

    /// Narration (transcribed on-device when the edit has none), the moments and their stills.
    static func prepare(session: RecordingSession, document: RecordingEditDocument?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> (steps: RecordingSteps, stills: [Data]) {
        let timeline = try await RecordingAgentPromptExport.timeline(session: session, document: document)
        let narration = try await RecordingAgentPromptExport.transcript(
            cues: document?.subtitleCues ?? [], words: document?.subtitleWords ?? [], screenURL: session.screenURL,
            canTranscribe: session.loadCaptureManifest()?.includesMicrophone == true)
        try Task.checkCancellation()
        progress(0.3)
        let plan = RecordingAgentPromptExport.plan(for: session, document: document, timeline: timeline,
                                                   transcript: narration.transcript, transcriptionFailure: narration.failure)
        let stills = try await RecordingSteps.stills(plan: plan, master: session.screenURL) { progress(0.3 + $0 * 0.7) }
        let steps = RecordingSteps(plan: plan, systemVersion: session.loadCaptureManifest()?.systemVersion,
                                   summary: await summary?(session))
        return (steps, stills)
    }

    /// A new folder in the export location, named after the recording and the format.
    static func write(_ steps: RecordingSteps, format: RecordingSteps.Format, stills: [Data]) throws -> URL {
        let directory = ScreendropPreferences.exportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = RecordingAgentPromptWriter.safeName(String(steps.title.prefix(80)) + " " + format.title)
        return try steps.write(format, stills: stills, to: ScreenshotFileNaming.uniqueURL(for: name, in: directory))
    }

    /// Writes the guide with Studio's unsaved edits when it's open on the recording, copies its
    /// Markdown for Jira, Linear or GitHub, and shows `guide.html` in Finder.
    static func exportGuide(session: RecordingSession, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        StudioProjectRegistry.shared.flushDrafts()
        let document = try StudioProjectRegistry.shared.document(for: session.directoryURL) ?? session.editDocumentForRendering()
        let (steps, stills) = try await prepare(session: session, document: document, progress: progress)
        let folder = try write(steps, format: .guide, stills: stills)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(steps.markdown(.guide, localFolder: folder), forType: .string)
        AccessibilityNotification.Announcement("Guide saved and copied as Markdown").post()
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(RecordingSteps.Format.guide.fileName + ".html")])
        return folder
    }
}
