// Compile against the Debug Dev module as in test-library-card-press.swift.
// Run with CFFIXED_USER_HOME="$(mktemp -d /private/tmp/sukusho-index-XXXXXX)".
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
@testable import Screendrop

@main
@MainActor
struct LibraryIndexStallTest {
    struct Failure: Error { let message: String }

    static func waitFor(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: message) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func main() async throws {
        let support = ScreendropStorage.applicationSupportDirectory
        precondition(support.path.contains("/tmp/sukusho-index-") && !FileManager.default.fileExists(atPath: support.path))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = support.appendingPathComponent("sample.png")
        let image = ImageTextWarmUp.sampleImage()!
        let png = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(png, image, nil)
        precondition(CGImageDestinationFinalize(png))
        let history = ScreenshotHistoryStore.shared, index = CaptureLibraryIndex.shared
        let store = CaptureTextIndexStore(directory: support.appendingPathComponent("Library Index"))
        index.modelAvailability = { true }
        index.retryDelay = 1
        index.insightTimeout = .seconds(12)
        var hold: CheckedContinuation<Void, Never>?
        var calls: [String: Int] = [:]
        var firstID = ""
        var cancelledLateAnswer = false
        let timedOutAt = Mutex<ContinuousClock.Instant?>(nil)
        var nextAllowedCall: ContinuousClock.Instant?
        index.describer = { item, _, _ in
            if let timeout = timedOutAt.withLock({ $0 }) {
                precondition(ContinuousClock.now >= timeout + .seconds(index.retryDelay), "A capture bypassed the timeout cooldown")
            }
            if let nextAllowedCall {
                precondition(ContinuousClock.now >= nextAllowedCall, "A different capture bypassed model backoff")
            }
            calls[item.id, default: 0] += 1
            if calls[item.id] == 1 {
                if item.id == firstID {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { hold = $0 } // Stay outstanding until released.
                    } onCancel: {
                        timedOutAt.withLock { $0 = .now }
                    }
                    cancelledLateAnswer = Task.isCancelled
                    return .insight(CaptureInsight(title: "Expired answer"))
                }
                // The first timeout and this busy response are consecutive model failures.
                nextAllowedCall = .now + .seconds(2 * index.retryDelay)
                return .later
            }
            return .insight(CaptureInsight(title: "Retried answer"))
        }
        index.start()
        try await waitFor("Initial plan did not run") { index.modelAvailable && index.usesIntelligence }
        history.importScreenshot(from: source)
        firstID = history.items[0].id.uuidString
        try await waitFor("First insight never started") { hold != nil }
        history.importScreenshot(from: source)
        let secondID = history.items[0].id.uuidString
        try await waitFor("New capture text was not indexed during the held insight") {
            store.loadAll()[secondID]?.paragraphs.joined().contains { !$0.isWhitespace } == true
        }
        guard calls[secondID] == nil && calls[firstID] == 1 else { throw Failure(message: "Expected OCR before insight timeout") }
        print("Second capture's text reached disk before the first insight timed out.")
        try await waitFor("Timed-out and busy requests did not retry without a refresh") {
            [firstID, secondID].allSatisfy { store.loadAll()[$0]?.insight?.title == "Retried answer" }
        }
        hold?.resume()
        try await waitFor("Deadline did not cancel the expired request") { cancelledLateAnswer }
        precondition(calls == [firstID: 2, secondID: 2])
        precondition(index.entries[firstID]?.insight?.title == "Retried answer" && index.insightsPending == 0)
        print("Timed-out and busy insights retried. The late answer did not overwrite the retry.")

        index.retryDelay = 3600
        var attempts = 0
        index.describer = { _, _, _ in
            attempts += 1
            return attempts < 3 ? .later : .insight(CaptureInsight(title: "After opt-in"))
        }
        history.importScreenshot(from: source)
        let newID = history.items[0].id.uuidString
        try await waitFor("The model did not enter cooldown") { attempts == 1 }
        index.includeExistingCaptures()
        try await waitFor("Including existing captures did not retry the model") { attempts == 2 }
        UserDefaults.standard.set(false, forKey: ScreendropPreferences.libraryUsesIntelligenceKey)
        index.settingsDidChange()
        precondition(!index.usesIntelligence)
        UserDefaults.standard.set(true, forKey: ScreendropPreferences.libraryUsesIntelligenceKey)
        index.settingsDidChange()
        try await waitFor("Turning titles on did not retry the model") {
            store.loadAll()[newID]?.insight?.title == "After opt-in"
        }
        precondition(attempts == 3)
        print("Including existing captures and turning titles back on each retried during an hour-long cooldown.")
    }
}
