//
//  RecordingExportBenchmark.swift
//  Screendrop
//
//  Debug-only headless export timing. Launch the binary with
//  `-benchmarkExport <path to .sukushorec>` and it renders that
//  project's Studio export, prints the wall time to stdout, deletes the
//  output (unless `-benchmarkKeepOutput YES`), and exits - no windows,
//  hotkeys, or updater. The exporter's own StudioExport log lines carry
//  the per-stage breakdown.
//
//  The project's saved export settings apply unless overridden with
//  `-benchmarkCodec`, `-benchmarkFPS`, `-benchmarkMotionBlur`, or
//  `-benchmarkResolution`, using the settings' raw values ("HEVC",
//  "30 fps", "YES", "1080p").
//

#if DEBUG
import AppKit
import Foundation

enum RecordingExportBenchmark {
    static let argumentKey = "benchmarkExport"

    /// Returns true when this launch is a benchmark run; the caller must
    /// then skip normal startup.
    static func runIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: argumentKey) else { return false }
        let session = RecordingSession(directoryURL: URL(fileURLWithPath: path).standardizedFileURL)
        Task {
            do {
                var configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
                applyOverrides(to: &configuration.exportSettings)
                let started = CFAbsoluteTimeGetCurrent()
                let outputURL = try await RecordingStudioExporter().export(configuration) { _ in }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                let keepsOutput = UserDefaults.standard.bool(forKey: "benchmarkKeepOutput")
                if !keepsOutput { try? FileManager.default.removeItem(at: outputURL) }
                let settings = configuration.exportSettings
                print(
                    "benchmarkExport seconds=\(String(format: "%.2f", elapsed))"
                        + " codec=\(settings.codec.rawValue)"
                        + " fps=\(settings.effectiveFrameRate.framesPerSecond)"
                        + " motionBlur=\(settings.effectiveMotionBlurEnabled)"
                        + " canvas=\(Int(configuration.canvasSize.width))x\(Int(configuration.canvasSize.height))"
                        + (keepsOutput ? " output=\(outputURL.path)" : "")
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("benchmarkExport failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private static func applyOverrides(to settings: inout VideoCompressionSettings) {
        let defaults = UserDefaults.standard
        if let codec = defaults.string(forKey: "benchmarkCodec").flatMap(VideoCompressionCodec.init(rawValue:)) {
            settings.codec = codec
        }
        if let frameRate = defaults.string(forKey: "benchmarkFPS").flatMap(VideoExportFrameRate.init(rawValue:)) {
            settings.frameRate = frameRate
        }
        if defaults.object(forKey: "benchmarkMotionBlur") != nil {
            settings.motionBlurEnabled = defaults.bool(forKey: "benchmarkMotionBlur")
        }
        if let resolution = defaults.string(forKey: "benchmarkResolution")
            .flatMap(VideoCompressionResolution.init(rawValue:)) {
            settings.resolution = resolution
        }
    }
}
#endif
