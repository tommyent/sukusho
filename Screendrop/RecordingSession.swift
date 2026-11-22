//
//  RecordingSession.swift
//  Screendrop
//
//  A recording is a folder ("session") rather than a bare .mov so the studio
//  editor can keep the screen video, the separately captured camera video,
//  and the timestamped pointer-capture sidecar together. Sessions live in
//  Application Support (not the temp dir) so a crash mid-recording never
//  hands the footage to the OS temp purger.
//

import CoreGraphics
import Darwin
import Foundation

nonisolated struct RecordingSession: Sendable, Equatable {
    static let screenFileName = "screen.mov"
    static let cameraFileName = "camera.mov"
    static let pointerCaptureFileName = "input.json"
    static let captureManifestFileName = "capture.json"
    static let editDocumentFileName = "edit.json"
    /// The working copy the editor writes while you type. `edit.json` is
    /// only rewritten by a save (at a pause, on leaving or closing the
    /// window, on quit or ⌘S), so a crash between saves costs nothing.
    static let draftDocumentFileName = "edit.draft.json"
    static let projectMetadataFileName = "project.json"
    /// The document that produced the current flattened deliverable, so a
    /// cached render can be proven fresh instead of assumed fresh.
    static let renderStampFileName = "render.json"
    /// Base name for an imported soundtrack. The picked file is copied in
    /// beside the footage (keeping its own extension) so the project keeps
    /// playing after the original is moved or deleted.
    static let replacementAudioBaseName = "audio-replacement"

    let directoryURL: URL

    var sessionSnapshotsURL: URL { directoryURL.appendingPathComponent("sessions", isDirectory: true) }
    var mediaDirectoryURL: URL { directoryURL.appendingPathComponent("media", isDirectory: true) }

    var screenURL: URL { directoryURL.appendingPathComponent(Self.screenFileName) }
    var cameraURL: URL { directoryURL.appendingPathComponent(Self.cameraFileName) }
    /// The default flattened deliverable. The source screen/camera movies stay
    /// untouched so Studio can always re-render the project non-destructively.
    var finalURL: URL {
        finalURL(for: .default)
    }

    func finalURL(for container: VideoExportContainer) -> URL {
        let fileName = directoryURL
            .deletingPathExtension()
            .lastPathComponent
            .appending(".\(container.fileExtension)")
        return directoryURL.appendingPathComponent(fileName)
    }
    var pointerCaptureURL: URL { directoryURL.appendingPathComponent(Self.pointerCaptureFileName) }
    var captureManifestURL: URL { directoryURL.appendingPathComponent(Self.captureManifestFileName) }
    var editDocumentURL: URL { directoryURL.appendingPathComponent(Self.editDocumentFileName) }
    var draftDocumentURL: URL { directoryURL.appendingPathComponent(Self.draftDocumentFileName) }
    var projectMetadataURL: URL { directoryURL.appendingPathComponent(Self.projectMetadataFileName) }
    var renderStampURL: URL { directoryURL.appendingPathComponent(Self.renderStampFileName) }

    /// True once the project has been committed to `edit.json`. Every
    /// package written by older builds has an `edit.json` from the previous
    /// silent autosave, so those open as already-saved - no migration.
    var hasSavedProject: Bool {
        FileManager.default.fileExists(atPath: editDocumentURL.path)
    }

    /// The name shown wherever the project is listed.
    var displayName: String {
        customName ?? packageName
    }

    /// The package's own name, which a rename in the Library doesn't change.
    var packageName: String { directoryURL.deletingPathExtension().lastPathComponent }

    /// The name given in the Library or Studio's title bar, if any.
    var customName: String? {
        let stored = loadProjectMetadata()?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    var hasCamera: Bool {
        FileManager.default.fileExists(atPath: cameraURL.path)
    }

    /// The flattened cache on disk, whichever container it was rendered into.
    /// Nil when the project has never been rendered. Probing every container
    /// keeps an existing render valid after the export format is changed -
    /// switching the picker converts on save rather than forcing a re-render.
    var existingFinalURL: URL? {
        for container in VideoExportContainer.allCases {
            let candidate = finalURL(for: container)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Uses an existing flattened cache when one is available; otherwise
    /// history previews the screen master so the project can appear without
    /// turning Stop into an implicit export.
    var deliverableURL: URL {
        existingFinalURL ?? screenURL
    }

    /// Drops every cached deliverable, whichever container it was rendered
    /// into. Targeting a single container would leave a render in the other
    /// one behind, and `existingFinalURL` would then hand out stale footage.
    func removeFinalVideos() {
        for container in VideoExportContainer.allCases {
            try? FileManager.default.removeItem(at: finalURL(for: container))
        }
        try? FileManager.default.removeItem(at: renderStampURL)
    }

    /// Adopts a freshly rendered file as this session's deliverable, taking the
    /// container from the render itself. Deliverables in other containers are
    /// cleared so a stale render can never win the `existingFinalURL` lookup.
    @discardableResult
    func installFinalVideo(
        movingFrom temporaryURL: URL,
        renderedFrom document: RecordingEditDocument? = nil
    ) throws -> URL {
        let container = VideoExportContainer(fileExtension: temporaryURL.pathExtension) ?? .default
        let destinationURL = finalURL(for: container)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }

        for stale in VideoExportContainer.allCases where stale != container {
            try? FileManager.default.removeItem(at: finalURL(for: stale))
        }
        writeRenderStamp(document)
        return destinationURL
    }

    /// True when two documents would render identical media and differ only in
    /// the container they get wrapped in or GIF conversion dimensions/rate.
    static func differsOnlyByExportContainer(
        _ document: RecordingEditDocument,
        _ other: RecordingEditDocument?
    ) -> Bool {
        guard let other else { return false }
        var normalized = document.withoutRevision
        normalized.exportSettings?.container = other.exportSettings?.container
        // GIF intermediates omit music, so exportsGIF remains part of the media identity.
        normalized.exportSettings?.gifFrameRate = other.exportSettings?.gifFrameRate
        normalized.exportSettings?.gifWidth = other.exportSettings?.gifWidth
        return normalized == other.withoutRevision
    }

    static func isSessionDirectory(_ url: URL) -> Bool {
        SukushoFileNames.isRecordingExtension(url.pathExtension)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent(screenFileName).path)
    }

    /// Loads `capture.json`, returning `nil` only when the file does not exist (`ENOENT`).
    /// Corrupt JSON, newer/unknown enum cases, or read errors throw so callers never
    /// mistake an existing manifest for an interrupted recording.
    func loadCaptureManifestStrict() throws -> CaptureManifest? {
        let data: Data
        do {
            data = try Data(contentsOf: captureManifestURL)
        } catch {
            let nsError = error as NSError
            let isMissing = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            var info = stat()
            if isMissing && lstat(captureManifestURL.path, &info) != 0 && errno == ENOENT {
                return nil
            }
            throw error
        }
        return try CaptureManifest.decoder.decode(CaptureManifest.self, from: data)
    }

    private struct SidecarVersionHeader: Decodable {
        var version: Int?
    }

    private static func isNewerFormatHeader<T>(_ type: T.Type, in data: Data) -> Bool {
        if type == RecordingEditDocument.self {
            return RecordingPackageMedia.readFormatVersion(from: data)
                .map { $0 > RecordingPackageMedia.currentFormatVersion } ?? false
        }
        if type == CaptureManifest.self || type == RecordingProjectMetadata.self {
            if let version = (try? JSONDecoder().decode(SidecarVersionHeader.self, from: data))?.version {
                let current = type == RecordingProjectMetadata.self ? RecordingProjectMetadata.currentVersion : 1
                return version > current
            }
        }
        return false
    }

    private func decodeSidecar<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try CaptureManifest.decoder.decode(type, from: data)
        } catch {
            if !Self.isNewerFormatHeader(type, in: data) {
                _ = try? RecordingSidecarQuarantine.preserve(at: url)
            }
            return nil
        }
    }

    private func quarantineIfUnreadable<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        validate: ((T) throws -> Void)? = nil
    ) throws {
        try RecordingSidecarQuarantine.preserveIfInvalid(at: url) { data in
            let decoded = try CaptureManifest.decoder.decode(type, from: data)
            try validate?(decoded)
        }
    }

    func loadCaptureManifest() -> CaptureManifest? {
        decodeSidecar(CaptureManifest.self, at: captureManifestURL)
    }

    func loadPointerCapture() -> PointerCaptureFile? {
        guard let data = try? Data(contentsOf: pointerCaptureURL) else { return nil }
        return try? CaptureManifest.decoder.decode(PointerCaptureFile.self, from: data)
    }

    func writeCaptureManifest(_ manifest: CaptureManifest) throws {
        try quarantineIfUnreadable(CaptureManifest.self, at: captureManifestURL)
        let data = try CaptureManifest.encoder.encode(manifest)
        try data.write(to: captureManifestURL, options: .atomic)
    }

    /// Publishes `capture.json` atomically with exclusive creation inside the verified
    /// package directory. Returns `true` when published, `false` if a manifest (or link)
    /// already exists at `capture.json` (leaving it untouched), and throws on I/O errors.
    func writeCaptureManifestIfAbsent(_ manifest: CaptureManifest) throws -> Bool {
        let data = try CaptureManifest.encoder.encode(manifest)
        let dirFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(dirFD) }
        let tempName = ".\(Self.captureManifestFileName).\(UUID().uuidString).tmp"
        let tempFD = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard tempFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { unlinkat(dirFD, tempName, 0) }
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let step = Darwin.write(tempFD, base.advanced(by: written), raw.count - written)
                if step < 0 && errno == EINTR { continue }
                if step <= 0 { return false }
                written += step
            }
            return true
        }
        let writeErrno = errno
        let synced = wroteAll && fsync(tempFD) == 0
        let syncErrno = errno
        close(tempFD)
        guard wroteAll else { throw POSIXError(.init(rawValue: writeErrno) ?? .EIO) }
        guard synced else { throw POSIXError(.init(rawValue: syncErrno) ?? .EIO) }
        if linkat(dirFD, tempName, dirFD, Self.captureManifestFileName, 0) == 0 {
            return true
        }
        if errno == EEXIST { return false }
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    func writePointerCapture(_ capture: PointerCaptureFile) throws {
        let data = try CaptureManifest.encoder.encode(capture)
        try data.write(to: pointerCaptureURL, options: .atomic)
    }

    func loadEditDocument() -> RecordingEditDocument? {
        decodeSidecar(RecordingEditDocument.self, at: editDocumentURL)
    }

    func writeEditDocument(_ document: RecordingEditDocument) throws {
        try quarantineIfUnreadable(RecordingEditDocument.self, at: editDocumentURL) {
            for redaction in $0.redactions { try redaction.validate() }
        }
        try writeNextRevision(of: document, to: editDocumentURL)
    }

    // MARK: - Working draft

    func loadDraftDocument() -> RecordingEditDocument? {
        decodeSidecar(RecordingEditDocument.self, at: draftDocumentURL)
    }

    func writeDraftDocument(_ document: RecordingEditDocument) throws {
        try quarantineIfUnreadable(RecordingEditDocument.self, at: draftDocumentURL) {
            for redaction in $0.redactions { try redaction.validate() }
        }
        try writeNextRevision(of: document, to: draftDocumentURL)
    }

    private func writeNextRevision(of document: RecordingEditDocument, to url: URL) throws {
        try validateEditVersionsForRendering()
        let newest = max(document.revision, loadEditDocument()?.revision ?? 0, loadDraftDocument()?.revision ?? 0)
        guard newest < Int.max else { throw CocoaError(.fileWriteUnknown) }
        var next = document
        next.revision = newest + 1
        try CaptureManifest.encoder.encode(next).write(to: url, options: .atomic)
    }

    func removeDraftDocument() {
        try? FileManager.default.removeItem(at: draftDocumentURL)
    }

    /// Revert to Original: the project's saved edits, its draft and any
    /// render of them, so it opens as a new recording does. The name and
    /// tags stay.
    func removeEdits() throws {
        if FileManager.default.fileExists(atPath: editDocumentURL.path) {
            try FileManager.default.removeItem(at: editDocumentURL)
        }
        removeDraftDocument()
        removeFinalVideos()
    }

    /// What the editor should actually open: the autosaved draft when one
    /// survived, otherwise the last save. Every consumer outside the
    /// editor (flattening, uploads) uses this too, so a deliverable always
    /// reflects the edits the user can see.
    func effectiveEditDocument() -> RecordingEditDocument? {
        try? editDocumentForRendering()
    }

    /// Verifies neither `edit.draft.json` (unless `ignoringDraft`) nor `edit.json` is an
    /// unsafe symlink or was written by a newer format version than this build supports.
    @discardableResult
    func validateEditVersionsForRendering(ignoringDraft: Bool = false) throws -> (draftURL: URL?, editURL: URL?) {
        let draftURL = ignoringDraft
            ? nil
            : try RecordingPackageMedia.resolveOptionalPackageFile(named: Self.draftDocumentFileName, in: directoryURL)
        let editURL = try RecordingPackageMedia.resolveOptionalPackageFile(named: Self.editDocumentFileName, in: directoryURL)
        try RecordingPackageMedia.rejectNewerFormatEdits(
            draftURL: draftURL,
            editURL: editURL,
            packageName: directoryURL.lastPathComponent
        )
        return (draftURL, editURL)
    }

    /// Missing legacy edits are fine; existing unreadable, symlinked, dangling, or
    /// newer-format edits (across both draft and saved files) must never expose the master.
    func editDocumentForRendering(ignoringDraft: Bool = false) throws -> RecordingEditDocument? {
        let (draftURL, editURL) = try validateEditVersionsForRendering(ignoringDraft: ignoringDraft)
        func read(_ url: URL) throws -> RecordingEditDocument {
            do {
                return try CaptureManifest.decoder.decode(RecordingEditDocument.self, from: Data(contentsOf: url))
            } catch {
                _ = try? RecordingSidecarQuarantine.preserve(at: url)
                throw error
            }
        }
        let saved = try editURL.map(read)
        guard let draft = try draftURL.map(read) else { return saved }
        guard let saved else { return draft }
        return try RecordingPackageMedia.activeEditIsDraft(
            draftRevision: draft.revision, savedRevision: saved.revision, sameEdit: draft == saved
        ) ? draft : saved
    }

    /// True when unsaved edits are sitting in the draft. A draft identical to
    /// the saved document is just a leftover and doesn't count.
    var hasUnsavedDraft: Bool {
        guard let draft = loadDraftDocument() else { return false }
        guard let saved = loadEditDocument() else { return true }
        return draft.revision >= saved.revision && draft.withoutRevision != saved.withoutRevision
    }

    // MARK: - Project metadata

    func loadProjectMetadata() -> RecordingProjectMetadata? {
        decodeSidecar(RecordingProjectMetadata.self, at: projectMetadataURL)
    }

    func writeProjectMetadata(_ metadata: RecordingProjectMetadata) throws {
        try quarantineIfUnreadable(RecordingProjectMetadata.self, at: projectMetadataURL)
        let data = try CaptureManifest.encoder.encode(metadata)
        try data.write(to: projectMetadataURL, options: .atomic)
    }

    /// Read-modify-write so touching one field never drops the others.
    func updateProjectMetadata(_ mutate: (inout RecordingProjectMetadata) -> Void) throws {
        var metadata = RecordingProjectMetadata()
        if let resolved = try RecordingPackageMedia.resolveOptionalPackageFile(named: Self.projectMetadataFileName, in: directoryURL) {
            let data = try Data(contentsOf: resolved)
            do {
                metadata = try CaptureManifest.decoder.decode(RecordingProjectMetadata.self, from: data)
            } catch {
                if !Self.isNewerFormatHeader(RecordingProjectMetadata.self, in: data) {
                    _ = try? RecordingSidecarQuarantine.preserve(at: resolved)
                }
                throw error
            }
        }
        metadata.version = RecordingProjectMetadata.currentVersion
        mutate(&metadata)
        try writeProjectMetadata(metadata)
    }

    // MARK: - Render stamp

    private struct RenderStamp: Codable {
        static let currentLayoutVersion = 3
        var layoutVersion = currentLayoutVersion
        var document: RecordingEditDocument?
    }

    func loadRenderStamp() -> RecordingEditDocument? {
        guard let data = try? Data(contentsOf: renderStampURL) else { return nil }
        if let stamp = try? CaptureManifest.decoder.decode(RenderStamp.self, from: data) {
            return stamp.document
        }
        // Older builds stored the edit document directly.
        return try? CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data)
    }

    func writeRenderStamp(_ document: RecordingEditDocument?) {
        guard let data = try? CaptureManifest.encoder.encode(RenderStamp(document: document)) else { return }
        try? data.write(to: renderStampURL, options: .atomic)
    }

    /// The movie deliverable only when it provably matches `document`.
    /// Export and Share can then skip the render instead of trusting that
    /// nothing has changed since it was made. The deliverable is the shared
    /// movie (`forVideoRendering`); a local export opts in to an exact match,
    /// so a GIF or HEVC export never gets it.
    func freshFinalURL(matching document: RecordingEditDocument?, forLocalExport: Bool = false) -> URL? {
        let document = forLocalExport ? document?.withoutRevision : document?.forVideoRendering
        // Older renders could include cut caption wording or omit replacement audio.
        guard let existing = existingFinalURL,
              let safeFinal = RecordingPackageMedia.resolvePackageFile(named: existing.lastPathComponent, in: directoryURL),
              let safeStamp = try? RecordingPackageMedia.resolveOptionalPackageFile(named: Self.renderStampFileName, in: directoryURL),
              let data = try? Data(contentsOf: safeStamp),
              let renderStamp = try? CaptureManifest.decoder.decode(RenderStamp.self, from: data),
              renderStamp.layoutVersion == RenderStamp.currentLayoutVersion else { return nil }
        let stamp = renderStamp.document?.withoutRevision
        if stamp == document { return safeFinal }
        // Swapping only the container leaves every encoded sample intact, so
        // the render survives and export converts it on the way out.
        if let document, Self.differsOnlyByExportContainer(document, stamp) { return safeFinal }
        return nil
    }
}

nonisolated struct CaptureManifest: Codable, Sendable, Equatable {
    var version = 1
    var createdAt = Date()
    /// Duration of the finished screen movie, in seconds.
    var duration: TimeInterval = 0
    var pixelWidth = 0
    var pixelHeight = 0
    /// Points→pixels scale of the captured source (Retina factor).
    var pixelScale: Double = 1
    var sourceDisplayID: UInt32?
    var includesSystemAudio = false
    var includesMicrophone = false
    /// Where the camera movie's t=0 falls on the screen movie's timeline.
    /// Positive means the camera started after the screen recording.
    var cameraLeadIn: TimeInterval?
    var cameraWidth: Int?
    var cameraHeight: Int?
    /// True when the capture excluded the OS cursor, so playback and export
    /// must draw the synthetic pointer from the capture sidecar. Optional so
    /// manifests written before this field decode as nil (cursor in pixels).
    var pointerSynthesized: Bool?
    /// New sessions keep press feedback out of the lossless screen master and
    /// reconstruct it from the pointer capture. Nil means a legacy session
    /// whose pixels may already contain the configured mouse indicators.
    var pressEffectsBaked: Bool?
    var pressEffectsEnabled: Bool?
    /// Whether Sukusho's own windows were visible to the capture when it
    /// started. Nil for sessions recorded before this was kept.
    var includesAppWindows: Bool?
    var captureMode: RecordingCaptureMode?
    var capturedWindowTitle: String?
    /// Stop writes the Agent Prompt for a Bug report take.
    var isBugReport: Bool?
    /// A Bug report take with Include app logs on: whose log to read after Stop, and when.
    var appLogSpan: RecordingAppLogs.Span?
    /// The macOS the take was recorded on ("Version 27.3 (Build …)"), for bug reports.
    var systemVersion: String?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

nonisolated enum RecordingSessionStore {
    static var recordingsDirectory: URL {
        return ScreendropStorage.applicationSupportDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func createSession() throws -> RecordingSession {
        let directory = recordingsDirectory
            .appendingPathComponent(SukushoFileNames.recordingName())
            .appendingPathExtension(SukushoFileNames.recordingExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingSession(directoryURL: directory)
    }

    static func allSessions() -> [RecordingSession] {
        (try? listSessions()) ?? []
    }

    /// Throws when the Recordings folder exists but can't be listed; a
    /// missing folder just means no recordings yet.
    static func listSessions() throws -> [RecordingSession] {
        try ScreendropStorage.folderContents(at: recordingsDirectory)
            .filter { RecordingSession.isSessionDirectory($0) }
            .map { RecordingSession(directoryURL: $0) }
    }

    static func deleteSession(_ session: RecordingSession) throws {
        try FileManager.default.trashItem(at: session.directoryURL, resultingItemURL: nil)
        Task { await CaptureLibraryThumbnails.shared.remove(for: [session.directoryURL]) }
    }
}
