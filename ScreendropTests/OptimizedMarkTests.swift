// The note an optimized capture carries. It must stop counting when the file's contents change under it:
// the editor's saves keep a file's extended attributes, so a fresh render would otherwise pass for optimized.
import Foundation
import Testing

@Suite struct OptimizedMarkTests {
    private func write(_ byte: UInt8, count: Int, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: byte, count: count))
        try handle.close()
    }

    @Test func theNoteCountsOnlyWhileTheFileIsAsTheOptimizerLeftIt() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SukushoMark-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 600).write(to: file)

        #expect(!OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.saving(of: file) == nil)

        OptimizedMark.set(1_000, on: file)
        #expect(OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.originalBytes(of: file) == 1_000)
        #expect(OptimizedMark.saving(of: file)?.percent == "↓40%")

        // New contents written into the same file, as an edit's save does: the note is still attached
        // but no longer describes the file.
        try write(2, count: 900, to: file)
        #expect(!OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.originalBytes(of: file) == nil)
        #expect(OptimizedMark.saving(of: file) == nil)

        // Nothing smaller came out: remembered as done, with no saving to show.
        OptimizedMark.set(900, on: file)
        #expect(OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.saving(of: file) == nil)

        // A save or a revert takes the note off outright.
        OptimizedMark.clear(file)
        #expect(!OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.originalBytes(of: file) == nil)
    }

    /// Astra OR5: other contents of exactly the same length.
    @Test func aRewriteOfTheSameLengthIsNotCurrent() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "SukushoMark-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 600).write(to: file)
        OptimizedMark.set(1_000, on: file)
        let date = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        try write(2, count: 600, to: file)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(3)], ofItemAtPath: file.path)
        #expect(!OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.saving(of: file) == nil)   // the date moved, so no saving is shown either

        // Even with the old date put back, the contents give it away to the check that decides.
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        #expect(!OptimizedMark.isCurrent(file))
    }
}
