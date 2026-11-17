//
//  ScreenshotOptimizedCopy.swift
//  Screendrop
//
//  Copy, as every image copy in the app makes it: optimized first when
//  Settings › Optimize says so, the original with ⇧⌘C.
//

import AppKit
import UniformTypeIdentifiers

extension ScreenshotFileActions {
    /// Copies the image at `url`. With Settings › Optimize › Optimize when copying on, a PNG or JPEG is made
    /// smaller first, with the same pixels, and the pasteboard is written once, with the result. Esc while
    /// that runs copies the original at once, and `original` (⇧⌘C) never optimizes. Returns the saving to
    /// show, such as "↓18% · 1.1 MB", when the copy came out smaller.
    @discardableResult
    static func copyImageToClipboard(from url: URL, original: Bool = false) async throws -> String? {
        let contentType = UTType(filenameExtension: url.pathExtension)
        let dataType: NSPasteboard.PasteboardType = if contentType?.conforms(to: .jpeg) == true {
            NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        } else {
            .png
        }
        guard !original, OptimizePreferences.whenCopying else {
            try await copyImageToClipboard(from: url, dataType: dataType)
            return nil
        }
        let copied = try await OptimizedImageCopy.shared.copy(url, optimize: { try await optimizedForCopy($0) }) {
            try await ScreenshotClipboardImage.item(from: $0, dataType: dataType, includeTIFF: ScreendropPreferences.copyTIFF)
        }
        guard let copied, copied.outcome == .optimized else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: copied.resultByteCount, countStyle: .file)
        return "\(ImageOptimizationResult.saving(from: copied.originalByteCount, to: copied.resultByteCount)) · \(size)"
    }

    /// The file to copy for `url`: its optimized result, or the file itself when nothing smaller comes out.
    /// Waits for the optimizer however long it takes, with a cue once the wait can be noticed. Esc stops
    /// the wait: the original is copied as it is.
    static func optimizedForCopy(_ url: URL) async throws -> ImageOptimizationResult {
        final class Finished { var result: Result<ImageOptimizationResult, Error>? }
        let work = Task.detached { try await ImageOptimizer.shared.optimize(url, effort: OptimizePreferences.quietEffort) }
        let finished = Finished()
        let watcher = Task { finished.result = await work.result }
        let toast = CaptureTextFeedbackPresenter.shared
        let clock = ContinuousClock()
        let started = clock.now
        var showsCue = false
        defer {
            watcher.cancel()
            if showsCue { toast.dismissWorking() }
        }
        while finished.result == nil {
            do {
                try await Task.sleep(for: .milliseconds(30))
            } catch {
                work.cancel()
                throw error
            }
            // Read, not taken, as the shake shelf reads it: needs no permission, and Esc still reaches the app in front.
            if CGEventSource.keyState(.combinedSessionState, key: 53) {
                work.cancel()
                return .original(url)
            }
            if !showsCue, clock.now - started > .milliseconds(400) {
                showsCue = true
                toast.showWorking("Optimizing…", detail: "Esc copies the original",
                                  displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: true))
            }
        }
        return try finished.result?.get() ?? .original(url)
    }
}
