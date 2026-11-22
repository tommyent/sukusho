import CoreGraphics
import Foundation

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
@main
struct SidecarQuarantineChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func main() {
        do {
            try run()
            print("PASS: Recording sidecar quarantine")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage outside temporary home: \(support.path)")
        let session = try RecordingSessionStore.createSession()

        // 1. Unreadable edit.json of a supported format version is preserved beside edit.json after a save.
        let corruptEdit = Data(#"{"formatVersion":7,"redactions":[{"start":1,"end":0,"rect":[[0,0],[0,0]]}]}"#.utf8)
        try corruptEdit.write(to: session.editDocumentURL)
        try check(session.loadEditDocument() == nil, "Unreadable edit.json unexpectedly decoded")

        let replacement = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: true, zoomCues: [])
        try session.writeEditDocument(replacement)
        try check(session.loadEditDocument()?.withoutRevision == replacement, "New edit.json was not saved")
        let backups = try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
            .filter { $0.hasPrefix("edit.json.unreadable-") }
        try check(backups.count == 1, "Expected 1 edit.json quarantine backup, got \(backups)")
        try check(try Data(contentsOf: session.directoryURL.appendingPathComponent(backups[0])) == corruptEdit,
                  "Quarantined edit.json bytes did not match original")

        // 2. Direct overwrite of an unreadable edit.json (without prior load) also quarantines first.
        let secondCorrupt = Data("{truncated".utf8)
        try secondCorrupt.write(to: session.editDocumentURL)
        try session.writeEditDocument(replacement)
        let backupsAfterSecond = try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
            .filter { $0.hasPrefix("edit.json.unreadable-") }
        try check(backupsAfterSecond.count == 2, "Expected 2 edit.json backups, got \(backupsAfterSecond)")
        let savedContents = try Set(backupsAfterSecond.map { try Data(contentsOf: session.directoryURL.appendingPathComponent($0)) })
        try check(savedContents == [corruptEdit, secondCorrupt], "Earlier edit.json quarantine copy was lost")

        // 3. Unreadable edit.draft.json, capture.json, and project.json are also quarantined on fallback/overwrite.
        let corruptDraft = Data("not-a-draft".utf8)
        try corruptDraft.write(to: session.draftDocumentURL)
        try session.writeDraftDocument(replacement)
        let draftBackups = try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
            .filter { $0.hasPrefix("edit.draft.json.unreadable-") }
        try check(draftBackups.count == 1
                  && (try Data(contentsOf: session.directoryURL.appendingPathComponent(draftBackups[0])) == corruptDraft),
                  "Unreadable edit.draft.json was not quarantined")

        let corruptCapture = Data(#"{"captureMode":"future"}"#.utf8)
        try corruptCapture.write(to: session.captureManifestURL)
        try check(session.loadCaptureManifest() == nil, "Corrupt capture.json unexpectedly decoded")
        let captureBackups = try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
            .filter { $0.hasPrefix("capture.json.unreadable-") }
        try check(captureBackups.count == 1
                  && (try Data(contentsOf: session.directoryURL.appendingPathComponent(captureBackups[0])) == corruptCapture),
                  "Unreadable capture.json was not quarantined")

        let corruptProject = Data("not-project".utf8)
        try corruptProject.write(to: session.projectMetadataURL)
        try session.writeProjectMetadata(RecordingProjectMetadata(displayName: "Fixed"))
        let projectBackups = try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
            .filter { $0.hasPrefix("project.json.unreadable-") }
        try check(projectBackups.count == 1
                  && (try Data(contentsOf: session.directoryURL.appendingPathComponent(projectBackups[0])) == corruptProject),
                  "Unreadable project.json was not quarantined")

        // 4. Valid overwrites produce no extra quarantine files.
        let beforeValidSave = try Set(FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path))
        try session.writeEditDocument(replacement)
        try session.writeDraftDocument(replacement)
        try session.writeProjectMetadata(RecordingProjectMetadata(displayName: "Fixed 2"))
        let afterValidSave = try Set(FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path))
        try check(beforeValidSave == afterValidSave, "Valid overwrites created spurious quarantine files")

        // 5. Saving over an oversized (> 64 MiB) invalid edit.json aborts without overwriting it.
        let oversizedSession = try RecordingSessionStore.createSession()
        try Data("{".utf8).write(to: oversizedSession.editDocumentURL)
        let handle = try FileHandle(forWritingTo: oversizedSession.editDocumentURL)
        try handle.truncate(atOffset: UInt64(RecordingSidecarQuarantine.maxBytes + 1))
        try handle.close()
        var savedOversized = false
        do { try oversizedSession.writeEditDocument(replacement); savedOversized = true } catch {}
        try check(!savedOversized, "Save over oversized invalid edit.json should abort")

        // 6. Pre-existing truncated/mismatched quarantine copy aborts overwrite and preserves original.
        let mismatchSession = try RecordingSessionStore.createSession()
        let badBytes = Data("{invalid".utf8)
        try badBytes.write(to: mismatchSession.editDocumentURL)
        let backupPath = try RecordingSidecarQuarantine.preserve(at: mismatchSession.editDocumentURL)
        try Data("partial".utf8).write(to: backupPath)
        var savedMismatch = false
        do { try mismatchSession.writeEditDocument(replacement); savedMismatch = true } catch {}
        try check(!savedMismatch && (try Data(contentsOf: mismatchSession.editDocumentURL) == badBytes),
                  "Mismatched quarantine copy allowed original edit.json to be overwritten")

        // 7. Decoded but semantically invalid edit (bad redaction rect) is quarantined before overwrite.
        let invalidMaskSession = try RecordingSessionStore.createSession()
        var invalidDoc = replacement
        invalidDoc.redactions = [RecordingRedaction(start: 0, end: 2, rect: CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5))]
        try invalidMaskSession.writeEditDocument(invalidDoc)
        try invalidMaskSession.writeEditDocument(replacement)
        let maskBackups = try FileManager.default.contentsOfDirectory(atPath: invalidMaskSession.directoryURL.path)
            .filter { $0.hasPrefix("edit.json.unreadable-") }
        try check(maskBackups.count == 1, "Semantically invalid edit.json was not quarantined before overwrite")

        // 8. Recognized newer-format sidecars must NOT create quarantine copies on read or Library scan.
        let futureSession = try RecordingSessionStore.createSession()
        try futureSession.writeEditDocument(replacement)
        let newerDraft = Data(#"{"formatVersion":99,"redactions":[{"mode":"mosaic_v2","start":0,"end":2,"rect":[[0,0],[1,1]]}]}"#.utf8)
        try newerDraft.write(to: futureSession.draftDocumentURL)
        let beforeFutureReads = try Set(FileManager.default.contentsOfDirectory(atPath: futureSession.directoryURL.path))
        try check(futureSession.loadDraftDocument() == nil, "Unknown-enum newer draft unexpectedly decoded")
        _ = futureSession.hasUnsavedDraft
        var threwUnsupported = false
        do {
            _ = try futureSession.editDocumentForRendering()
        } catch RecordingPackageMedia.ValidationError.unsupportedFormatVersion(99) {
            threwUnsupported = true
        }
        try check(threwUnsupported, "editDocumentForRendering did not reject recognized newer-format draft")
        _ = CaptureLibraryScanner.redactionTag(for: futureSession)
        let afterFutureReads = try Set(FileManager.default.contentsOfDirectory(atPath: futureSession.directoryURL.path))
        try check(afterFutureReads == beforeFutureReads && (try Data(contentsOf: futureSession.draftDocumentURL) == newerDraft),
                  "Read/scan of recognized newer-format project wrote files: \(afterFutureReads.subtracting(beforeFutureReads))")

        print("CHECK: unreadable, oversized, mismatched, and semantically invalid sidecars are protected; recognized newer formats stay read-only")
    }
}
