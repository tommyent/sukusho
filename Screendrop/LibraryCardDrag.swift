import AppKit
import UniformTypeIdentifiers

extension LibrarySavedCard {
    func dragWriter() throws -> NSPasteboardWriting? {
        switch self {
        case .capture(let item):
            var file = item.fileURL
            if item.isVideo, let session = item.session ?? RecordingDeliverable.session(for: file) {
                StudioProjectRegistry.shared.flushDrafts()
                try RecordingPackageMedia.validateRenderInputs(in: session.directoryURL)
                let edits = try session.editDocumentForRendering()
                guard let ready = RecordingSessionRenderer.readyDeliverable(for: session, editDocument: edits) else {
                    return LibraryRecordingPromise.provider(for: session, edits: edits, name: item.name)
                }
                file = ready
            }
            return try ClipboardFiles.withClipboardSnapshots(of: [file], name: {
                CaptureLibraryFiles.fileName(item.name, ext: $0.pathExtension)
            }) { $0[0] as NSURL }
        case .clip(let entry):
            switch entry.kind {
            case .image: return try entry.imageSnapshot() as NSURL
            case .text, .snippet:
                return try ClipboardFiles.withSnapshotDirectory { try entry.textTransfer.write(to: $0) as NSURL }
            case .files:
                let urls = try entry.fileTransferURLs()
                guard let first = urls.first else { return nil }
                return urls.count == 1 ? first as NSURL : LibraryFileGroup(urls: urls)
            }
        }
    }
}

// AppKit requests one writer per card. A clipboard card can represent several files.
final class LibraryFileGroup: NSPasteboardItem {
    let urls: [URL]
    required init?(pasteboardPropertyList: Any, ofType: NSPasteboard.PasteboardType) { return nil }

    init(urls: [URL]) {
        self.urls = urls
        super.init()
        setString(urls[0].absoluteString, forType: .fileURL)
    }
}

private final class LibraryRecordingPromise: NSObject, NSFilePromiseProviderDelegate {
    let session: RecordingSession
    let edits: RecordingEditDocument?
    let name: String

    init(session: RecordingSession, edits: RecordingEditDocument?, name: String) {
        self.session = session
        self.edits = edits
        self.name = name
    }

    static func provider(for session: RecordingSession, edits: RecordingEditDocument?, name: String) -> NSFilePromiseProvider {
        let container = (edits?.exportSettings ?? RecordingExportPreferences.lastSettings).effectiveContainer
        let delegate = LibraryRecordingPromise(session: session, edits: edits,
                                               name: CaptureLibraryFiles.fileName(name, ext: container.fileExtension))
        let provider = NSFilePromiseProvider(fileType: container.contentType.identifier, delegate: delegate)
        provider.userInfo = delegate // AppKit holds a weak delegate until the destination requests the file.
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                let file = try await RecordingSessionRenderer.ensureDeliverable(for: session, editDocument: edits)
                try await VideoFileActions.save(from: file, to: url, replacingExisting: false)
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
}
