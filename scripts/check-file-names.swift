import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// New files get Sukusho names and types; Screendrop's, and those of builds
// before the rename, are still found, opened and matched, and never renamed.
// Run with check-editor-idle-save.py against the actual app sources and an isolated home:
//   python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData scripts/check-file-names.swift
@main
struct FileNameChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func require<T>(_ value: T?, _ message: String = "Missing value") throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func writePNG(to url: URL) throws {
        let context = try require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try require(context.makeImage()), nil)
        try check(CGImageDestinationFinalize(destination), "Couldn't write \(url.lastPathComponent)")
    }

    @MainActor static func main() async {
        do {
            let support = ScreendropStorage.applicationSupportDirectory
            try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage is outside the temporary home: \(support.path)")
            try await recordings()
            try sidecars()
            try presets()
            print("PASS: file names")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor static func recordings() async throws {
        let created = try RecordingSessionStore.createSession()
        let name = created.directoryURL.lastPathComponent
        try check(name.hasPrefix("Sukusho_") && created.directoryURL.pathExtension == "sukushorec"
                  && !name.localizedCaseInsensitiveContains("screendrop"), "A new recording is named \(name)")
        try Data("stub".utf8).write(to: created.screenURL)

        // A package Screendrop, or a build before the rename, left behind.
        let legacyURL = RecordingSessionStore.recordingsDirectory
            .appendingPathComponent("Screendrop_2026-10-01-09-30-00_AB12CD.screendroprec", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let legacy = RecordingSession(directoryURL: legacyURL)
        try Data("stub".utf8).write(to: legacy.screenURL)

        for session in [created, legacy] {
            try check(RecordingSession.isSessionDirectory(session.directoryURL), "\(session.directoryURL.lastPathComponent) isn't a recording")
            try check(SukushoFileNames.recordingDate(inName: session.packageName) != nil,
                      "\(session.packageName) gives no recording date")
        }
        let listed = Set(try RecordingSessionStore.listSessions().map(\.directoryURL.lastPathComponent))
        try check(listed == [name, legacyURL.lastPathComponent], "Recordings listed: \(listed.sorted())")

        // Each is one Library card, matched with its History row by its package path.
        let history = ScreenshotHistoryStore.shared
        for session in [created, legacy] { await history.importRecordingSession(session) }
        let rows = history.items.map(CaptureLibraryHistorySnapshot.init)
        try check(rows.count == 2, "History rows: \(rows.map(\.fileName))")
        let scan = CaptureLibraryScanner.scan(history: rows, historyDirectory: ScreenshotHistoryStore.historyDirectory,
                                              excludingSessionPath: nil)
        try check(scan.recordingsListed && scan.items.count == 2, "Library cards: \(scan.items.map(\.id))")
        for session in [created, legacy] {
            let card = try require(scan.items.first { $0.session?.directoryURL.lastPathComponent == session.directoryURL.lastPathComponent },
                                   "No Library card for \(session.directoryURL.lastPathComponent)")
            try check(card.historyIDs.count == 1 && card.isVideo && card.ownedURL.lastPathComponent == session.directoryURL.lastPathComponent,
                      "\(session.directoryURL.lastPathComponent) didn't match its History row: rows \(card.historyIDs.count), owns \(card.ownedURL.path)")
        }
        try check(exists(legacyURL), "The Screendrop package was renamed")
        print("CHECK: recordings, new \(name), old \(legacyURL.lastPathComponent) listed, dated and matched")
    }

    @MainActor static func sidecars() throws {
        let history = ScreenshotHistoryStore.shared
        let scratch = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("names-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        func capture(_ name: String) throws -> URL {
            let source = scratch.appendingPathComponent(name)
            try writePNG(to: source)
            let url = history.importScreenshot(from: source)
            try check(history.isHistoryURL(url), "\(name) didn't reach History")
            return url
        }
        func rendered() throws -> URL {
            let url = scratch.appendingPathComponent("render-\(UUID()).png")
            try writePNG(to: url)
            return url
        }
        let document = AnnotationDocument(shapes: [AnnoShape(x: 10, y: 20, kind: .magnifier(.init()))],
                                          background: AnnotationBackgroundSettings())

        // A first edit writes <image>.sukusho.
        let fresh = try capture("fresh.png")
        let freshSidecar = fresh.appendingPathExtension("sukusho")
        try history.commitAnnotations(displayURL: fresh, baseURL: fresh, renderedURL: rendered(), document: document)
        try check(exists(freshSidecar) && !exists(fresh.appendingPathExtension("screendrop")),
                  "A new edit's sidecar isn't \(freshSidecar.lastPathComponent)")
        try check(history.hasEditDocument(for: fresh) && history.loadEditDocument(for: fresh)?.shapes.count == 1,
                  "The new sidecar didn't open")

        // A capture edited before the rename keeps, opens and saves into <image>.screendrop.
        let old = try capture("old.png")
        let oldSidecar = old.appendingPathExtension("screendrop")
        try JSONEncoder().encode(document).write(to: oldSidecar)
        try check(history.hasEditDocument(for: old) && history.loadEditDocument(for: old)?.shapes.count == 1,
                  "A Screendrop sidecar didn't open")
        var twice = document
        twice.shapes.append(AnnoShape(x: 30, y: 40, kind: .magnifier(.init())))
        try history.commitAnnotations(displayURL: old, baseURL: old,
                                      renderedURL: rendered(), document: twice)
        try check(exists(oldSidecar) && !exists(old.appendingPathExtension("sukusho")),
                  "Saving an older capture made a second sidecar")
        try check(history.loadEditDocument(for: old)?.shapes.count == 2, "The save didn't land in the Screendrop sidecar")
        try check(ScreenshotHistoryStore.companionURLs(for: old).contains(oldSidecar)
                  && ScreenshotHistoryStore.companionURLs(for: fresh).contains(freshSidecar),
                  "A capture's files leave out its sidecar")

        // Clearing the edits removes whichever sidecar the capture has.
        try history.removeAnnotations(displayURL: old)
        try check(!exists(oldSidecar) && !history.hasEditDocument(for: old), "Clearing left the Screendrop sidecar")
        print("CHECK: sidecars, new .sukusho written, old .screendrop opened, saved into and cleared")
    }

    @MainActor static func presets() throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("styles-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ data: Data, _ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        func format(_ data: Data) throws -> String {
            try require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? String, "No format in the file")
        }
        /// The same file as Screendrop, or a build before the rename, wrote it.
        func legacy(_ data: Data, from new: String, to old: String) throws -> Data {
            let text = try require(String(data: data, encoding: .utf8))
            try check(text.contains("\"\(new)\""), "The export doesn't say \(new)")
            return Data(text.replacingOccurrences(of: "\"\(new)\"", with: "\"\(old)\"").utf8)
        }

        try check(AnnotationBackgroundPresetTransferFile.filenameExtension == "sukushopreset", "Exports aren't .sukushopreset")
        try check(UTType.sukushoPreset.identifier == "com.tommyent.sukusho.preset"
                  && UTType.screendropPreset.identifier == "com.fayazahmed.screendrop.preset", "The preset types changed")

        let editor = AnnotationBackgroundPresetStore.shared
        var settings = AnnotationBackgroundSettings()
        settings.style = .gradient(AnnotationBackgroundGradient.presets[0])
        let saved = try require(editor.savePreset(named: "Shot \(UUID().uuidString.prefix(4))", settings: settings))
        let exported = try editor.exportedData(for: saved.id).data
        try check(try format(exported) == "sukusho-screenshot-presets", "A screenshot style says \(try format(exported))")
        let oldShot = try legacy(exported, from: "sukusho-screenshot-presets", to: "screendrop-screenshot-presets")
        let newImport = try editor.importStyles(from: write(exported, "shot.sukushopreset"))
        let oldImport = try editor.importStyles(from: write(oldShot, "shot.screendroppreset"))
        try check(newImport.presets.count == 1 && oldImport.presets.count == 1
                  && oldImport.presets[0].settings.style == settings.style, "A Screendrop screenshot style didn't import")

        let studio = RecordingStudioStylePresetStore.shared
        let style = RecordingStudioStyle(
            background: .gradient(AnnotationBackgroundGradient.presets[0]), padding: 0.1, cornerRadius: 0.05,
            shadow: 0.3, cursorScale: 2.5, hidesCursor: true,
            camera: RecordingCameraBubbleSettings(isVisible: false, center: CGPoint(x: 0.2, y: 0.7), size: 0.3, roundness: 0.4)
        )
        let studioSaved = try require(studio.savePreset(named: "Dawn \(UUID().uuidString.prefix(4))", style: style))
        let studioExported = try studio.exportedData(for: studioSaved.id).data
        try check(try format(studioExported) == "sukusho-recording-presets", "A Studio style says \(try format(studioExported))")
        let oldDawn = try legacy(studioExported, from: "sukusho-recording-presets", to: "screendrop-recording-presets")
        let studioNew = try studio.importStyles(from: write(studioExported, "dawn.sukushopreset"))
        let studioOld = try studio.importStyles(from: write(oldDawn, "dawn.screendroppreset"))
        try check(studioNew.presets.count == 1 && studioOld.presets.count == 1 && studioOld.presets[0].value == style,
                  "A Studio style from before the rename didn't import")

        // Each editor still names the other's older files rather than misreading them.
        do {
            _ = try studio.importStyles(from: write(oldShot, "shot-2.screendroppreset"))
            throw Failure(description: "Studio imported an older screenshot style")
        } catch AnnotationBackgroundPresetTransferError.screenshotStyle {}
        do {
            _ = try editor.importStyles(from: write(oldDawn, "dawn-2.screendroppreset"))
            throw Failure(description: "The image editor imported an older Studio style")
        } catch AnnotationBackgroundPresetTransferError.recordingStyle {}

        for preset in [saved] + newImport.presets + oldImport.presets { editor.deletePreset(id: preset.id) }
        for preset in [studioSaved] + studioNew.presets + studioOld.presets { studio.deletePreset(id: preset.id) }
        print("CHECK: presets, exports say Sukusho, Screendrop-named files of both kinds import")
    }
}
