// Compile against the Debug Dev module as in test-library-card-press.swift.
import Foundation
import Vision
@testable import Screendrop

@main
struct VisionFallbackTest {
    enum Failure: Error { case unavailable }

    static func main() async throws {
        var calls: [VNRequestTextRecognitionLevel] = []
        let empty = ImageTextRecognizer.withFallback { level in calls.append(level); return "" }
        precondition(empty.isEmpty && calls == [.accurate])

        calls.removeAll()
        let recovered = try ImageTextRecognizer.withFallback { level in
            calls.append(level)
            if level == .accurate { throw Failure.unavailable }
            return "Recovered"
        }
        precondition(recovered == "Recovered" && calls == [.accurate, .fast])

        calls.removeAll()
        do {
            try ImageTextRecognizer.withFallback { level in calls.append(level); throw Failure.unavailable }
            preconditionFailure("Both recognition failures must propagate")
        } catch Failure.unavailable {
            precondition(calls == [.accurate, .fast])
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let unreadable = await ImageTextRecognizer.recognizeText(at: missing)
        precondition(unreadable == nil)
        print("Empty accurate result kept; fast retry recovered; two failures propagated; unreadable image reported failure.")
    }
}
