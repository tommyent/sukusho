// The shake shelf's Save and Save and Replace Originals, on files in a temporary folder. "The Trash" here is a
// folder of the test's own, so nothing reaches the real one.
import Foundation
import Testing

/// Other contents of the same length written into `url`, with its modification date put back to the
/// nanosecond, as a careful tool leaves a file: nothing but the contents tells the two apart.
func rewriteKeepingSizeAndDate(_ url: URL, with data: Data) throws {
    var before = stat()
    try #require(stat(url.path, &before) == 0)
    try #require(Int(before.st_size) == data.count)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: data)
    try handle.close()
    var times = [before.st_atimespec, before.st_mtimespec]
    try #require(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
    var after = stat()
    try #require(stat(url.path, &after) == 0)
    try #require(after.st_size == before.st_size && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
        && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
}

@Suite struct ShelfFileSaveTests {
    private struct Desk {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SukushoShelfSave-\(UUID().uuidString)")
        var trash: URL { folder.appending(path: "trash") }
        var results: URL { folder.appending(path: "results") }

        init() throws {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }

        func file(_ name: String, _ text: String, in directory: URL? = nil) throws -> URL {
            let url = (directory ?? folder).appending(path: name)
            try Data(text.utf8).write(to: url)
            return url
        }

        func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

        /// Stands in for the Trash.
        func retire(_ url: URL) throws -> URL {
            let destination = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }

        /// Convenience wrapper for tests whose result file hasn't been tampered with.
        func save(_ result: URL, of original: URL, identity: FileIdentity? = nil, outputIdentity: FileIdentity? = nil,
                  replacing: Bool, in folder: URL? = nil,
                  beforeInstall: (URL) throws -> Void = { _ in },
                  beforeRetire: (URL) throws -> Void = { _ in },
                  retire: ((URL) throws -> URL)? = nil) -> ShelfFileSave.Outcome {
            ShelfFileSave.save(result, of: original, identity: identity ?? FileIdentity(original),
                               outputIdentity: outputIdentity ?? FileIdentity(result),
                               replacing: replacing, in: folder, beforeInstall: beforeInstall,
                               beforeRetire: beforeRetire, retire: retire ?? self.retire)
        }

        var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != "trash" && $0 != "results" }.sorted()
        }
    }

    @Test func saveWritesBesideTheOriginalAndLeavesIt() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let original = try desk.file("shot.png", "original pixels, long")
        let result = try desk.file("shot.png", "smaller", in: desk.results)

        let outcome = desk.save(result, of: original, replacing: false)
        #expect(outcome == .saved(desk.folder.appending(path: "shot optimized.png")))
        #expect(desk.text(original) == "original pixels, long")
        #expect(desk.names == ["shot optimized.png", "shot.png"])   // and no staging folder left

        // A second save doesn't write over the first.
        let again = desk.save(result, of: original, replacing: false)
        #expect(again == .saved(desk.folder.appending(path: "shot optimized 2.png")))

        // Converting to another format uses the new extension beside the original, without overwriting.
        let photo = try desk.file("photo.jpeg", "jpeg bytes")
        let webP = try desk.file("photo.webp", "smaller webp", in: desk.results)
        #expect(desk.save(webP, of: photo, replacing: false)
            == .saved(desk.folder.appending(path: "photo.webp")))
        #expect(desk.save(webP, of: photo, replacing: false)
            == .saved(desk.folder.appending(path: "photo 2.webp")))
        #expect(desk.text(photo) == "jpeg bytes")
    }

    @Test func saveIntoChosenFolderWritesThereAndAvoidsCollisions() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let chosen = desk.folder.appending(path: "chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let original = try desk.file("shot.png", "original pixels, long")
        let result = try desk.file("shot.png", "smaller", in: desk.results)

        let first = desk.save(result, of: original, replacing: false, in: chosen)
        #expect(first == .saved(chosen.appending(path: "shot optimized.png")))
        #expect(desk.text(chosen.appending(path: "shot optimized.png")) == "smaller")
        #expect(desk.text(original) == "original pixels, long")

        let second = desk.save(result, of: original, replacing: false, in: chosen)
        #expect(second == .saved(chosen.appending(path: "shot optimized 2.png")))

        let photo = try desk.file("photo.jpeg", "jpeg bytes")
        let webP = try desk.file("photo.webp", "webp bytes", in: desk.results)
        let converted = desk.save(webP, of: photo, replacing: false, in: chosen)
        #expect(converted == .saved(chosen.appending(path: "photo.webp")))
        #expect(desk.text(photo) == "jpeg bytes")
    }

    @Test func replaceInstallsTheNewFileAndRetiresTheOriginal() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let original = try desk.file("shot.png", "original pixels, long")
        let result = try desk.file("shot.png", "smaller", in: desk.results)

        #expect(desk.save(result, of: original, replacing: true) == .saved(original))
        #expect(desk.text(original) == "smaller")
        let trashedNames = try FileManager.default.contentsOfDirectory(atPath: desk.trash.path)
        #expect(trashedNames.count == 1)
        #expect(desk.text(desk.trash.appending(path: trashedNames[0])) == "original pixels, long")
        #expect(desk.names == ["shot.png"])

        // Another format takes another name; the original is retired once that file is in place.
        let photo = try desk.file("photo.png", "png bytes")
        let webP = try desk.file("photo.webp", "webp", in: desk.results)
        #expect(desk.save(webP, of: photo, replacing: true)
            == .saved(desk.folder.appending(path: "photo.webp")))
        #expect(!FileManager.default.fileExists(atPath: photo.path))
        #expect(desk.text(desk.trash.appending(path: "photo.png")) == "png bytes")
    }

    /// Astra OR2: optimized on the shelf, then changed in another app, then Replace.
    @Test func aSourceChangedSinceItWasOptimizedIsNeverReplaced() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let original = try desk.file("shot.png", "the version that was optimized")
        let identity = FileIdentity(original)
        let result = try desk.file("shot.png", "smaller", in: desk.results)

        try Data("a newer version, edited in another app".utf8).write(to: original)
        for replacing in [true, false] {
            #expect(desk.save(result, of: original, identity: identity, replacing: replacing) == .changed)
        }
        #expect(desk.text(original) == "a newer version, edited in another app")
        #expect(desk.names == ["shot.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)

        // The same length and a new date is still a change.
        let same = try desk.file("same.png", "12345")
        let before = FileIdentity(same)
        try Data("54321".utf8).write(to: same)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: same.path)
        #expect(desk.save(result, of: same, identity: before, replacing: true) == .changed)
        #expect(desk.text(same) == "54321")

        // Astra's second review: the same length with the old date put back. Only the contents tell.
        let quiet = try desk.file("quiet.png", "12345")
        let quietBefore = FileIdentity(quiet)
        try rewriteKeepingSizeAndDate(quiet, with: Data("54321".utf8))
        for replacing in [true, false] {
            #expect(desk.save(result, of: quiet, identity: quietBefore, replacing: replacing) == .changed)
        }
        #expect(desk.text(quiet) == "54321")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)
    }

    /// Same-format Replace installs via replaceItemAt with a retained backup before touching Trash: if Trash
    /// fails, the new file is already in place, the backup stays intact, and its path is preserved across
    /// a batch summary even if another file fails later.
    @Test func aSameFormatReplaceKeepsBackupAndPreservesRecoveryDetailAcrossABatch() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let original = try desk.file("shot.png", "original pixels, long")
        let result = try desk.file("shot.png", "smaller", in: desk.results)

        let outcome = desk.save(result, of: original, replacing: true, retire: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        guard case .saved(let installed, .trashFailed(let keptBackup)) = outcome else {
            Issue.record("expected saved with kept backup: \(outcome)")
            return
        }
        #expect(installed == original)
        #expect(desk.text(original) == "smaller")
        #expect(desk.text(keptBackup) == "original pixels, long")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)

        // A later failure in the same batch must preserve the structured recovery URL and path.
        let summary = ShelfFileSave.summary(of: [outcome, .failed("Disk full.")], replacing: true)
        #expect(summary.isFailure)
        #expect(summary.recoveryURLs == [keptBackup])
        #expect(summary.detail.contains("Disk full."))
        #expect(summary.detail.contains(keptBackup.path))
    }

    /// Sol 6.2 re-check #1: if FileManager.replaceItemAt throws an error with NSFileOriginalItemLocationKey,
    /// carry that relocated original URL structurally into both Outcome.failed and Summary.recoveryURLs.
    @Test func aReplacementFailureCarriesNSFileOriginalItemLocationKeyForRecovery() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let original = try desk.file("shot.png", "original pixels, long")
        let result = try desk.file("shot.png", "smaller", in: desk.results)
        let relocated = desk.folder.appending(path: "relocated-original.png")

        let outcome = ShelfFileSave.save(
            result, of: original, identity: FileIdentity(original), outputIdentity: FileIdentity(result),
            replacing: true,
            replaceItem: { source, _, _ in
                try FileManager.default.moveItem(at: source, to: relocated)
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Replacement failed mid-swap.",
                        NSFileOriginalItemLocationKey: relocated,
                    ]
                )
            },
            retire: desk.retire
        )
        guard case .failed(let reason, let recoveryURL?) = outcome else {
            Issue.record("expected failed with recoveryURL: \(outcome)")
            return
        }
        #expect(reason.contains("Replacement failed"))
        #expect(recoveryURL == relocated)
        #expect(desk.text(relocated) == "original pixels, long")

        let keptOther = desk.folder.appending(path: "other.png")
        let summary = ShelfFileSave.summary(of: [.saved(desk.folder.appending(path: "other.webp"), keptOriginal: .trashFailed(keptOther)), outcome], replacing: true)
        #expect(summary.isFailure)
        #expect(summary.recoveryURLs == [keptOther, relocated])
        #expect(summary.detail.contains(keptOther.path))
        #expect(summary.detail.contains(relocated.path))
    }

    /// editor-opus L4: a Replace in another format whose new file is in place, but whose original the Trash
    /// won't take, has saved. It says so, with the path of the kept original.
    @Test func aReplaceThatSavedButKeptTheOriginalIsNotAFailure() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let photo = try desk.file("photo.png", "png bytes")
        let webP = try desk.file("photo.webp", "webp", in: desk.results)
        let outcome = desk.save(webP, of: photo, replacing: true, retire: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        #expect(outcome == .saved(desk.folder.appending(path: "photo.webp"), keptOriginal: .trashFailed(photo)))
        #expect(desk.text(desk.folder.appending(path: "photo.webp")) == "webp")
        #expect(desk.text(photo) == "png bytes")
        #expect(desk.names == ["photo.png", "photo.webp"])
    }

    /// Sol 6.2 #2: if another app edits the PNG between installing photo.webp and retiring photo.png,
    /// Replace must NOT Trash the newer PNG and keeps the newly saved WebP as a separate file.
    @Test func aSourceEditedBetweenInstallAndRetireIsNeverTrashed() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let photo = try desk.file("photo.png", "old png bytes")
        let webP = try desk.file("photo.webp", "smaller webp", in: desk.results)
        let sourceID = FileIdentity(photo)

        let outcome = desk.save(webP, of: photo, identity: sourceID, replacing: true, beforeRetire: { installed in
            #expect(FileManager.default.fileExists(atPath: installed.path))
            try Data("newer edited png bytes".utf8).write(to: photo)
        })
        #expect(outcome == .saved(desk.folder.appending(path: "photo.webp"), keptOriginal: .sourceChanged(photo)))
        #expect(desk.text(photo) == "newer edited png bytes")
        #expect(desk.text(desk.folder.appending(path: "photo.webp")) == "smaller webp")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)

        let summary = ShelfFileSave.summary(of: [outcome], replacing: true)
        #expect(!summary.isFailure)
        #expect(summary.detail.contains("changed"))
    }

    /// Astra OR2: the original must not be gone when the new file can't be put in place.
    @Test func aFailedReplaceLeavesTheOriginalWhereItWas() throws {
        let desk = try Desk()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: desk.folder.path)
            desk.remove()
        }
        let original = try desk.file("shot.png", "original pixels, long")
        let missing = desk.results.appending(path: "shot.png")   // a result that is no longer there

        guard case .failed = ShelfFileSave.save(missing, of: original, identity: FileIdentity(original),
                                                outputIdentity: FileIdentity(original), replacing: true, retire: desk.retire) else {
            Issue.record("a missing result was saved")
            return
        }
        #expect(desk.text(original) == "original pixels, long")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)
        #expect(desk.names == ["shot.png"])

        // A read-only folder fails before anything moves, leaving the original untouched.
        let result = try desk.file("shot.png", "smaller", in: desk.results)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: desk.folder.path)
        guard case .failed = desk.save(result, of: original, replacing: true) else {
            Issue.record("replaced in a read-only folder")
            return
        }
        #expect(desk.text(original) == "original pixels, long")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)
        #expect(desk.names == ["shot.png"])
    }

    @Test func aResultChangedAfterEncodingIsNeverSavedOrReplaced() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let original = try desk.file("photo.png", "original png bytes")
        let result = try desk.file("photo.webp", "verified webp bytes", in: desk.results)
        let sourceID = FileIdentity(original)
        let expectedOutput = FileIdentity(result)

        // Truncate the temporary result file after the encoder recorded its fingerprint.
        try Data("trunc".utf8).write(to: result)

        for replacing in [true, false] {
            let outcome = ShelfFileSave.save(result, of: original, identity: sourceID,
                                             outputIdentity: expectedOutput, replacing: replacing, retire: desk.retire)
            guard case .failed = outcome else {
                Issue.record("saved a result whose bytes no longer matched the encoder's fingerprint: \(outcome)")
                return
            }
        }
        #expect(desk.text(original) == "original png bytes")
        #expect(desk.names == ["photo.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)
    }

    @Test func aLateCollisionPicksTheNextFreeNameAndLeavesTheSourceUntouchedOnFailure() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let photo = try desk.file("photo.png", "original png")
        let webP = try desk.file("photo.webp", "new webp", in: desk.results)
        var collided = false

        // Another app creates photo.webp after the shelf picks it, right before exclusive rename.
        let outcome = desk.save(webP, of: photo, replacing: false, beforeInstall: { candidate in
            if !collided, candidate.lastPathComponent == "photo.webp" {
                collided = true
                try Data("raced file".utf8).write(to: candidate)
            }
        })
        #expect(outcome == .saved(desk.folder.appending(path: "photo 2.webp")))
        #expect(desk.text(desk.folder.appending(path: "photo.webp")) == "raced file")
        #expect(desk.text(desk.folder.appending(path: "photo 2.webp")) == "new webp")
        #expect(desk.text(photo) == "original png")

        // A non-collision install failure leaves the source untouched and Trash empty.
        let failed = desk.save(webP, of: photo, replacing: true, beforeInstall: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        guard case .failed = failed else {
            Issue.record("expected install failure: \(failed)")
            return
        }
        #expect(desk.text(photo) == "original png")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.trash.path).isEmpty)
    }
}
