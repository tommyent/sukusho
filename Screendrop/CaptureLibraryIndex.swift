@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Reads the words in every Library capture so search can find them: the
/// text in a screenshot, in a few frames of a recording, and a recording's
/// saved captions. One capture at a time, newest first, at background
/// priority, pausing while recording, in Low Power Mode or when the Mac runs
/// hot. Runs from launch, so new captures are read with the Library closed.
@MainActor
@Observable
final class CaptureLibraryIndex {
    static let shared = CaptureLibraryIndex()

    private(set) var entries: [String: CaptureTextEntry] = [:]
    /// Captures waiting to be read, or being read now.
    private(set) var pendingIDs: Set<String> = []
    /// Each entry's text, folded once for search.
    @ObservationIgnored private(set) var foldedText: [String: String] = [:]

    @ObservationIgnored private let store = CaptureTextIndexStore(
        directory: ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Library Index", isDirectory: true)
    )
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var latestItems: [CaptureLibraryItem]?
    @ObservationIgnored private var latestIsComplete = false
    @ObservationIgnored private var queue: [CaptureLibraryItem] = []
    @ObservationIgnored private var inFlight: CaptureLibraryItem?
    /// Fingerprints that couldn't be read this session, so an unreadable
    /// file isn't retried on every refresh.
    @ObservationIgnored private var unreadable: Set<String> = []
    @ObservationIgnored private var runner: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        observeHistory()
        let store = store
        Task {
            let loaded = await Task.detached(priority: .utility) { store.loadAll() }.value
            entries = loaded
            foldedText = loaded.mapValues(Self.fold)
            isLoaded = true
            CaptureLibraryModel.shared.textIndexDidChange()
            if let latestItems { sync(latestItems, isComplete: latestIsComplete) } else { CaptureLibraryModel.shared.refresh() }
        }
    }

    func settingsDidChange() {
        if let latestItems { sync(latestItems, isComplete: latestIsComplete) }
    }

    /// Forgets captures that are gone and queues every capture whose text is
    /// missing or stale. `isComplete` is false when History or the Recordings
    /// folder couldn't be read in full, so missing captures may still exist.
    func sync(_ items: [CaptureLibraryItem], isComplete: Bool) {
        latestItems = items
        latestIsComplete = isComplete
        guard isLoaded else { return }
        let gone = CaptureTextIndexPlan.removed(entryIDs: entries.keys, liveIDs: Set(items.map(\.id)), isComplete: isComplete)
        if !gone.isEmpty {
            for id in gone {
                entries[id] = nil
                foldedText[id] = nil
            }
            let store = store
            Task.detached(priority: .utility) { store.remove(ids: gone) }
        }
        guard ScreendropPreferences.libraryReadsText else {
            queue = []
            updatePending()
            return
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = CaptureTextIndexPlan.stale(
            items.filter { $0.id != inFlight?.id }.map { .init(id: $0.id, fingerprint: $0.thumbnailKey, createdAt: $0.createdAt) },
            entries: entries, skipping: unreadable
        )
        queue = stale.compactMap { byID[$0.id] }
        updatePending()
        if !queue.isEmpty, runner == nil { runner = Task { await drain() } }
    }

    private func drain() async {
        defer { runner = nil }
        while !Task.isCancelled, ScreendropPreferences.libraryReadsText, !queue.isEmpty {
            if Self.shouldPause() {
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            let item = queue.removeFirst()
            inFlight = item
            updatePending()
            let outcome = await Self.read(item)
            inFlight = nil
            switch outcome {
            case .paused:
                // Not read yet, and not unreadable: first in line once it may run.
                queue.insert(item, at: 0)
                continue
            case .unreadable:
                unreadable.insert(item.thumbnailKey)
            case .read(let entry):
                // A capture deleted while it was read keeps no entry.
                if latestItems?.contains(where: { $0.id == item.id }) == true {
                    let store = store
                    // A failed save only costs a re-read at the next launch.
                    try? await Task.detached(priority: .utility) { try store.save(entry) }.value
                    entries[item.id] = entry
                    foldedText[item.id] = Self.fold(entry)
                    CaptureLibraryModel.shared.textIndexDidChange()
                }
            }
            // Re-plans, so a capture edited while it was read is read again.
            if let latestItems { sync(latestItems, isComplete: latestIsComplete) }
        }
        queue = []
        updatePending()
    }

    private func updatePending() {
        let ids = Set(queue.map(\.id) + (inFlight.map { [$0.id] } ?? []))
        if ids != pendingIDs { pendingIDs = ids }
    }

    /// Recording, Low Power Mode and a hot Mac all come before indexing.
    private static func shouldPause() -> Bool {
        Task.isCancelled
            || ScreenRecordingManager.shared.isActive
            || ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// Refreshes the Library when History or the project list changes, so
    /// new captures are read even while its window is closed.
    private func observeHistory() {
        withObservationTracking {
            _ = ScreenshotHistoryStore.shared.items
            _ = RecordingProjectStore.shared.projects
        } onChange: {
            Task { @MainActor in
                CaptureLibraryModel.shared.refresh()
                CaptureLibraryIndex.shared.observeHistory()
            }
        }
    }

    nonisolated private static func fold(_ entry: CaptureTextEntry) -> String {
        CaptureLibraryQuery.fold(entry.displayParagraphs.joined(separator: "\n"))
    }

    // MARK: Reading

    private enum ReadOutcome {
        case read(CaptureTextEntry)
        /// Nothing could be read: tried again at the next launch rather than
        /// stored as having no text.
        case unreadable
        /// A pause began mid-read; nothing is stored and it stays queued.
        case paused
    }

    /// Checks for a pause before each frame and before Vision runs on each tile.
    nonisolated private static func read(_ item: CaptureLibraryItem) async -> ReadOutcome {
        await ImageTextWarmUp.shared.waitUntilReady()
        var frames: [[CaptureTextLine]?] = []
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.fileURL))
            generator.appliesPreferredTrackTransform = true
            let size = CaptureTextIndexPlan.readingSize(width: item.pixelWidth, height: item.pixelHeight)
            generator.maximumSize = CGSize(width: size, height: size)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let duration = item.duration ?? 0
            // The first frame, the middle and near the end.
            for fraction in [0, 0.5, 0.9].prefix(duration > 2 ? 3 : 1) {
                guard !(await shouldPause()) else { return .paused }
                let image = try? await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 600)).image
                guard let lines = await lines(in: image) else { return .paused }
                frames.append(lines)
            }
        } else {
            guard !(await shouldPause()) else { return .paused }
            guard let lines = await lines(in: await decode(item.fileURL)) else { return .paused }
            frames.append(lines)
        }
        let transcript = item.session?.effectiveEditDocument()?.subtitleCues.map { $0.map(\.text).joined(separator: " ") }
        return CaptureTextEntry(id: item.id, fingerprint: item.thumbnailKey, frames: frames, transcript: transcript)
            .map(ReadOutcome.read) ?? .unreadable
    }

    /// The image upright, at `CaptureTextIndexPlan.readingSize`.
    nonisolated private static func decode(_ url: URL) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    return continuation.resume(returning: nil)
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let size = CaptureTextIndexPlan.readingSize(width: properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                                            height: properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
                continuation.resume(returning: CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                ] as CFDictionary))
            }
        }
    }

    /// An image's lines, read in tiles when it's long (`CaptureTextTiling`),
    /// checking for a pause before each. Nil when a pause began; `.some(nil)`
    /// when the image or Vision failed.
    nonisolated private static func lines(in image: CGImage?) async -> [CaptureTextLine]?? {
        guard let image else { return .some(nil) }
        var pieces: [(tile: CaptureTextTiling.Tile, lines: [CaptureTextLine])] = []
        for tile in CaptureTextTiling.tiles(width: image.width, height: image.height) {
            guard !(await shouldPause()) else { return nil }
            guard let piece = image.cropping(to: tile.rect), let lines = await recognize(piece) else { return .some(nil) }
            pieces.append((tile, lines))
        }
        return CaptureTextTiling.merge(pieces, width: image.width, height: image.height)
    }

    /// Reads one image on a background queue: Vision's work is synchronous,
    /// and 25 s or more while it's cold.
    nonisolated private static func recognize(_ image: CGImage?) async -> [CaptureTextLine]? {
        guard let image else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                continuation.resume(returning: try? ImageTextRecognizer.recognizeLines(in: image))
            }
        }
    }
}
