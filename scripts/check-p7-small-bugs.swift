import Foundation

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
@main
struct P7SmallBugsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func main() {
        do {
            try run()
            print("PASS: P7 small bugs")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage outside temporary home: \(support.path)")

        // 1. Canonical editor URL deduplicates symlinks, relative components, and trailing-slash variants.
        let session = try RecordingSessionStore.createSession()
        try Data("stub".utf8).write(to: session.screenURL)
        let pkg = session.directoryURL
        let noSlash = URL(fileURLWithPath: pkg.path, isDirectory: false)
        let withSlash = URL(fileURLWithPath: pkg.path, isDirectory: true)
        let dotted = URL(fileURLWithPath: pkg.deletingLastPathComponent().path + "/./" + pkg.lastPathComponent, isDirectory: false)
        let symlink = pkg.deletingLastPathComponent().appendingPathComponent("Alias.sukushorec")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: pkg)
        let tmpAliasPath = pkg.path.hasPrefix("/private/tmp/")
            ? "/tmp/" + pkg.path.dropFirst("/private/tmp/".count)
            : pkg.path
        let tmpAlias = URL(fileURLWithPath: tmpAliasPath, isDirectory: false)

        let canonical = [noSlash, withSlash, dotted, symlink, tmpAlias].map(ScreendropApp.canonicalEditorURL)
        try check(Set(canonical).count == 1, "Editor URL aliases did not canonicalize to one URL: \(canonical)")

        // 2. CaptureSessionSnapshots.encode matches CaptureManifest.decoder (.iso8601).
        struct DatedDoc: Codable, Equatable { var stampedAt: Date }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try CaptureSessionSnapshots.encode(DatedDoc(stampedAt: date))
        let decoded = try CaptureManifest.decoder.decode(DatedDoc.self, from: data)
        try check(decoded == DatedDoc(stampedAt: date), "CaptureSessionSnapshots date strategy disagreed with CaptureManifest.decoder")

        print("CHECK: editor URL aliases canonicalize to one window key and snapshot dates match CaptureManifest.decoder")
    }
}
