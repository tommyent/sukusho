import Foundation
import Testing

struct RecordingSidecarQuarantineTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Sukusho-Quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func preservesUnreadableBytesWithoutClobberingEarlierCopies() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecar = dir.appendingPathComponent("edit.json")
        let firstBytes = Data(#"{"formatVersion":99,"future":true}"#.utf8)
        try firstBytes.write(to: sidecar)

        let firstCopy = try #require(RecordingSidecarQuarantine.preserve(at: sidecar))
        #expect(firstCopy.lastPathComponent.hasPrefix("edit.json.unreadable-"))
        #expect(try Data(contentsOf: firstCopy) == firstBytes)

        // Repeating on the same bytes does not clobber the existing copy.
        let mtime = try firstCopy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try #require(RecordingSidecarQuarantine.preserve(at: sidecar))
        #expect(again == firstCopy)
        #expect(try firstCopy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == mtime)

        // Different unreadable contents create a second distinct copy, keeping the first intact.
        let secondBytes = Data("{broken".utf8)
        try secondBytes.write(to: sidecar)
        let secondCopy = try #require(RecordingSidecarQuarantine.preserve(at: sidecar))
        #expect(secondCopy != firstCopy)
        #expect(try Data(contentsOf: firstCopy) == firstBytes)
        #expect(try Data(contentsOf: secondCopy) == secondBytes)
    }

    @Test func neverFollowsSourceOrDestinationSymlinksAndIgnoresDirectories() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = dir.appendingPathComponent("outside.json")
        let secret = Data("do not copy".utf8)
        try secret.write(to: outside)

        // Source symlink is refused.
        let sourceLink = dir.appendingPathComponent("edit.json")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: outside)
        #expect(RecordingSidecarQuarantine.preserve(at: sourceLink) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["edit.json", "outside.json"])

        // Destination pre-existing symlink is never followed or overwritten.
        try FileManager.default.removeItem(at: sourceLink)
        let corrupt = Data("corrupt bytes".utf8)
        try corrupt.write(to: sourceLink)
        let target = dir.appendingPathComponent("victim.txt")
        try Data("untouched".utf8).write(to: target)
        // Compute expected destination by quarantining in a sibling folder first.
        let probeDir = dir.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        let probeFile = probeDir.appendingPathComponent("edit.json")
        try corrupt.write(to: probeFile)
        let expectedName = try #require(RecordingSidecarQuarantine.preserve(at: probeFile)).lastPathComponent
        let destLink = dir.appendingPathComponent(expectedName)
        try FileManager.default.createSymbolicLink(at: destLink, withDestinationURL: target)

        #expect(RecordingSidecarQuarantine.preserve(at: sourceLink) == nil)
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))

        // Directory and missing file are ignored.
        #expect(RecordingSidecarQuarantine.preserve(at: probeDir) == nil)
        #expect(RecordingSidecarQuarantine.preserve(at: dir.appendingPathComponent("missing.json")) == nil)
    }
}
