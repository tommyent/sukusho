// Compile against the Debug Dev module as in test-library-card-press.swift.
// Run with CFFIXED_USER_HOME="$(mktemp -d /private/tmp/sukusho-index-XXXXXX)".
import CoreGraphics
import Foundation
import ImageIO
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
        index.describer = { item, _, _ in
            calls[item.id, default: 0] += 1
            if calls[item.id] == 1 {
                if item.id == firstID {
                    await withCheckedContinuation { hold = $0 } // Ignore cancellation until the test releases this call.
                    cancelledLateAnswer = Task.isCancelled
                    return .insight(CaptureInsight(title: "Expired answer"))
                }
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
            let words = store.loadAll()[secondID]?.paragraphs.joined().filter { !$0.isWhitespace }
            return words?.localizedCaseInsensitiveContains("captureisready") == true
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
    }
}
