//
//  AgentAccessApp.swift
//  Screendrop
//
//  Agent access inside the app: the switch in Settings › Agents, the socket
//  while it's on, the tools' work through the Library's own code, and the
//  windows that ask the owner.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class AgentAccess {
    static let shared = AgentAccess()
    static let enabledKey = "agentAccessEnabled"
    /// Passed by the helper when it starts the app, which then stays in the menu bar.
    static let launchArgument = "--agent-launch"

    let grants = AgentGrantStore()
    let log = AgentActivityLog(fileURL: ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Agent Activity.json"))
    @ObservationIgnored let server: AgentAccessServer
    private(set) var errorMessage: String?
    /// The latest connection Sukusho turned away, and why.
    private(set) var lastRefusal: String?

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            apply()
        }
    }

    static var socketPath: String {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("mcp.sock").path
    }

    var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + AgentPeerPolicy.helperName).path
    }

    /// What Claude Code needs to add Sukusho.
    var addCommand: String { "claude mcp add sukusho -- '\(helperPath)'" }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let toolbox = AgentToolbox(backend: AgentLiveBackend(), asker: AgentApprovalPresenter(), grants: grants, log: log)
        server = AgentAccessServer(toolbox: toolbox)
        server.onRefusal = { [weak self] reason in self?.lastRefusal = reason }
    }

    func start() { apply() }

    private func apply() {
        guard isEnabled else {
            server.stop()
            errorMessage = nil
            return
        }
        guard !server.isRunning else { return }
        do {
            try server.start(path: Self.socketPath, policy: .current())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() { server.stop() }
}

// MARK: - The Library's own code

@MainActor
final class AgentLiveBackend: AgentBackend {
    var cloud: AgentCloud? {
        CloudUploader.shared.ownerAccess.map { AgentCloud(workerBase: $0.workerBase, token: $0.token) }
    }

    /// What a share that skips Share Options gets, as the shake shelf's Option-drop does.
    var defaultShare: AgentShareSettings {
        let saved = CloudUploadOptions.savedDefaults
        return AgentShareSettings(title: nil, expiry: saved.expiry, comments: saved.socialEnabled,
                                  anonymousComments: saved.allowAnonymousComments)
    }

    func libraryItems() -> [AgentItem] {
        CaptureLibraryModel.shared.items.map(Self.item)
    }

    static func item(_ item: CaptureLibraryItem) -> AgentItem {
        AgentItem(id: item.id, title: item.title, kind: item.session != nil ? "recording" : item.isVideo ? "video" : "screenshot",
                  createdAt: item.createdAt, width: item.pixelWidth, height: item.pixelHeight, duration: item.duration,
                  tags: item.tags, source: item.source, cloudURL: item.cloudURL, fileURL: item.fileURL,
                  foldedText: CaptureLibraryIndex.shared.foldedText[item.id])
    }

    /// The Open With path: a copy in History, then the Library's next scan lists it.
    func addImages(_ files: [URL], title: String?, tags: [String]) async -> [AgentItem] {
        var ids: [UUID] = []
        for file in files {
            let imported = ScreenshotHistoryStore.shared.importScreenshot(from: file)
            guard imported != file, let row = ScreenshotHistoryStore.shared.item(for: imported) else { continue }
            ids.append(row.id)
        }
        if let title { for id in ids { ScreenshotHistoryStore.shared.rename(id: id, to: title) } }
        for tag in tags { ScreenshotHistoryStore.shared.setTag(tag, applied: true, ids: Set(ids)) }
        return await listed(ids.map(\.uuidString))
    }

    /// The Library's items with these IDs, once a scan has listed them all.
    private func listed(_ ids: [String]) async -> [AgentItem] {
        CaptureLibraryModel.shared.refresh()
        for _ in 0..<50 {
            let items = Dictionary(CaptureLibraryModel.shared.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if ids.allSatisfy({ items[$0] != nil }) { return ids.compactMap { items[$0].map(Self.item) } }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let items = CaptureLibraryModel.shared.items
        return ids.compactMap { id in items.first { $0.id == id }.map(Self.item) }
    }

    func text(of item: AgentItem) -> String? {
        guard let entry = CaptureLibraryIndex.shared.entries[item.id] else { return nil }
        let text = (entry.displayParagraphs + [entry.transcript].compactMap { $0 }).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func jpeg(of item: AgentItem, maxPixels: Int) async -> Data? {
        let url = item.fileURL
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let thumbnail = try? CloudGalleryAPI.thumbnail(of: url, maxPixels: maxPixels) else { return nil }
            return thumbnail.jpeg
        }.value
    }

    /// The Library's Share to Cloud path, without copying the link: the agent gets it.
    func shareOne(_ item: AgentItem, settings: AgentShareSettings) async throws -> AgentShareResult {
        guard let library = CaptureLibraryModel.shared.items.first(where: { $0.id == item.id }) else {
            throw AgentToolError("The capture is gone from the Library.")
        }
        StudioProjectRegistry.shared.flushDrafts()
        if let session = library.session, library.historyIDs.isEmpty {
            _ = await ScreenshotHistoryStore.shared.importRecordingSession(session)
        }
        let id = library.historyIDs.first ?? ScreenshotHistoryStore.shared.items.first {
            $0.recordingSessionPath == library.session?.directoryURL.standardizedFileURL.path
        }?.id ?? UUID()
        let result = try await CloudUploader.shared.upload(
            itemID: id, fileURL: library.fileURL, title: settings.title, socialEnabled: settings.comments,
            expiresAt: settings.expiry.date(), allowAnonymousComments: settings.anonymousComments,
            password: settings.password, encrypt: settings.encrypted)
        ScreenshotHistoryStore.shared.setLibraryCloudURL(id: id, cloudURL: result.url)
        CaptureLibraryModel.shared.refresh()
        let image = item.isImage && settings.password == nil && !settings.encrypted
        return AgentShareResult(id: result.id, url: result.url, title: settings.title ?? item.title,
                                expiresAt: result.expiryIgnored ? nil : settings.expiry.date(), hasPassword: settings.password != nil,
                                thumbnailURL: image ? cloud.map { $0.workerBase + "/api/image/" + result.id } : nil,
                                isGallery: false, uploadIDs: [])
    }

    /// The Library's gallery path.
    func shareGallery(_ items: [AgentItem], settings: AgentShareSettings) async throws -> AgentShareResult {
        guard let share = CloudGalleryShare.configured() else { throw CloudUploadError.notConfigured }
        StudioProjectRegistry.shared.flushDrafts()
        let shared = try await share.share(items.map { CloudGalleryShare.Image(fileURL: $0.fileURL, title: $0.title) },
                                           settings: .init(title: settings.title, expiresAt: settings.expiry.date(), password: settings.password,
                                                           socialEnabled: settings.comments, allowAnonymousComments: settings.anonymousComments)) { _ in }
        let library = Dictionary(CaptureLibraryModel.shared.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (item, uploaded) in zip(items, shared.items) where item.cloudURL == nil {
            if let id = library[item.id]?.historyIDs.first { ScreenshotHistoryStore.shared.setLibraryCloudURL(id: id, cloudURL: uploaded.url) }
        }
        CaptureLibraryModel.shared.refresh()
        return AgentShareResult(id: shared.gallery.id, url: shared.gallery.url, title: shared.gallery.title ?? settings.title ?? "Gallery",
                                expiresAt: shared.gallery.expiresAt, hasPassword: shared.gallery.hasPassword,
                                thumbnailURL: shared.gallery.hasPassword ? nil : shared.gallery.coverUrl, isGallery: true,
                                uploadIDs: shared.items.map(\.id))
    }

    /// The Request Files path: the link is copied and kept for Manage, as from the sheet.
    func createFileRequest(_ draft: CloudFileRequestDraft) async throws -> CloudFileRequest {
        let model = FileRequestsModel.shared
        guard let created = await model.create(draft) else {
            throw AgentToolError(model.errorMessage ?? "Sukusho couldn’t make the request.")
        }
        return created
    }

    /// As the Uploads page's own delete: the cards lose those links, a gallery's images included.
    func cloudDidChange(deleted: Set<String>) {
        if !deleted.isEmpty {
            let history = ScreenshotHistoryStore.shared
            for row in history.items where CloudUploadList.uploadID(of: row.cloudURL).map(deleted.contains) == true {
                history.setLibraryCloudURL(id: row.id, cloudURL: nil)
            }
            for id in deleted {
                CloudShareLinks.forget(uploadID: id)
                CloudPreviewCache.shared.remove(id)
            }
            CaptureLibraryModel.shared.refresh()
        }
        CloudLibraryModel.shared.refresh()
        Task { await FileRequestsModel.shared.refreshRequests() }
    }

    func latestAgentPrompt() -> AgentPromptInfo? {
        let directory = RecordingAgentPromptWriter.directoryURL()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("latest.json")),
              let latest = try? decoder.decode(RecordingAgentPromptWriter.Latest.self, from: data),
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: latest.path).appendingPathComponent("prompt.md").path)
        else { return nil }
        return AgentPromptInfo(folder: URL(fileURLWithPath: latest.path, isDirectory: true), title: latest.title,
                               recording: latest.recording, time: latest.time)
    }

    /// The Library's Agent Prompt export, which also plays the ready chime.
    func exportAgentPrompt(_ item: AgentItem) async throws -> AgentPromptInfo {
        guard let session = CaptureLibraryModel.shared.items.first(where: { $0.id == item.id })?.session else {
            throw AgentToolError("That recording is gone from the Library.")
        }
        guard await CaptureLibraryModel.shared.exportBugReport(session), let latest = latestAgentPrompt() else {
            throw AgentToolError(CaptureLibraryModel.shared.errorMessage ?? "The export failed.")
        }
        return latest
    }

    /// The App Intents' capture paths.
    func capture(_ mode: AgentCaptureMode) async -> AgentCaptureOutcome {
        switch mode {
        case .full:
            guard let url = await CaptureCoordinator.shared.captureFullscreenAwaiting() else { return .cancelled }
            guard let row = ScreenshotHistoryStore.shared.item(for: url),
                  let item = await listed([row.id.uuidString]).first else { return .failed("The screenshot didn’t reach the Library.") }
            return .captured(item)
        case .text:
            switch await CaptureCoordinator.shared.captureTextAwaiting() {
            case .cancelled: return .cancelled
            case .noTextFound: return .noText
            case .copied(let text): return .text(text)
            }
        }
    }
}

// MARK: - Asking the owner

/// Sukusho's own windows for the asks: Share Options and Request Files,
/// prefilled, or a short Allow/Deny. Each answers once; closing it is a no.
@MainActor
final class AgentApprovalPresenter: AgentAsker {
    private var panels: [AgentPanel] = []

    func askShare(_ ask: AgentAsk, settings: AgentShareSettings,
                  answer: @escaping ((decision: AgentDecision, settings: AgentShareSettings)?) -> Void) -> () -> Void {
        let choice = AgentChoice()
        let once = AgentOnce()
        var panel: AgentPanel?
        let finish: (((decision: AgentDecision, settings: AgentShareSettings))?) -> Void = { value in
            guard once.first() else { return }
            answer(value)
            panel?.close()
        }
        panel = present(Self.shareView(ask, settings: settings, choice: choice, finish: finish)) { finish(nil) }
        return { panel?.close() }
    }

    func askFileRequest(_ ask: AgentAsk, draft: CloudFileRequestDraft,
                        answer: @escaping ((decision: AgentDecision, draft: CloudFileRequestDraft)?) -> Void) -> () -> Void {
        let choice = AgentChoice()
        let once = AgentOnce()
        var panel: AgentPanel?
        let finish: (((decision: AgentDecision, draft: CloudFileRequestDraft))?) -> Void = { value in
            guard once.first() else { return }
            answer(value)
            panel?.close()
        }
        panel = present(Self.fileRequestView(ask, draft: draft, choice: choice, finish: finish)) { finish(nil) }
        return { panel?.close() }
    }

    func ask(_ ask: AgentAsk, answer: @escaping (AgentDecision?) -> Void) -> () -> Void {
        let choice = AgentChoice()
        let once = AgentOnce()
        var panel: AgentPanel?
        let finish: (AgentDecision?) -> Void = { value in
            guard once.first() else { return }
            answer(value)
            panel?.close()
        }
        panel = present(Self.plainView(ask, choice: choice, finish: finish)) { finish(nil) }
        return { panel?.close() }
    }

    /// Share Options, prefilled, under who is asking: Allow or Deny, or Upload or Cancel for a hand-off.
    static func shareView(_ ask: AgentAsk, settings: AgentShareSettings, choice: AgentChoice,
                          finish: @escaping (((decision: AgentDecision, settings: AgentShareSettings))?) -> Void) -> some View {
        let initial = CloudUploadOptions(title: settings.title ?? "", socialEnabled: settings.comments, expiry: settings.expiry,
                                         allowAnonymousComments: settings.anonymousComments)
        return AgentApprovalView(ask: ask, choice: choice) {
            CloudUploadOptionsPopover(
                suggestedTitle: settings.title ?? "",
                encryptionUnavailable: ask.encryptionUnavailable,
                initial: initial, focusesPassword: !ask.grantable,
                confirmTitle: ask.grantable ? "Allow" : "Upload", cancelTitle: ask.grantable ? "Deny" : "Cancel",
                onCancel: { finish(nil) }
            ) { options in
                finish((choice.decision, AgentShareSettings(title: options.trimmedTitleOrNil, expiry: options.expiry, password: options.password,
                                                            comments: options.socialEnabled, anonymousComments: options.allowAnonymousComments,
                                                            encrypted: options.encrypted)))
            }
        }
    }

    /// Request Files, prefilled.
    static func fileRequestView(_ ask: AgentAsk, draft: CloudFileRequestDraft, choice: AgentChoice,
                                finish: @escaping (((decision: AgentDecision, draft: CloudFileRequestDraft))?) -> Void) -> some View {
        AgentApprovalView(ask: ask, choice: choice) {
            FileRequestsSheet(draft: draft, focusesPassword: !ask.grantable, submitTitle: ask.grantable ? "Allow" : "Create Link",
                              cancelTitle: ask.grantable ? "Deny" : "Cancel", onCancel: { finish(nil) }) { draft in
                finish((choice.decision, draft))
            }
        }
    }

    static func plainView(_ ask: AgentAsk, choice: AgentChoice, finish: @escaping (AgentDecision?) -> Void) -> some View {
        AgentApprovalView(ask: ask, choice: choice) {
            HStack {
                Spacer()
                Button("Deny") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Allow") { finish(choice.decision) }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
    }

    private func present<Content: View>(_ view: Content, onClose: @escaping () -> Void) -> AgentPanel {
        let panel = AgentPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Sukusho"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: view)
        panel.onClose = { [weak self, weak panel] in
            onClose()
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        let offset = CGFloat(panels.count - 1) * 24
        panel.center()
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + offset, y: panel.frame.minY - offset))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        AccessibilityNotification.Announcement("Sukusho is asking about an agent’s request").post()
        return panel
    }
}

/// The first of several calls.
@MainActor
private final class AgentOnce {
    private var done = false
    func first() -> Bool {
        defer { done = true }
        return !done
    }
}

@MainActor
@Observable
final class AgentChoice {
    var decision = AgentDecision.once
}

final class AgentPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    func windowWillClose(_ notification: Notification) {
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}

/// Who is asking and for what, above the sheet that answers.
struct AgentApprovalView<Content: View>: View {
    let ask: AgentAsk
    @Bindable var choice: AgentChoice
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ask.agent.displayName) wants to \(ask.action)")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(ask.agent.signerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("The program that started Sukusho’s helper. Grants are kept for this program and agent name together.")
                    }
                }
                if !ask.thumbnails.isEmpty { AgentThumbnails(urls: ask.thumbnails) }
                if !ask.details.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(ask.details.enumerated()), id: \.offset) { Text($0.element) }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if ask.grantable {
                    Picker("Allow", selection: $choice.decision) {
                        ForEach(AgentDecision.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    if choice.decision == .always, ask.group == .publish {
                        Text("Covers only what this agent adds or creates. Anything else from the Library still asks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Type the password here. The agent never sees it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let deadline = ask.deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text("No answer in \(left) s counts as Deny.")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)
            content
        }
        .frame(minWidth: 300)
        .fixedSize()
    }
}

private struct AgentThumbnails: View {
    let images: [NSImage]

    init(urls: [URL]) {
        images = urls.prefix(6).compactMap { ScreenshotImageLoader.downsampledImage(at: $0, maxPixelSize: 160) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator))
            }
        }
        .accessibilityHidden(true)
    }
}
