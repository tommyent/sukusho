import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
@main
struct RecordingRecoveryChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB),
            size: .init(width: 160, height: 120)
        )
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            var pixels = try CVMutablePixelBuffer(attributes)
            try pixels.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first,
                      let context = CGContext(data: plane.bytes.baseAddress, width: 160, height: 120,
                                              bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                else { throw Failure(description: "Cannot create pixel buffer") }
                context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        try check(writer.status == .completed, "Movie fixture failed")
    }

    static func main() async {
        do {
            try await run()
            print("PASS: Recording crash recovery")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage outside temporary home: \(support.path)")

        // 1. Newer captureMode ("tab") must survive recovery untouched.
        let newer = try RecordingSessionStore.createSession()
        try await makeMovie(at: newer.screenURL)
        let newerBytes = Data(#"{"captureMode":"tab","createdAt":"2026-11-20T12:00:00Z","duration":1,"pixelHeight":120,"pixelWidth":160,"version":1}"#.utf8)
        try newerBytes.write(to: newer.captureManifestURL)
        do {
            _ = try newer.loadCaptureManifestStrict()
            throw Failure(description: "Expected loadCaptureManifestStrict to throw on unknown captureMode")
        } catch is Failure { throw Failure(description: "Unexpected pass") } catch { }
        try check(!RecordingRecoveryCoordinator.needsRecovery(newer), "Newer manifest marked for recovery")

        // 2. Corrupt JSON must survive recovery untouched.
        let corrupt = try RecordingSessionStore.createSession()
        try await makeMovie(at: corrupt.screenURL)
        let corruptBytes = Data("{not json".utf8)
        try corruptBytes.write(to: corrupt.captureManifestURL)
        try check(!RecordingRecoveryCoordinator.needsRecovery(corrupt), "Corrupt manifest marked for recovery")

        // 3. Dangling symlink must not be treated as ENOENT.
        let dangling = try RecordingSessionStore.createSession()
        try await makeMovie(at: dangling.screenURL)
        try FileManager.default.createSymbolicLink(atPath: dangling.captureManifestURL.path, withDestinationPath: "/nonexistent/target.json")
        try check(!RecordingRecoveryCoordinator.needsRecovery(dangling), "Dangling symlink marked for recovery")

        // 4. Truly missing capture.json IS recovered.
        let interrupted = try RecordingSessionStore.createSession()
        try await makeMovie(at: interrupted.screenURL)
        try check(try interrupted.loadCaptureManifestStrict() == nil, "Missing manifest did not return nil")
        try check(RecordingRecoveryCoordinator.needsRecovery(interrupted), "Missing manifest not marked for recovery")

        var imported: [URL] = []
        let count = await RecordingRecoveryCoordinator.recoverInterrupted([newer, corrupt, dangling, interrupted]) {
            imported.append($0.directoryURL)
        }
        try check(count == 1 && imported == [interrupted.directoryURL], "Recovered \(count) sessions: \(imported)")
        try check(try Data(contentsOf: newer.captureManifestURL) == newerBytes, "Newer capture.json was modified")
        try check(try Data(contentsOf: corrupt.captureManifestURL) == corruptBytes, "Corrupt capture.json was modified")
        let recovered = try interrupted.loadCaptureManifestStrict()
        try check(recovered?.pixelWidth == 160 && recovered?.pixelHeight == 120 && (recovered?.duration ?? 0) > 0.5,
                  "Recovered manifest missing playable metadata: \(String(describing: recovered))")
        print("CHECK: unknown captureMode, corrupt JSON, and dangling symlink survive recovery untouched; missing manifest recovers")
    }
}
