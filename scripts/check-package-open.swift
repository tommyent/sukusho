import Foundation
import UniformTypeIdentifiers

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
@main
struct PackageOpenChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func main() {
        do {
            try run()
            print("PASS: Recording package open & import types")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage outside temporary home: \(support.path)")

        // 1. Valid package inside Recordings passes.
        let inside = try RecordingSessionStore.createSession()
        try Data("stub".utf8).write(to: inside.screenURL)
        let validatedInside = try ScreendropApp.validatedRecordingPackage(at: inside.directoryURL)
        try check(validatedInside?.path == inside.directoryURL.resolvingSymlinksInPath().standardizedFileURL.path,
                  "Valid package inside Recordings rejected: \(String(describing: validatedInside))")

        // 2. Valid .sukushorec and .screendroprec outside Recordings pass.
        let outsideRoot = support.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        for ext in ["sukushorec", "screendroprec"] {
            let pkg = outsideRoot.appendingPathComponent("Shared.\(ext)", isDirectory: true)
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: pkg.appendingPathComponent("screen.mov"))
            let validated = try ScreendropApp.validatedRecordingPackage(at: pkg)
            try check(validated?.path == pkg.resolvingSymlinksInPath().standardizedFileURL.path,
                      "Valid .\(ext) outside Recordings rejected")
        }

        // 3. Symlinked package or symlinked screen.mov is rejected.
        let symlinkPkg = outsideRoot.appendingPathComponent("Link.sukushorec")
        try FileManager.default.createSymbolicLink(at: symlinkPkg, withDestinationURL: inside.directoryURL)
        do {
            _ = try ScreendropApp.validatedRecordingPackage(at: symlinkPkg)
            throw Failure(description: "Symlinked package was accepted")
        } catch is Failure { throw Failure(description: "Symlinked package accepted") } catch { }

        let badScreen = outsideRoot.appendingPathComponent("BadScreen.sukushorec", isDirectory: true)
        try FileManager.default.createDirectory(at: badScreen, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: badScreen.appendingPathComponent("screen.mov"), withDestinationURL: inside.screenURL)
        do {
            _ = try ScreendropApp.validatedRecordingPackage(at: badScreen)
            throw Failure(description: "Package with symlinked screen.mov was accepted")
        } catch is Failure { throw Failure(description: "Symlinked screen.mov accepted") } catch { }

        // 4. Non-recording files return nil (hand off to image check).
        let image = outsideRoot.appendingPathComponent("shot.png")
        try check(try ScreendropApp.validatedRecordingPackage(at: image) == nil, "PNG treated as recording package")

        // 5. Studio video overlay import panel still includes .sukushorec and .screendroprec.
        let importTypes = RecordingVideoOverlay.importContentTypes
        let extensions = Set(importTypes.compactMap(\.preferredFilenameExtension))
        try check(extensions.contains("sukushorec") && extensions.contains("screendroprec"),
                  "RecordingVideoOverlay.importContentTypes missing recording extensions: \(importTypes)")

        print("CHECK: Finder open validates inside/outside packages, rejects symlinks, and Studio import types keep .sukushorec/.screendroprec")
    }
}
