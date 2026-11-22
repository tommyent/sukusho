import Foundation

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
@main
struct AtomicPointerWriteChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func main() {
        do {
            try run()
            print("PASS: Atomic pointer capture write")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage outside temporary home: \(support.path)")

        let session = try RecordingSessionStore.createSession()
        let initial = PointerCaptureFile(travel: [.init(time: 0.5, x: 0.25, y: 0.75)])
        try session.writePointerCapture(initial)
        let originalBytes = try Data(contentsOf: session.pointerCaptureURL)
        try check(session.loadPointerCapture() == initial, "Initial atomic write failed to reload")

        // Make the package directory read-only while keeping input.json writable:
        // atomic replacement cannot create a sibling temp file, whereas a non-atomic
        // direct overwrite would succeed and risk truncating input.json.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: session.directoryURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: session.directoryURL.path) }

        let replacement = PointerCaptureFile(travel: [.init(time: 1.0, x: 0.9, y: 0.1)])
        var threw = false
        do {
            try session.writePointerCapture(replacement)
        } catch {
            threw = true
        }
        try check(threw, "writePointerCapture silently fell back to a non-atomic write")
        try check(try Data(contentsOf: session.pointerCaptureURL) == originalBytes,
                  "Original input.json was modified after atomic write failed")

        print("CHECK: writePointerCapture fails when atomic staging cannot run and leaves input.json untouched")
    }
}
