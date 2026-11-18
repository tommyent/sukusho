import AppKit

/// The native share sheet accepts strings directly. Export and Cloud use files.
nonisolated enum LibraryTransferValue {
    case text(String, name: String)
    case file(URL, name: String)

    var sharingItem: Any {
        switch self {
        case .text(let text, _): text
        case .file(let url, _): url
        }
    }

    func write(to directory: URL) throws -> URL {
        switch self {
        case .file(let url, let name):
            return try CaptureLibraryFiles.export(url, name: name, to: directory)
        case .text(let text, let name):
            return try CaptureLibraryFiles.export(name: name, ext: "txt", to: directory) {
                try Data(text.utf8).write(to: $0, options: .withoutOverwriting)
            }
        }
    }
}

extension LibrarySavedCard {
    func transferValues() async throws -> [LibraryTransferValue] {
        switch self {
        case .capture(let item):
            let url = item.isVideo ? try await RecordingDeliverable.resolve(for: item.fileURL) : item.fileURL
            return [.file(url, name: item.name)]
        case .clip(let entry):
            switch entry.kind {
            case .text, .snippet:
                return [.text(entry.text ?? "", name: entry.title.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "Text")]
            case .image:
                let url = try entry.imageSnapshot()
                return [.file(url, name: String(ClipboardList.title(of: entry).prefix(60)))]
            case .files:
                return try entry.filePaths.map { path in
                    guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
                    let url = URL(fileURLWithPath: path)
                    return .file(url, name: url.lastPathComponent)
                }
            }
        }
    }
}

/// Snapshot the files until Share Options is dismissed or the last upload finishes.
final class LibraryClipUpload: Identifiable {
    let directory: URL
    private(set) var sources: [LibraryUploadSource<CaptureLibraryItem>] = []
    private(set) var includesRecording = false
    private(set) var owners: [URL: (id: String, position: Int)] = [:]

    init(cards: [LibrarySavedCard]) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "Sukusho-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for card in cards {
            if case .capture(let item) = card {
                sources.append(.capture(item, url: item.fileURL))
                includesRecording = includesRecording || item.isVideo
                continue
            }
            for (position, value) in try await card.transferValues().enumerated() {
                if case .file(let url, _) = value, CloudLibraryModel.regularFiles([url]).isEmpty {
                    throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Choose files inside a folder to upload them."])
                }
                let file = try await Task.detached(priority: .userInitiated) { [directory] in try value.write(to: directory) }.value
                sources.append(.file(file))
                if let id = card.clipID { owners[file] = (id, position) }
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func upload(options: CloudUploadOptions) {
        StudioProjectRegistry.shared.flushDrafts()
        CloudLibraryModel.shared.uploadSelection(sources, options: options, didUpload: { [self] file, link in
            if let owner = owners[file], let store = ClipboardMonitor.shared.store {
                try await store.setCloudLink(link, entry: owner.id, position: owner.position)
            }
        }) { copied, _ in
            ClipboardHistoryModel.shared.refresh()
            if copied > 0 { CaptureLibraryModel.shared.actionFeedback.show(ActionFeedback.linksCopied(copied)) }
        }
    }
}

extension CaptureLibraryModel {
    func shareSelection(_ cards: [LibrarySavedCard]) {
        run("Preparing share…") {
            StudioProjectRegistry.shared.flushDrafts()
            var values: [LibraryTransferValue] = []
            for card in cards { values += try await card.transferValues() }
            LibrarySharing.show(values.map(\.sharingItem))
        }
    }

    func prepareClipUpload(_ cards: [LibrarySavedCard]) {
        guard CloudLibraryModel.shared.fileUploads == nil else { return }
        run("Preparing upload…") {
            self.pendingClipUpload = try await LibraryClipUpload(cards: cards)
        }
    }
}
