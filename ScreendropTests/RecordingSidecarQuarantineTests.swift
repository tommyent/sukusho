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

        let firstCopy = try RecordingSidecarQuarantine.preserve(at: sidecar)
        #expect(firstCopy.lastPathComponent.hasPrefix("edit.json.unreadable-"))
        #expect(try Data(contentsOf: firstCopy) == firstBytes)

        // Repeating on identical bytes keeps the single verified copy without clobbering it.
        let mtime = try firstCopy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try RecordingSidecarQuarantine.preserve(at: sidecar)
        #expect(again == firstCopy)
        #expect(try firstCopy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == mtime)

        // Different unreadable contents create a second distinct copy, keeping the first intact.
        let secondBytes = Data("{broken".utf8)
        try secondBytes.write(to: sidecar)
        let secondCopy = try RecordingSidecarQuarantine.preserve(at: sidecar)
        #expect(secondCopy != firstCopy)
        #expect(try Data(contentsOf: firstCopy) == firstBytes)
        #expect(try Data(contentsOf: secondCopy) == secondBytes)
    }

    @Test func rejectsSymlinkedPackageSourceOrDestinationAndMismatchedExistingCopy() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = dir.appendingPathComponent("outside.json")
        try Data("do not copy".utf8).write(to: outside)

        // Source symlink is rejected.
        let sourceLink = dir.appendingPathComponent("edit.json")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: outside)
        #expect(throws: RecordingSidecarQuarantine.QuarantineError.unsafeSourceFile("edit.json")) {
            try RecordingSidecarQuarantine.preserve(at: sourceLink)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["edit.json", "outside.json"])

        // Symlinked package directory is rejected.
        let realPackage = dir.appendingPathComponent("real.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: realPackage, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: realPackage.appendingPathComponent("edit.json"))
        let linkedPackage = dir.appendingPathComponent("linked.sukushorec")
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: realPackage)
        #expect(throws: RecordingSidecarQuarantine.QuarantineError.unsafePackageDirectory("linked.sukushorec")) {
            try RecordingSidecarQuarantine.preserve(at: linkedPackage.appendingPathComponent("edit.json"))
        }

        // Destination pre-existing symlink is never followed or overwritten.
        try FileManager.default.removeItem(at: sourceLink)
        let corrupt = Data("corrupt bytes".utf8)
        try corrupt.write(to: sourceLink)
        let target = dir.appendingPathComponent("victim.txt")
        try Data("untouched".utf8).write(to: target)
        let probeDir = dir.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        let probeFile = probeDir.appendingPathComponent("edit.json")
        try corrupt.write(to: probeFile)
        let expectedName = try RecordingSidecarQuarantine.preserve(at: probeFile).lastPathComponent
        let destLink = dir.appendingPathComponent(expectedName)
        try FileManager.default.createSymbolicLink(at: destLink, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try RecordingSidecarQuarantine.preserve(at: sourceLink)
        }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))

        // Existing quarantine file with truncated/different bytes is rejected (aborting overwrite).
        try FileManager.default.removeItem(at: destLink)
        try Data("partial".utf8).write(to: destLink)
        #expect(throws: (any Error).self) {
            try RecordingSidecarQuarantine.preserve(at: sourceLink)
        }
        #expect(try Data(contentsOf: destLink) == Data("partial".utf8))

        // Directory and missing file throw cleanly.
        #expect(throws: RecordingSidecarQuarantine.QuarantineError.unsafeSourceFile("probe")) {
            try RecordingSidecarQuarantine.preserve(at: probeDir)
        }
        #expect(throws: RecordingSidecarQuarantine.QuarantineError.missingSourceFile("missing.json")) {
            try RecordingSidecarQuarantine.preserve(at: dir.appendingPathComponent("missing.json"))
        }
    }

    @Test func rejectsOversizedSidecarAndQuarantinesLibraryStarTypedDecodeFailures() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Oversized (> 64 MiB) invalid file aborts preserveIfInvalid.
        let huge = dir.appendingPathComponent("edit.json")
        try Data("{".utf8).write(to: huge)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(RecordingSidecarQuarantine.maxBytes + 1))
        try handle.close()
        #expect(throws: RecordingSidecarQuarantine.QuarantineError.oversizedSourceFile("edit.json")) {
            try RecordingSidecarQuarantine.preserveIfInvalid(at: huge) { _ in throw CocoaError(.fileReadCorruptFile) }
        }

        // Library star writer quarantines JSON that JSONSerialization accepts but RecordingProjectMetadata rejects.
        let project = dir.appendingPathComponent("project.json")
        let badTyped = Data(#"{"version":1,"tags":"not-an-array","futureKey":42}"#.utf8)
        try badTyped.write(to: project)
        let now = Date()
        #expect(try RecordingLibraryMark.change(at: project, from: nil, to: now))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("project.json.unreadable-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == badTyped)

        // If the quarantine target is corrupted/mismatched, Library star writer aborts without overwriting project.json.
        let backupURL = dir.appendingPathComponent(backups[0])
        try badTyped.write(to: project)
        try Data("truncated".utf8).write(to: backupURL)
        #expect(throws: (any Error).self) {
            try RecordingLibraryMark.change(at: project, from: nil, to: now)
        }
        #expect(try Data(contentsOf: project) == badTyped)
    }
}
