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
                  replacing: Bool, in folder: URL? = nil, retire: ((URL) throws -> URL)? = nil) -> ShelfFileSave.Outcome {
            ShelfFileSave.save(result, of: original, identity: identity ?? FileIdentity(original),
                               outputIdentity: outputIdentity ?? FileIdentity(result),
                               replacing: replacing, in: folder, retire: retire ?? self.retire)
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
        #expect(desk.text(desk.trash.appending(path: "shot.png")) == "original pixels, long")
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

    /// Astra's second review: when the new file can't be put in place and the original can't be put back
    /// either, the failure says so and says where the original is.
    @Test func aReplaceThatCannotBeUndoneSaysWhereTheOriginalIs() throws {
        let desk = try Desk()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: desk.folder.path)
            desk.remove()
        }
        let original = try desk.file("shot.png", "original pixels, long")
        let result = try desk.file("shot.png", "smaller", in: desk.results)
        let retired = desk.trash.appending(path: "shot.png")

        // The folder stops taking files right after the original has left it.
        let outcome = desk.save(result, of: original, replacing: true) { url in
            let destination = try desk.retire(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: desk.folder.path)
            return destination
        }
        guard case .failed(let reason) = outcome else {
            Issue.record("a replace that could not finish: \(outcome)")
            return
        }
        #expect(reason.contains("put back"))
        #expect(reason.contains(retired.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(desk.text(retired) == "original pixels, long")
    }

    /// editor-opus L4: a Replace in another format whose new file is in place, but whose original the Trash
    /// won't take, has saved. It says so, with a note that the original is still there.
    @Test func aReplaceThatSavedButKeptTheOriginalIsNotAFailure() throws {
        let desk = try Desk()
        defer { desk.remove() }
        let photo = try desk.file("photo.png", "png bytes")
        let webP = try desk.file("photo.webp", "webp", in: desk.results)
        let outcome = desk.save(webP, of: photo, replacing: true) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        #expect(outcome == .saved(desk.folder.appending(path: "photo.webp"), originalKept: true))
        #expect(desk.text(desk.folder.appending(path: "photo.webp")) == "webp")
        #expect(desk.text(photo) == "png bytes")
        #expect(desk.names == ["photo.png", "photo.webp"])
    }

    /// Astra OR2: the original must not be gone when the new file can't be put in place.
    @Test func aFailedReplaceLeavesTheOriginalWhereItWas() throws {
        let desk = try Desk()
        defer { desk.remove() }
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

        // The Trash refusing the original stops the replace before anything moves.
        let result = try desk.file("shot.png", "smaller", in: desk.results)
        let refused = desk.save(result, of: original, replacing: true) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        guard case .failed = refused else {
            Issue.record("replaced without retiring the original")
            return
        }
        #expect(desk.text(original) == "original pixels, long")
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
}
