// The note an optimized capture carries. It must stop counting when the file's contents change under it:
// the editor's saves keep a file's extended attributes, so a fresh render would otherwise pass for optimized.
import Foundation
import Testing

@Suite struct OptimizedMarkTests {
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
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: 2, count: 900))
        try handle.close()
        #expect(!OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.originalBytes(of: file) == nil)
        #expect(OptimizedMark.saving(of: file) == nil)

        // Nothing smaller came out: remembered as done, with no saving to show.
        OptimizedMark.set(900, on: file)
        #expect(OptimizedMark.isCurrent(file))
        #expect(OptimizedMark.saving(of: file) == nil)
    }
}
