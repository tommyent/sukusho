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

struct ScreenshotHistoryItem: Identifiable, Codable, Equatable, SavedMarkRow {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var kind: PreviewMediaKind
    var duration: Double?
    var cloudURL: String?
    var cloudRedactions: [RecordingRedaction]?
    /// Whether this screenshot has an editable annotation sidecar document.
    var hasEdits: Bool
    /// Absolute path to the non-destructive recording package, when this video
    /// belongs to the new Studio workflow. Older video items remain bare files.
    var recordingSessionPath: String?
    /// A Library title, kept separate from the file name and editable sidecars.
    var displayName: String?
    /// Library tags. Screendrop's own, not Finder tags.
    var tags: [String] = []
    /// The app and window it was taken from. Nil for older rows, and when
    /// no window could be named. Stays on this Mac.
    var source: CaptureSource?
    /// When it was saved (★) to Library › Saved, by hand or by naming, tagging or sharing it. Kept in
    /// `CaptureSavedMarks`' file, not in history.json, which older builds rewrite without it; read from a row only to
    /// move it there.
    var librarySavedAt: Date?

    /// Every key but `librarySavedAt`, so history.json no longer carries it.
    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, fileName, pixelWidth, pixelHeight, kind, duration, cloudURL, cloudRedactions,
             hasEdits, recordingSessionPath, displayName, tags, source
    }

    private enum LegacyKeys: String, CodingKey { case librarySavedAt }

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

    var isVideo: Bool { kind == .video }

    // Backward-compatible decoding: existing history.json entries have no
    // `kind` or `duration` fields, so they default to .image / nil.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        kind = try container.decodeIfPresent(PreviewMediaKind.self, forKey: .kind) ?? .image
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        cloudURL = try container.decodeIfPresent(String.self, forKey: .cloudURL)
        cloudRedactions = try container.decodeIfPresent([RecordingRedaction].self, forKey: .cloudRedactions)
        hasEdits = try container.decodeIfPresent(Bool.self, forKey: .hasEdits) ?? false
        // Rows imported from Screendrop point at its folder; use this app's copy.
        recordingSessionPath = try container.decodeIfPresent(String.self, forKey: .recordingSessionPath)
            .map(ScreendropStorage.remapLegacyPath)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try container.decodeIfPresent(CaptureSource.self, forKey: .source)
        librarySavedAt = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Date.self, forKey: .librarySavedAt)
    }

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: PreviewMediaKind = .image,
        duration: Double? = nil,
        cloudURL: String? = nil,
        hasEdits: Bool = false,
        recordingSessionPath: String? = nil,
        displayName: String? = nil,
        source: CaptureSource? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.duration = duration
        self.cloudURL = cloudURL
        self.hasEdits = hasEdits
        self.recordingSessionPath = recordingSessionPath
        self.displayName = displayName
        self.source = source
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
        load()
        retroSaveOnce()
    }

    /// Set once captures named, tagged or shared before Saved have been marked, so it happens once.
    static let retroSaveDoneKey = "libraryRetroSave.v1"

    /// The owner's one-time retro-save, at the first launch of a build with Saved. It waits for a launch where History
    /// and the marks file are fully readable, and counts as done only once the marks are on disk.
    private func retroSaveOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.retroSaveDoneKey), isFullyLoaded,
              files.marks.state != .unreadable else { return }
        let rows = items.map { item -> (id: UUID, isNamedTaggedOrShared: Bool, updatedAt: Date) in
            // A recording keeps its name and tags in its own project.
            let project = item.recordingSession?.loadProjectMetadata()
            let named = item.displayName != nil || project?.displayName?.isEmpty == false
            let tagged = !item.tags.isEmpty || project?.tags?.isEmpty == false
            return (item.id, named || tagged || item.cloudURL != nil, item.updatedAt)
        }
        let current = Dictionary(items.compactMap { item in item.librarySavedAt.map { (item.id, $0) } }, uniquingKeysWith: max)
        let marks = CaptureSavedMarks.retroSaved(rows, into: current)
        guard marks != current else {
            UserDefaults.standard.set(true, forKey: Self.retroSaveDoneKey)
            return
        }
        let before = items
        for index in items.indices { items[index].librarySavedAt = marks[items[index].id] }
        do {
            guard try files.save(items) else { throw CocoaError(.fileWriteUnknown) }
            UserDefaults.standard.set(true, forKey: Self.retroSaveDoneKey)
        } catch {
            items = before
            print("Retro-save of named, tagged and shared captures failed; it'll be tried at the next launch: \(error)")
        }
        savedMarksProblem = files.problem
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].displayName = trimmed.isEmpty ? nil : trimmed
        // Naming a capture says it's worth keeping (Fable's critique, 2026-11-16).
        if !trimmed.isEmpty, items[index].librarySavedAt == nil { items[index].librarySavedAt = Date() }
        items[index].updatedAt = Date()
        saveMetadata()
    }

    /// Saves the items to Library › Saved, or takes them out. Leaves `updatedAt` alone, as tagging does.
    /// Marks a recording's History rows saved, so the marks file covers it too: its project.json mark alone can be
    /// dropped by an older Studio re-saving the project. For naming and tagging, which write only the project.
    func markRecordingSaved(_ session: RecordingSession) {
        // The project keeps its own mark; a failure here shows on the Saved page.
        try? setLibrarySaved(true, ids: CaptureSavedMarks.rows(ofRecordingAt: session.directoryURL.path,
                                                               in: items.map { ($0.id, $0.recordingSessionPath) }))
    }

    /// Throws, and leaves the marks as they were, when they couldn't be kept on disk: a Save that didn't stick isn't
    /// shown as saved (Astra M2).
    func setLibrarySaved(_ saved: Bool, ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let before = items
        for index in items.indices where ids.contains(items[index].id) {
            items[index].librarySavedAt = saved ? (items[index].librarySavedAt ?? Date()) : nil
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
            items[index].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if applied { items[index].tags.append(tag) }
            // So does tagging it.
            if applied, items[index].librarySavedAt == nil { items[index].librarySavedAt = Date() }
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
        if items[index].cloudURL != cloudURL { items[index].cloudRedactions = nil }
        items[index].cloudURL = cloudURL
        // And sharing it.
        if cloudURL != nil { markShared(index) }
        items[index].updatedAt = Date()
        saveMetadata()
    }

    /// A shared capture is saved: on its History row, and for a recording in its own project.json too, as an explicit
    /// Save writes it (Astra L5). That's `librarySavedAt`, apart from Studio's `savedAt`.
    private func markShared(_ index: Int) {
        if items[index].librarySavedAt == nil { items[index].librarySavedAt = Date() }
        try? items[index].recordingSession?.updateProjectMetadata { $0.librarySavedAt = $0.librarySavedAt ?? Date() }
    }

    func recordCloudUpload(id: UUID, cloudURL: String, redactions: [RecordingRedaction]?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].cloudURL = cloudURL
        items[index].cloudRedactions = redactions
        markShared(index)
        items[index].updatedAt = Date()
        saveMetadata()
    }

    private func load() {
        items = files.load()
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
