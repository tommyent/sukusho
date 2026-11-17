// The file transaction behind the editor's saves and Convert › Save…: a file is replaced whole or not at all.
import Foundation
import Testing

@Suite struct ScreenshotEditFileTransactionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SukushoTransaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// Astra OR1: Save… onto a file that exists. The old file is there until the new one has taken its place.
    @Test func aReplacedFileIsNeverDeletedFirst() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let results = folder.appending(path: "results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let destination = folder.appending(path: "shot.jpg")
        try Data("the file already there".utf8).write(to: destination)
        let converted = results.appending(path: "shot.jpg")
        try Data("converted".utf8).write(to: converted)

        try ScreenshotEditFileTransaction.apply(replacements: [(converted, destination)])
        #expect(text(destination) == "converted")
        #expect(text(converted) == "converted")   // the result is copied, not moved
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["results", "shot.jpg"])

        // A new file that can't be read: the save fails and the old file is untouched, with nothing left beside it.
        try Data("the file already there".utf8).write(to: destination)
        #expect(throws: (any Error).self) {
            try ScreenshotEditFileTransaction.apply(replacements: [(results.appending(path: "gone.jpg"), destination)])
        }
        #expect(text(destination) == "the file already there")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["results", "shot.jpg"])

        // A save that fails part-way puts back what it had already replaced.
        let locked = folder.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) {
            try ScreenshotEditFileTransaction.apply(replacements: [(converted, destination), (converted, locked.appending(path: "shot.jpg"))])
        }
        #expect(text(destination) == "the file already there")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["locked", "results", "shot.jpg"])
    }
}
