//
//  ScreenshotHistoryStore.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import Observation

extension ScreenshotHistoryItem {
    var recordingSession: RecordingSession? {
        guard let recordingSessionPath else { return nil }
        let session = RecordingSession(directoryURL: URL(fileURLWithPath: recordingSessionPath, isDirectory: true))
        return RecordingSession.isSessionDirectory(session.directoryURL) ? session : nil
    }

    var url: URL {
        if let recordingSession {
            return recordingSession.deliverableURL
        }
        return ScreenshotHistoryStore.historyDirectory.appendingPathComponent(fileName)
    }

    var editorURL: URL {
        recordingSession?.directoryURL ?? url
    }
}

@MainActor
@Observable
final class ScreenshotHistoryStore {
    static let shared = ScreenshotHistoryStore()

    static var historyDirectory: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("History", isDirectory: true)
    }

    private static var metadataURL: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("history.json")
    }

    private static var savedMarksURL: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("library-saved.json")
    }

    /// Location of the editable annotation sidecar document for a display image,
    /// e.g. `shot.png` -> `shot.png.sukusho` (`shot.png.screendrop` where an
    /// older capture already has one).
    nonisolated static func editDocumentURL(for displayURL: URL) -> URL {
        SukushoFileNames.editDocumentURL(for: displayURL)
    }

    /// Location of the base image the annotations are drawn on (cropped, if
    /// the capture was), e.g. `shot.png` -> `shot.base.png`.
    nonisolated static func baseImageURL(for displayURL: URL) -> URL {
        taggedImageURL(for: displayURL, tag: "base")
    }

    /// Location of the image as captured, kept from the first save of an edit
    /// and never overwritten, e.g. `shot.png` -> `shot.original.png`.
    nonisolated static func originalImageURL(for displayURL: URL) -> URL {
        taggedImageURL(for: displayURL, tag: "original")
    }

    /// The files an edited screenshot keeps beside its display image. They
    /// go wherever the capture goes.
    nonisolated static func companionURLs(for displayURL: URL) -> [URL] {
        [editDocumentURL(for: displayURL), baseImageURL(for: displayURL), originalImageURL(for: displayURL), sessionSnapshotsURL(for: displayURL)]
    }

    nonisolated static func sessionSnapshotsURL(for displayURL: URL) -> URL {
        displayURL.appendingPathExtension("sessions")
    }

    nonisolated private static func taggedImageURL(for displayURL: URL, tag: String) -> URL {
        let ext = displayURL.pathExtension
        let stem = displayURL.deletingPathExtension().lastPathComponent
        let directory = displayURL.deletingLastPathComponent()
        let fileName = ext.isEmpty ? "\(stem).\(tag)" : "\(stem).\(tag).\(ext)"
        return directory.appendingPathComponent(fileName)
    }

    /// Loads the editable annotation document for a screenshot, if one exists.
    func loadEditDocument(for displayURL: URL) throws -> AnnotationDocument? {
        try AnnotationDocument.load(from: Self.editDocumentURL(for: displayURL))
    }

    func hasEditDocument(for displayURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: Self.editDocumentURL(for: displayURL).path)
    }

    @ObservationIgnored private var files = MarkedHistory<ScreenshotHistoryItem>(historyURL: ScreenshotHistoryStore.metadataURL, marksURL: ScreenshotHistoryStore.savedMarksURL)
    /// False when history.json, or a row in it, couldn't be read, so `items`
    /// may be missing captures that still exist.
    var isFullyLoaded: Bool { !files.history.isReadOnly }
    /// Why Saved marks can't be read or written, for the Library to show; nil when all is well.
    private(set) var savedMarksProblem: String?

    private(set) var items: [ScreenshotHistoryItem] = []

    @ObservationIgnored private var reservedHistoryURLs: Set<URL> = []
    var recentItems: [ScreenshotHistoryItem] {
        Array(items.prefix(5))
    }

    private init() {
        load(launchDefaults: .standard)
    }

    /// An outside file open in the editor that becomes a capture on its first saved edit, with these details rather
    /// than the file's: a clipboard image is dated when it was copied and credited to its app (Fable #5).
    struct PendingImport {
        let createdAt: Date
        let source: CaptureSource?
        let title: String?
        /// Told the capture's History URL once it exists, so the clip can link to it.
        let onImport: (URL) -> Void
    }

    /// Keyed by the outside file's standardized path.
    @ObservationIgnored private var pendingImports: [String: PendingImport] = [:]
    /// The capture each outside file became on its first saved edit. The editor keeps the outside file open and saves
    /// again (by itself, after a pause), and each of those saves goes to that capture rather than importing it again.
    @ObservationIgnored private var importedOutsideFiles: [String: URL] = [:]

    func registerPendingImport(_ pending: PendingImport, for fileURL: URL) {
        pendingImports[fileURL.standardizedFileURL.path] = pending
    }

    /// `title` is the Library title for an image the user opened or imported: its own file name, rather than the
    /// History file's `screenshot_…` (Fable #2). It doesn't save the capture, as naming it would. `createdAt` dates it
    /// when that isn't now, such as a clipboard image's copy time.
    @discardableResult
    func importScreenshot(from sourceURL: URL, source: CaptureSource? = nil, title: String? = nil, createdAt: Date? = nil) -> URL {
        do {
            try FileManager.default.createDirectory(at: Self.historyDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueHistoryURL(for: sourceURL)

            if sourceURL != destinationURL {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }

            let imageSize = ScreenshotImageLoader.imageSize(at: destinationURL) ?? .zero
            let item = ScreenshotHistoryItem(
                id: UUID(),
                createdAt: createdAt ?? Date(),
                updatedAt: Date(),
                fileName: destinationURL.lastPathComponent,
                pixelWidth: Int(imageSize.width),
                pixelHeight: Int(imageSize.height),
                displayName: title.flatMap { $0.isEmpty ? nil : $0 },
                source: source
            )
            items.insert(item, at: 0)
            saveMetadata()
            CaptureOptimizer.optimizeNewCapture(destinationURL)
            return destinationURL
        } catch {
            print("Failed to import screenshot into history: \(error)")
            return sourceURL
        }
    }

    func prepareUniqueHistoryURL(extension ext: String = "png") throws -> URL {
        try FileManager.default.createDirectory(at: Self.historyDirectory, withIntermediateDirectories: true)
        let base = ScreenshotFileNaming.fileName(extension: ext)
        var candidate = ScreenshotFileNaming.uniqueURL(for: base, in: Self.historyDirectory)
        if reservedHistoryURLs.contains(candidate.standardizedFileURL) {
            let stem = candidate.deletingPathExtension().lastPathComponent
            for index in 2...10_000 {
                let next = Self.historyDirectory.appendingPathComponent("\(stem)_\(index).\(ext)")
                if !FileManager.default.fileExists(atPath: next.path),
                   !reservedHistoryURLs.contains(next.standardizedFileURL) {
                    candidate = next
                    break
                }
            }
        }
        reservedHistoryURLs.insert(candidate.standardizedFileURL)
        return candidate
    }

    func releaseReservedHistoryURL(_ url: URL) {
        reservedHistoryURLs.remove(url.standardizedFileURL)
    }

    func registerImportedScreenshot(at destinationURL: URL, pixelSize: CGSize, source: CaptureSource? = nil) {
        reservedHistoryURLs.remove(destinationURL.standardizedFileURL)
        let item = ScreenshotHistoryItem(
            id: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            fileName: destinationURL.lastPathComponent,
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height),
            source: source
        )
        items.insert(item, at: 0)
        saveMetadata()
    }

    /// Adds a Studio recording to history without copying its potentially huge
    /// screen master. History owns the package and reopens the complete project
    /// (camera, event sidecar, and project edits), not a detached movie.
    @discardableResult
    func importRecordingSession(_ session: RecordingSession) async -> URL {
        let standardizedPath = session.directoryURL.standardizedFileURL.path
        if let existing = items.first(where: { $0.recordingSessionPath == standardizedPath }) {
            return existing.url
        }
        guard RecordingSession.isSessionDirectory(session.directoryURL) else {
            return session.screenURL
        }

        // The recorder has already persisted this metadata before invoking
        // the completion handler. Prefer it so the preview/editor can appear
        // immediately instead of opening the movie with AVFoundation again.
        let manifest = session.loadCaptureManifest()
        let metadata: (width: Int, height: Int, duration: Double?)
        if let manifest,
           manifest.pixelWidth > 0,
           manifest.pixelHeight > 0,
           manifest.duration > 0 {
            metadata = (
                width: manifest.pixelWidth,
                height: manifest.pixelHeight,
                duration: manifest.duration
            )
        } else {
            metadata = await videoMetadata(at: session.screenURL)
        }
        let displayName = session.directoryURL
            .deletingPathExtension()
            .lastPathComponent
            .appending(".\(VideoExportContainer.default.fileExtension)")
        let item = ScreenshotHistoryItem(
            id: UUID(),
            createdAt: manifest?.createdAt ?? Date(),
            updatedAt: Date(),
            fileName: displayName,
            pixelWidth: metadata.width,
            pixelHeight: metadata.height,
            kind: .video,
            duration: metadata.duration,
            recordingSessionPath: standardizedPath
        )
        items.insert(item, at: 0)
        saveMetadata()
        return session.deliverableURL
    }

    /// Non-destructive annotation commit.
    ///
    /// - Preserves the untouched base image (lazily, on first edit) so future
    ///   edits always re-render from the original pixels.
    /// - Overwrites the display image with the freshly rendered composite.
    /// - Writes the editable `.sukusho` sidecar document so the annotations
    ///   can be re-opened and edited later.
    @discardableResult
    func commitAnnotations(
        displayURL: URL,
        baseURL: URL,
        renderedURL: URL,
        document: AnnotationDocument
    ) throws -> URL {
        _ = try loadEditDocument(for: displayURL)
        guard isHistoryURL(displayURL) else {
            let key = displayURL.standardizedFileURL.path
            if let imported = importedOutsideFiles[key], FileManager.default.fileExists(atPath: imported.path) {
                return try commitAnnotations(displayURL: imported, baseURL: baseURL, renderedURL: renderedURL, document: document)
            }
            // The file as opened, not a crop of it, so History keeps the original, and its name. A clipboard image keeps
            // its own date and app instead, and its clip is linked to the new capture.
            let pending = pendingImports.removeValue(forKey: key)
            let imported = importScreenshot(from: displayURL, source: pending?.source,
                                            title: pending == nil ? displayURL.deletingPathExtension().lastPathComponent : pending?.title,
                                            createdAt: pending?.createdAt)
            guard isHistoryURL(imported) else { throw CocoaError(.fileWriteUnknown) }
            importedOutsideFiles[key] = imported
            pending?.onImport(imported)
            return try commitAnnotations(displayURL: imported, baseURL: baseURL,
                                         renderedURL: renderedURL, document: document)
        }
        let baseDestination = Self.baseImageURL(for: displayURL)
        var replacements: [(source: URL, destination: URL)] = []
        // The image as captured, kept once and never replaced, so a saved crop
        // can still be undone after the editor closes. Before the first edit
        // the display image is the capture; after one, the base is (a crop
        // saved before originals were kept is already in it). The
        // transaction stages every source before installing anything.
        if let source = Self.originalSource(for: displayURL) {
            replacements.append((source, Self.originalImageURL(for: displayURL)))
        }
        // The base is always the image these shapes were drawn on. When that is the display
        // image, an existing base belongs to something else (a pre-v2 sidecar's clean
        // original), and keeping it would drop the marks baked into the display image.
        if baseURL.standardizedFileURL != baseDestination.standardizedFileURL {
            replacements.append((baseURL, baseDestination))
        }
        var document = document
        document.baseImageFileName = baseDestination.lastPathComponent
        let documentData = try JSONEncoder().encode(document)
        let temporaryDocument = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try documentData.write(to: temporaryDocument, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryDocument) }
        replacements.append((renderedURL, displayURL))
        replacements.append((temporaryDocument, Self.editDocumentURL(for: displayURL)))
        try ScreenshotEditFileTransaction.apply(replacements: replacements)

        if let index = items.firstIndex(where: { $0.fileName == displayURL.lastPathComponent }) {
            let imageSize = ScreenshotImageLoader.imageSize(at: displayURL) ?? .zero
            items[index].updatedAt = Date()
            items[index].pixelWidth = Int(imageSize.width)
            items[index].pixelHeight = Int(imageSize.height)
            items[index].hasEdits = true
            saveMetadata()
        }
        // A new render is in the file, which keeps its extended attributes: the note about the old one goes.
        OptimizedMark.clear(displayURL)
        // The rendered image is optimized once the editing is over, not on each save.
        CaptureOptimizer.editingChanged(displayURL, closed: !CaptureLibraryOpenEditors.isEditing(displayURL))
        return displayURL
    }

    /// Where the original comes from while none is kept: the base once an
    /// edit was saved, otherwise the display image. Nil once it is kept.
    nonisolated private static func originalSource(for displayURL: URL) -> URL? {
        guard !FileManager.default.fileExists(atPath: originalImageURL(for: displayURL).path) else { return nil }
        let base = baseImageURL(for: displayURL)
        return FileManager.default.fileExists(atPath: base.path) ? base : displayURL
    }

    /// The image as captured, kept now if no save has kept it yet. A file
    /// from outside History is its own original.
    func originalImage(for displayURL: URL) throws -> URL {
        guard isHistoryURL(displayURL) else { return displayURL }
        let original = Self.originalImageURL(for: displayURL)
        if let source = Self.originalSource(for: displayURL) {
            try ScreenshotEditFileTransaction.apply(replacements: [(source, original)])
        }
        return original
    }

    /// The Library's Revert to Original: the capture as captured, with no
    /// edits left to open.
    @discardableResult
    func revertToOriginal(displayURL: URL) throws -> URL {
        try removeAnnotations(displayURL: displayURL, restoringFrom: originalImage(for: displayURL))
    }

    /// Restores the base, or `source` (the original, for a revert), and
    /// removes the editable files as one recoverable save. The original stays.
    @discardableResult
    func removeAnnotations(displayURL: URL, restoringFrom source: URL? = nil) throws -> URL {
        _ = try loadEditDocument(for: displayURL)
        guard isHistoryURL(displayURL) else { return displayURL }
        let baseDestination = Self.baseImageURL(for: displayURL)
        let documentURL = Self.editDocumentURL(for: displayURL)
        let restored = source ?? baseDestination
        // Missing pixels are a failed restore, not a successful clear.
        guard FileManager.default.fileExists(atPath: restored.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try ScreenshotEditFileTransaction.apply(
            replacements: [(restored, displayURL)],
            removing: [baseDestination, documentURL]
        )
        OptimizedMark.clear(displayURL)
        if let index = items.firstIndex(where: { $0.fileName == displayURL.lastPathComponent }) {
            let imageSize = ScreenshotImageLoader.imageSize(at: displayURL) ?? .zero
            items[index].updatedAt = Date()
            items[index].pixelWidth = Int(imageSize.width)
            items[index].pixelHeight = Int(imageSize.height)
            items[index].hasEdits = false
            saveMetadata()
        }
        return displayURL
    }

    func delete(_ item: ScreenshotHistoryItem) {
        let thumbnailOwner = item.recordingSessionPath.map { URL(fileURLWithPath: $0) } ?? item.url
        let auxiliaryURLs: [URL]
        if let recordingSession = item.recordingSession {
            auxiliaryURLs = [recordingSession.directoryURL]
        } else {
            auxiliaryURLs = [item.url] + Self.companionURLs(for: item.url)
        }

        // To the Trash, as the Library does, so a capture deleted from its
        // preview card can be put back (design pass).
        for url in auxiliaryURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                print("Failed to move history file to the Trash: \(error)")
            }
        }

        // Checked via the stored path, not `recordingSession`: the package
        // has already been removed by this point, so the lookup would fail.
        let wasRecordingProject = item.recordingSessionPath != nil
        items.removeAll { $0.id == item.id }
        saveMetadata()
        Task { await CaptureLibraryThumbnails.shared.remove(for: [thumbnailOwner]) }
        if wasRecordingProject {
            // The package is gone, so the Projects browser must stop listing it.
            RecordingProjectStore.shared.reload()
        }
    }

    @discardableResult
    func delete(url: URL) -> Bool {
        guard let index = index(for: url) else { return false }
        delete(items[index])
        return true
    }

    func setCloudURL(for fileURL: URL, cloudURL: String) {
        guard let index = index(for: fileURL) else { return }
        items[index].cloudURL = cloudURL
        items[index].updatedAt = Date()
        saveMetadata()
    }

    func reveal(_ item: ScreenshotHistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([
            item.recordingSession?.directoryURL ?? item.url
        ])
    }

    /// Resolves a flattened recording URL back to its non-destructive project
    /// package. Every editor entry point uses this so overlay cards, History,
    /// and after-capture actions cannot accidentally open different editors.
    func editorURL(for mediaURL: URL) -> URL {
        guard let index = index(for: mediaURL) else { return mediaURL }
        return items[index].editorURL
    }

    func item(for mediaURL: URL) -> ScreenshotHistoryItem? {
        index(for: mediaURL).map { items[$0] }
    }

    /// Recording media filenames change when the render cache changes;
    /// their owning package remains the same History identity.
    private func index(for mediaURL: URL) -> Int? {
        let standardizedURL = mediaURL.standardizedFileURL
        if let session = RecordingDeliverable.session(for: standardizedURL),
           let index = items.firstIndex(where: { item in
               guard let path = item.recordingSessionPath else { return false }
               return URL(fileURLWithPath: path).standardizedFileURL == session.directoryURL.standardizedFileURL
           }) {
            return index
        }
        return items.firstIndex { $0.url.standardizedFileURL == standardizedURL }
    }

    func reload() {
        load()
    }

    func rename(id: UUID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].rename(to: name)
        saveMetadata()
    }

    /// Throws, and leaves the marks as they were, when they couldn't be kept on disk: a Save that didn't stick isn't
    /// shown as saved (Astra M2).
    func moveToSaved(ids: Set<UUID>, at date: Date) throws {
        guard !ids.isEmpty else { return }
        let before = items
        for index in items.indices where ids.contains(items[index].id) {
            items[index].librarySavedAt = items[index].librarySavedAt ?? date
        }
        do {
            guard try files.save(items) else {
                throw NSError(domain: "Sukusho.SavedMarks", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: files.problem ?? "Saved marks couldn't be written."])
            }
            savedMarksProblem = files.problem
        } catch {
            items = before
            savedMarksProblem = files.problem ?? error.localizedDescription
            throw error
        }
    }

    /// Adds `tag` to the items, or removes it, ignoring case. Leaves
    /// `updatedAt` alone: tagging isn't an edit of the capture.
    func setTag(_ tag: String, applied: Bool, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in items.indices where ids.contains(items[index].id) {
            items[index].setTag(tag, applied: applied)
        }
        saveMetadata()
    }

    /// Called only after Library has successfully moved the owned files to Trash.
    func removeTrashedItems(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        saveMetadata()
    }

    func setLibraryCloudURL(id: UUID, cloudURL: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].setLibraryCloudURL(cloudURL)
        saveMetadata()
    }

    func recordCloudUpload(id: UUID, cloudURL: String, redactions: [RecordingRedaction]?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].recordCloudUpload(url: cloudURL, redactions: redactions)
        saveMetadata()
    }

    private func load(launchDefaults: UserDefaults? = nil) {
        items = files.load(launchDefaults: launchDefaults)
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt > $1.createdAt }
        savedMarksProblem = files.problem
    }

    private func saveMetadata() {
        do {
            try files.save(items)
        } catch {
            print("Failed to save screenshot history: \(error)")
        }
        savedMarksProblem = files.problem
    }

    private func uniqueHistoryURL(for sourceURL: URL) -> URL {
        let pathExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let candidate = ScreenshotFileNaming.uniqueURL(
            for: ScreenshotFileNaming.fileName(extension: pathExtension),
            in: Self.historyDirectory
        )
        guard reservedHistoryURLs.contains(candidate.standardizedFileURL) else { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        for index in 2...10_000 {
            let next = Self.historyDirectory.appendingPathComponent("\(stem)_\(index).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: next.path),
               !reservedHistoryURLs.contains(next.standardizedFileURL) {
                return next
            }
        }
        return candidate
    }

    private func videoMetadata(at url: URL) async -> (width: Int, height: Int, duration: Double?) {
        let asset = AVURLAsset(url: url)
        var width = 0
        var height = 0
        var duration: Double?

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            if let size, let transform {
                let transformed = size.applying(transform)
                width = Int(abs(transformed.width))
                height = Int(abs(transformed.height))
            } else if let size {
                width = Int(size.width)
                height = Int(size.height)
            }
        }

        if let loadedDuration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(loadedDuration)
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
        }
        return (width, height, duration)
    }

    func isHistoryURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(Self.historyDirectory.standardizedFileURL.path + "/")
    }

}
