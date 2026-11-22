import Foundation
import Testing
import UniformTypeIdentifiers

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

    @Test func infoPlistDeclaresRecordingPackagesAndEditorDocumentType() throws {
        let infoPlistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Screendrop/Info.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: try Data(contentsOf: infoPlistURL), format: nil) as? [String: Any]
        )
        let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let sukushoUTI = try #require(exported.first { ($0["UTTypeIdentifier"] as? String) == "com.tommyent.sukusho.recording" })
        #expect((sukushoUTI["UTTypeConformsTo"] as? [String])?.contains("com.apple.package") == true)
        let sukushoTags = sukushoUTI["UTTypeTagSpecification"] as? [String: Any]
        #expect((sukushoTags?["public.filename-extension"] as? [String])?.contains("sukushorec") == true)

        let imported = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let legacyUTI = try #require(imported.first { ($0["UTTypeIdentifier"] as? String) == "com.fayazahmed.screendrop.recording" })
        #expect((legacyUTI["UTTypeConformsTo"] as? [String])?.contains("com.apple.package") == true)
        let legacyTags = legacyUTI["UTTypeTagSpecification"] as? [String: Any]
        #expect((legacyTags?["public.filename-extension"] as? [String])?.contains("screendroprec") == true)

        let docTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let recordingDoc = try #require(docTypes.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("com.tommyent.sukusho.recording") == true
        })
        #expect(recordingDoc["CFBundleTypeRole"] as? String == "Editor")
        #expect(recordingDoc["LSHandlerRank"] as? String == "Owner")
        #expect(recordingDoc["LSTypeIsPackage"] as? Bool == true)
        #expect((recordingDoc["LSItemContentTypes"] as? [String])?.contains("com.fayazahmed.screendrop.recording") == true)

        // When the built app is registered with Launch Services, UTType resolves .sukushorec as a package.
        if let resolved = UTType(filenameExtension: "sukushorec"), !resolved.isDynamic {
            #expect(resolved.conforms(to: .package))
        }
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

    @Test func uniqueURLSkipsReservedInFlightExports() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sukusho-ReservedNames-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = ScreenshotFileNaming.uniqueURL(for: "screenshot_2026-11-13_120000.png", in: folder)
        #expect(first.lastPathComponent == "screenshot_2026-11-13_120000.png")
        let reserved: Set<URL> = [first.standardizedFileURL]
        let second = ScreenshotFileNaming.uniqueURL(for: "screenshot_2026-11-13_120000.png", in: folder, reserved: reserved)
        #expect(second.lastPathComponent == "screenshot_2026-11-13_120000_2.png")
        let third = ScreenshotFileNaming.uniqueURL(
            for: "screenshot_2026-11-13_120000.png",
            in: folder,
            reserved: reserved.union([second.standardizedFileURL])
        )
        #expect(third.lastPathComponent == "screenshot_2026-11-13_120000_3.png")
    }
}
