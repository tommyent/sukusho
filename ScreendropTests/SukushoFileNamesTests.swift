import Foundation
import Testing

/// New files get Sukusho names; Screendrop's, and those of builds before the
/// rename, are still read. Files on disk are never renamed.
struct SukushoFileNamesTests {
    @Test func newRecordingsAreNamedSukushoAndBothNamesGiveTheirDate() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = SukushoFileNames.recordingName(date: date, id: "9A5457")
        #expect(name.hasPrefix("Sukusho_"))
        #expect(name.hasSuffix("_9A5457"))
        #expect(!name.localizedCaseInsensitiveContains("screendrop"))
        #expect(SukushoFileNames.recordingDate(inName: name) == date)

        let legacy = "Screendrop_" + name.dropFirst("Sukusho_".count)
        #expect(SukushoFileNames.recordingDate(inName: legacy) == date)
        #expect(SukushoFileNames.recordingDate(inName: "Holiday_" + name.dropFirst("Sukusho_".count)) == nil)
        #expect(SukushoFileNames.recordingDate(inName: "Sukusho") == nil)

        #expect(RecordingAgentPromptWriter.recordingID(ofFolder: RecordingAgentPromptWriter.folderName(name)) == "9A5457")
        #expect(RecordingAgentPromptWriter.recordingID(ofFolder: RecordingAgentPromptWriter.folderName(legacy)) == "9A5457")
    }

    @Test func bothRecordingExtensionsAreRecordings() {
        #expect(SukushoFileNames.recordingExtension == "sukushorec")
        #expect(SukushoFileNames.isRecordingExtension("sukushorec"))
        #expect(SukushoFileNames.isRecordingExtension("screendroprec"))
        #expect(!SukushoFileNames.isRecordingExtension("mov"))
        #expect(!SukushoFileNames.isRecordingExtension(""))
    }

    @Test func aNewSidecarIsSukushoAndAnExistingScreendropOneStaysInUse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sukusho-FileNamesTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fresh = folder.appendingPathComponent("fresh.png")
        #expect(SukushoFileNames.editDocumentURL(for: fresh).lastPathComponent == "fresh.png.sukusho")

        let old = folder.appendingPathComponent("old.png")
        let oldSidecar = folder.appendingPathComponent("old.png.screendrop")
        try Data("{}".utf8).write(to: oldSidecar)
        #expect(SukushoFileNames.editDocumentURL(for: old) == oldSidecar)

        // With both beside an image, the Sukusho one is the capture's.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old.png.sukusho"))
        #expect(SukushoFileNames.editDocumentURL(for: old).lastPathComponent == "old.png.sukusho")
        #expect(FileManager.default.fileExists(atPath: oldSidecar.path))
    }
}
