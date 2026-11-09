import AppKit
import SwiftUI

/// Export Steps for a recording, from Studio or the Library: its sheet picks Guide or
/// Bug Report, then writes a folder to the export location or copies the Markdown.
@MainActor
enum RecordingStepsExport {
    /// The recording's summary as Studio saved it (Summarize, or typed), never a new model call.
    /// When there is one, it leads both formats under "Summary"; narration is never rewritten.
    static var summary: (@MainActor (RecordingSession) async -> String?)? = { $0.loadProjectMetadata()?.summary }

    /// Narration (transcribed on-device when the edit has none), the moments and their stills.
    static func prepare(session: RecordingSession, document: RecordingEditDocument?, includesLogs: Bool,
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
                                   includesLogs: includesLogs, summary: await summary?(session))
        return (steps, stills)
    }

    /// A new folder in the export location, named after the recording and the format.
    static func write(_ steps: RecordingSteps, format: RecordingSteps.Format, stills: [Data]) throws -> URL {
        let directory = ScreendropPreferences.exportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = RecordingAgentPromptWriter.safeName(String(steps.title.prefix(80)) + " " + format.title)
        return try steps.write(format, stills: stills, to: ScreenshotFileNaming.uniqueURL(for: name, in: directory))
    }
}

/// Puts the Export Steps sheet on the key window: Studio's or the Library's.
@MainActor
enum RecordingStepsSheetPresenter {
    private static var window: NSWindow?

    static func present(session: RecordingSession) {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        let parent = NSApp.keyWindow
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        // Studio's unsaved edits when it's open on the recording, as Export Agent Prompt reads them.
        let document: @MainActor () throws -> RecordingEditDocument? = {
            StudioProjectRegistry.shared.flushDrafts()
            return try StudioProjectRegistry.shared.document(for: session.directoryURL) ?? session.editDocumentForRendering()
        }
        sheet.contentViewController = NSHostingController(rootView: RecordingStepsSheet(session: session, document: document) { [weak sheet] in
            if let sheet {
                if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
            }
            window = nil
        })
        window = sheet
        if let parent {
            parent.beginSheet(sheet)
        } else {
            sheet.center()
            NSApp.activate()
            sheet.makeKeyAndOrderFront(nil)
        }
    }
}

struct RecordingStepsSheet: View {
    let session: RecordingSession
    let document: @MainActor () throws -> RecordingEditDocument?
    let dismiss: @MainActor () -> Void

    @State private var format: RecordingSteps.Format = .guide
    @State private var attachLogs = true
    @State private var progress: Double?
    @State private var failure: String?
    @State private var work: Task<Void, Never>?
    @State private var logs: RecordingAppLogs?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Steps").font(.headline)
            Picker("Format", selection: $format) {
                ForEach(RecordingSteps.Format.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(format == .guide
                 ? "A numbered step for each click, shortcut, pointer rest, scroll and pen stroke, with a still and what was said."
                 : "The environment, steps to reproduce, what happened from the narration, and the stills as attachments.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if format == .bugReport, let logs {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Attach \(logs.appName)'s log", isOn: $attachLogs)
                    Text(logs.countsLine).font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        Text(logs.text(timeline: nil))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 96)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    Text("Logs can hold personal data. They stay on this Mac unless you share the export.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Narration is used as transcribed. Copy as Markdown pastes into Jira, Linear or GitHub; the images stay local files to attach.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                ProgressView(value: progress).accessibilityLabel("Exporting steps")
            }
            if let failure {
                Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    work?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Copy as Markdown") { run(copy: true) }
                    .disabled(work != nil)
                Button("Export") { run(copy: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(work != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { logs = RecordingAppLogs.load(fromPackage: session.directoryURL) }
    }

    private func run(copy: Bool) {
        failure = nil
        progress = 0
        let format = format, includesLogs = attachLogs
        work = Task {
            defer { work = nil }
            do {
                let (steps, stills) = try await RecordingStepsExport.prepare(
                    session: session, document: try document(), includesLogs: includesLogs) { value in
                        Task { @MainActor in progress = value }
                    }
                let folder = try RecordingStepsExport.write(steps, format: format, stills: stills)
                if copy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(steps.markdown(format, localFolder: folder), forType: .string)
                    AccessibilityNotification.Announcement("Steps copied as Markdown").post()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                dismiss()
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                failure = error.localizedDescription
            }
        }
    }
}
