import AppKit
import SwiftUI
import UserNotifications

/// File requests and what clients send through them: the open links, a new
/// link (shown once), a look for new received files every few minutes while
/// a link is open, their notification, and downloads.
@MainActor
@Observable
final class FileRequestsModel {
    static let shared = FileRequestsModel()

    static let autoDownloadKey = "cloudReceivedAutoDownload"
    static let downloadFolderKey = "cloudReceivedDownloadFolder"
    nonisolated static let notificationKey = "receivedUploadIDs"
    // shortcut: polls GET /api/uploads?received=1 every 5 minutes while a link is open (288 Worker
    // requests a day at most) and only while Sukusho runs; email from the Worker when there's a domain.
    private static let pollInterval = Duration.seconds(300)
    private static let knownKeyPrefix = "cloudReceivedKnown."

    private(set) var openRequests: [CloudFileRequest] = []
    private(set) var isCreating = false
    private(set) var closingIDs: Set<String> = []
    private(set) var downloadingIDs: Set<String> = []
    /// Shown in the Request Files sheet and the open links' popover.
    var errorMessage: String?
    var showsSheet = false
    var showsOpenLinks = false
    private var pollTask: Task<Void, Never>?

    private init() {}

    /// At launch: the open links, and one look for files sent while Sukusho was quit.
    func start() {
        guard CloudUploader.shared.isConfigured else { return }
        Task {
            await refreshRequests()
            await checkReceived()
        }
    }

    func refreshRequests() async {
        guard let owner = CloudUploader.shared.ownerAccess,
              let request = CloudFileRequestAPI.listRequest(workerBase: owner.workerBase, token: owner.token) else { return }
        do {
            openRequests = try CloudFileRequestAPI.decodeList(try await Self.send(request))
        } catch {
            errorMessage = error.localizedDescription
        }
        schedulePoll()
    }

    /// Creates a link and copies it; the answer is the only time the Worker shows it.
    func create(_ draft: CloudFileRequestDraft) async -> CloudFileRequest? {
        guard let owner = CloudUploader.shared.ownerAccess,
              let request = CloudFileRequestAPI.createRequest(workerBase: owner.workerBase, token: owner.token, draft: draft) else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try CloudFileRequestAPI.decodeCreated(try await Self.send(request))
            openRequests.insert(created, at: 0)
            if let link = created.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
            errorMessage = nil
            schedulePoll()
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Closes the link for good. Files already received stay.
    func close(_ fileRequest: CloudFileRequest) {
        guard let owner = CloudUploader.shared.ownerAccess,
              let request = CloudFileRequestAPI.closeRequest(workerBase: owner.workerBase, token: owner.token, id: fileRequest.id),
              closingIDs.insert(fileRequest.id).inserted else { return }
        Task {
            defer { closingIDs.remove(fileRequest.id) }
            do {
                _ = try await Self.send(request)
                openRequests.removeAll { $0.id == fileRequest.id }
                schedulePoll()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func checkReceived() async {
        guard let uploads = try? await CloudUploader.shared.listUploads(received: true) else { return }
        notice(uploads)
    }

    /// Every full list of uploads comes here: received files not seen before
    /// get a notification, and download if Settings › Cloud says so.
    func notice(_ uploads: [CloudUpload]) {
        guard let workerBase = CloudUploader.shared.workerBase else { return }
        let key = Self.knownKeyPrefix + workerBase
        let known = (UserDefaults.standard.array(forKey: key) as? [String]).map(Set.init)
        let fresh = ReceivedFiles.newFiles(in: uploads, known: known)
        UserDefaults.standard.set(ReceivedFiles.known(after: uploads).sorted(), forKey: key)
        guard !fresh.isEmpty else { return }
        Self.notify(fresh)
        if UserDefaults.standard.bool(forKey: Self.autoDownloadKey) { download(fresh, reveal: false) }
        // The Library and the requests' tallies catch up.
        CloudLibraryModel.shared.refresh()
        Task { await refreshRequests() }
    }

    static var downloadFolder: URL {
        guard let path = UserDefaults.standard.string(forKey: downloadFolderKey), !path.isEmpty else { return .downloadsDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Downloads received files with the owner's token into the download
    /// folder, never over a file already there.
    func download(_ uploads: [CloudUpload], reveal: Bool = true) {
        guard let owner = CloudUploader.shared.ownerAccess else { return }
        let targets = uploads.filter { $0.isReceived && downloadingIDs.insert($0.id).inserted }
        guard !targets.isEmpty else { return }
        let folder = Self.downloadFolder
        Task {
            var saved: [URL] = []
            var failures: [String] = []
            for upload in targets {
                do {
                    let file = try await ReceivedFiles.download(upload, workerBase: owner.workerBase, token: owner.token, into: folder)
                    saved.append(file)
                    // The card's thumbnail and Quick Look use this copy.
                    try? CloudPreviewCache.shared.adopt(file, for: upload)
                } catch {
                    failures.append("\(upload.filename): \(error.localizedDescription)")
                }
                downloadingIDs.remove(upload.id)
            }
            if !saved.isEmpty { CloudLibraryModel.shared.previewRevision += 1 }
            if reveal, !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
            if !failures.isEmpty {
                CaptureLibraryModel.shared.errorMessage = "Couldn’t download:\n" + failures.joined(separator: "\n")
            }
        }
    }

    /// Opens the Library on Received with these files selected, as a notification's click does.
    static func showReceived(_ ids: [String]) {
        CaptureLibraryModel.shared.show()
        CloudLibraryModel.shared.showReceived(selecting: ids)
    }

    private func schedulePoll() {
        guard openRequests.contains(where: { $0.expiresAt > .now }) else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled, openRequests.contains(where: { $0.expiresAt > .now }) {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
                await checkReceived()
            }
            pollTask = nil
        }
    }

    /// A 2xx answer's body; otherwise the Worker's own error text.
    nonisolated private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        if status == 404, request.url?.path == "/api/requests" { throw FileRequestError.unavailable }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw FileRequestError.worker(status, message)
    }

    private static func notify(_ files: [CloudUpload]) {
        let text = ReceivedFiles.notificationText(for: files)
        let ids = files.map(\.id)
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            content.userInfo = [notificationKey: ids]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

nonisolated enum FileRequestError: LocalizedError {
    case unavailable
    case worker(Int, String?)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Update your Worker to use file requests."
        case .worker(_, let message?): message
        case .worker(let status, nil): "The Worker answered with HTTP \(status)."
        }
    }
}

/// Request Files: a new link (message, password, expiry, caps), shown once
/// and copied, and the open links with Close.
struct FileRequestsSheet: View {
    @State private var model = FileRequestsModel.shared
    @State private var draft = CloudFileRequestDraft()
    @State private var created: CloudFileRequest?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Request Files").font(.headline)
            if let created, let link = created.url {
                Text("Send this link to the person who has the files. It works until \(Self.date(created.expiresAt)), and it’s shown only now. It’s on the clipboard.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(link)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                }
                HStack {
                    Spacer()
                    Button("New Request") {
                        self.created = nil
                        draft = CloudFileRequestDraft()
                    }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Message", text: $draft.message, prompt: Text("What to send (optional)"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Text("Password")
                Spacer()
                SecureField("Password", text: $draft.password, prompt: Text("Optional"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            .help("The client needs it to send files. Up to 128 characters.")
            HStack {
                Text("Link expires")
                Spacer()
                Picker("Link expires", selection: $draft.expiry) {
                    ForEach(CloudFileRequestAPI.expiryChoices) { Text("In \($0.title)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Files")
                Spacer()
                Stepper(value: $draft.maxFiles, in: CloudFileRequestAPI.fileCountRange) { Text(draft.maxFiles, format: .number).monospacedDigit() }
            }
            HStack {
                Text("Each file up to")
                Spacer()
                Picker("Each file up to", selection: $draft.maxFileBytes) {
                    ForEach(CloudFileRequestAPI.fileSizeChoices, id: \.self) { Text(Self.bytes($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("All files up to")
                Spacer()
                Picker("All files up to", selection: $draft.maxTotalBytes) {
                    ForEach(CloudFileRequestAPI.totalSizeChoices, id: \.self) { Text(Self.bytes($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("The page asks the sender to pass a bot check. What they send is private to you and isn’t scanned for malware.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Link") {
                    Task { created = await model.create(draft) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid || model.isCreating)
            }
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    private static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func summary(_ request: CloudFileRequest) -> String {
        "\(request.filesReceived) of \(request.maxFiles) files · \(bytes(request.bytesReceived)) of \(bytes(request.maxTotalBytes)) · until \(date(request.expiresAt))"
            + (request.hasPassword ? " · password" : "")
    }
}

/// The Received toolbar's "Manage": how many links are open, and a popover to close them.
/// Hidden while none is open.
struct FileRequestsManageButton: View {
    @State private var model = FileRequestsModel.shared

    var body: some View {
        let open = model.openRequests.count
        if open > 0 {
            Button {
                model.showsOpenLinks.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("Manage")
                    Text(open, format: .number).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .help("Open links people can use to send you files")
            .accessibilityLabel("Manage open links, \(open) open")
            .popover(isPresented: $model.showsOpenLinks, arrowEdge: .bottom) {
                FileRequestsOpenLinks()
            }
        }
    }
}

/// The open links, newest first, each closed with its X after a confirmation.
struct FileRequestsOpenLinks: View {
    @State private var model = FileRequestsModel.shared
    @State private var pendingClose: CloudFileRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open Links").font(.headline).padding([.horizontal, .top], 8)
            if model.openRequests.isEmpty {
                Text("No open links.").foregroundStyle(.secondary).padding(8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.openRequests) { request in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.message.isEmpty ? "No message" : request.message)
                                    .lineLimit(1)
                                    .foregroundStyle(request.message.isEmpty ? .secondary : .primary)
                                Text(FileRequestsSheet.summary(request)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Close Link…", systemImage: "xmark.circle.fill") { pendingClose = request }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Close this link")
                                .disabled(model.closingIDs.contains(request.id))
                        }
                        .padding(8)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(8)
            }
        }
        .padding(8)
        .frame(width: 340)
        .task { await model.refreshRequests() }
        .alert("Close this link?", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
               presenting: pendingClose) { request in
            Button("Close Link", role: .destructive) { model.close(request) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Nobody can send files with it anymore. Files already received stay in Received.")
        }
    }
}

/// Settings › Cloud: where received files download, and whether they do on their own.
struct ReceivedFilesSettingsSection: View {
    @AppStorage(FileRequestsModel.autoDownloadKey) private var autoDownload = false
    @AppStorage(FileRequestsModel.downloadFolderKey) private var folderPath = ""

    var body: some View {
        Section {
            Toggle("Download received files automatically", isOn: $autoDownload)
            LabeledContent("Download to") {
                HStack(spacing: 8) {
                    Text(folderPath.isEmpty ? "Downloads" : (folderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { choose() }
                }
            }
        } header: {
            Text("Received Files")
        } footer: {
            Text("Files clients send through your file requests. While one of your requests is open and Sukusho is running, it checks every 5 minutes and notifies you of new files.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = FileRequestsModel.downloadFolder
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            folderPath = url.path(percentEncoded: false)
        }
    }
}
