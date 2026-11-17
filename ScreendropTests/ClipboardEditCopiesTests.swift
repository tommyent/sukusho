import Foundation
import Testing

/// Astra R5-2: a clipboard image's editable copy goes when no editor has it open, and a reused path gets fresh pixels.
struct ClipboardEditCopiesTests {
    @Test func copiesLiveOnlyWhileAnEditorHasThemOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditCopiesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        try Data("first version".utf8).write(to: first)
        try Data("second version".utf8).write(to: second)
        let copies = ClipboardEditCopies(folder: root.appendingPathComponent("Clipboard Edits"))
        var open: Set<String> = []
        let inUse = { (folder: URL) in open.contains(folder.lastPathComponent) }

        let a = try #require(copies.copy(of: first, named: "Clip.png", entryID: "A", inUse: inUse))
        let b = try #require(copies.copy(of: first, named: "Other.png", entryID: "B", inUse: inUse))
        // The clip changed while no editor had it open: the reused path gets the new pixels.
        #expect(copies.copy(of: second, named: "Clip.png", entryID: "A", inUse: inUse) == a)
        #expect(try Data(contentsOf: a) == Data("second version".utf8))

        // An open editor keeps its copy as it is, and Delete leaves it; the unopened one goes.
        open = ["A"]
        #expect(copies.copy(of: first, named: "Clip.png", entryID: "A", inUse: inUse) == a)
        #expect(try Data(contentsOf: a) == Data("second version".utf8))
        copies.clear(inUse: inUse)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path))

        // The editor closes.
        open = []
        copies.clear(inUse: inUse)
        #expect(!FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: first.path))
    }
}
