import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Names and describes copied images the way the Library does captures: their text is read on this Mac
/// (Settings › Library › Read text in captures), then Apple's on-device model gives a title, keywords and a
/// category (Use Apple Intelligence…). One image at a time, after each refresh, pausing as the Library's
/// index does. An image that is a Library capture keeps the Library's own name and isn't asked again.
/// Without the model an image keeps its plain title, "Image (W×H)".
@MainActor
final class ClipboardDescriber {
    static let shared = ClipboardDescriber()

    private var running: Task<Void, Never>?
    /// Images the model was busy for this session, and images that couldn't be read: not retried until relaunch.
    private var skipped: Set<String> = []
    private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "Clipboard")

    private init() {}

    /// Starts on the next image that's due, if nothing is running. The store's write refreshes the model,
    /// which calls this again for the one after.
    func update(_ entries: [ClipboardEntry], store: ClipboardHistoryStore?) {
        guard running == nil, let store else { return }
        let reads = ScreendropPreferences.libraryReadsText
        let describes = CaptureInsightRules.runs(modelAvailable: CaptureIntelligence.isModelAvailable,
                                                 enabled: ScreendropPreferences.libraryUsesIntelligence, readsText: reads)
        guard let entry = entries.first(where: { entry in
            entry.kind == .image && entry.libraryPath == nil && entry.imageURL != nil && !skipped.contains(entry.id)
                && ((reads && entry.readText == nil) || (describes && !entry.isDescribed))
        }), let url = entry.imageURL else { return }
        let source = ClipboardHistoryModel.shared.appName(entry.sourceBundleID)
            .map { CaptureSource(bundleIdentifier: entry.sourceBundleID, appName: $0) }
        running = Task {
            defer {
                running = nil
                ClipboardHistoryModel.shared.refresh()
            }
            if CaptureLibraryIndex.shouldPause() {
                try? await Task.sleep(for: .seconds(30))
                return
            }
            var text = entry.readText
            if text == nil, reads {
                _ = await ImageTextWarmUp.shared.waitUntilReady()
                guard let read = await Self.readText(at: url) else {
                    logger.error("Clipboard image text couldn't be read")
                    skipped.insert(entry.id)
                    return
                }
                text = read
                try? await store.setReadText(entry.id, read)
            }
            guard describes, !entry.isDescribed else { return }
            let paragraphs = (text ?? "").split(separator: "\n").map(String.init)
            let image = await Self.decode(url, maxSize: 1280)
            let outcome = await Task.detached(priority: .background) {
                await CaptureIntelligence.describe(paragraphs: paragraphs, transcript: nil, source: source, isVideo: false, image: image)
            }.value
            switch outcome {
            case .later:
                skipped.insert(entry.id)
            case .insight(let insight):
                try? await store.setDescription(entry.id, title: insight.declined ? nil : insight.title,
                                                keywords: insight.keywords, category: insight.category)
            }
        }
    }

    /// The image's text as paragraphs, one per line, capped; "" when it has none, nil when Vision failed.
    nonisolated private static func readText(at url: URL) async -> String? {
        guard let image = await decode(url, maxSize: 2560) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                guard let lines = try? ImageTextRecognizer.recognizeLines(in: image) else {
                    return continuation.resume(returning: nil)
                }
                let text = CaptureReadableText.paragraphs(from: lines).joined(separator: "\n")
                continuation.resume(returning: String(text.prefix(4000)))
            }
        }
    }

    nonisolated private static func decode(_ url: URL, maxSize: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSize,
                ] as CFDictionary))
            }
        }
    }
}
