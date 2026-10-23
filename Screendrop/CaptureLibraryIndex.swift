@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
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
            if let latestItems { sync(latestItems) } else { CaptureLibraryModel.shared.refresh() }
        }
    }

    func settingsDidChange() {
        if let latestItems { sync(latestItems) }
    }

    /// Forgets captures that are gone and queues every capture whose text is
    /// missing or stale.
    func sync(_ items: [CaptureLibraryItem]) {
        latestItems = items
        guard isLoaded else { return }
        let gone = CaptureTextIndexPlan.removed(entryIDs: entries.keys, liveIDs: Set(items.map(\.id)))
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
        while ScreendropPreferences.libraryReadsText, !queue.isEmpty {
            if shouldPause {
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            let item = queue.removeFirst()
            inFlight = item
            updatePending()
            let entry = await Self.read(item)
            inFlight = nil
            if let entry {
                // A capture deleted while it was read keeps no entry.
                if latestItems?.contains(where: { $0.id == item.id }) == true {
                    let store = store
                    // A failed save only costs a re-read at the next launch.
                    try? await Task.detached(priority: .utility) { try store.save(entry) }.value
                    entries[item.id] = entry
                    foldedText[item.id] = Self.fold(entry)
                    CaptureLibraryModel.shared.textIndexDidChange()
                }
            } else {
                unreadable.insert(item.thumbnailKey)
            }
            // Re-plans, so a capture edited while it was read is read again.
            if let latestItems { sync(latestItems) }
        }
        queue = []
        updatePending()
    }

    private func updatePending() {
        let ids = Set(queue.map(\.id) + (inFlight.map { [$0.id] } ?? []))
        if ids != pendingIDs { pendingIDs = ids }
    }

    /// Recording, Low Power Mode and a hot Mac all come before indexing.
    private var shouldPause: Bool {
        ScreenRecordingManager.shared.isActive
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

    /// Nil when nothing could be read, so the capture is tried again at the
    /// next launch rather than stored as having no text.
    nonisolated private static func read(_ item: CaptureLibraryItem) async -> CaptureTextEntry? {
        await ImageTextWarmUp.shared.waitUntilReady()
        var results: [[CaptureTextLine]?] = []
        if item.isVideo {
            for frame in await videoFrames(item) {
                results.append(await recognize { frame })
            }
        } else {
            let url = item.fileURL
            results.append(await recognize { ScreenshotImageLoader.uprightImage(at: url) })
        }
        let transcript = item.session?.effectiveEditDocument()?.subtitleCues.map { $0.map(\.text).joined(separator: " ") }
        let frames = results.compactMap { $0 }
        guard !frames.isEmpty || transcript?.isEmpty == false else { return nil }
        // Frames of one recording repeat most of their text.
        var seen = Set<String>()
        let paragraphs = frames.flatMap(CaptureReadableText.paragraphs).filter { seen.insert($0).inserted }
        return CaptureTextEntry(id: item.id, fingerprint: item.thumbnailKey, paragraphs: paragraphs,
                                transcript: transcript?.isEmpty == false ? transcript : nil)
    }

    /// Decodes and reads one image on a background queue: Vision's work is
    /// synchronous, and 25 s or more while it's cold.
    nonisolated private static func recognize(_ image: @escaping @Sendable () -> CGImage?) async -> [CaptureTextLine]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                continuation.resume(returning: image().flatMap { try? ImageTextRecognizer.recognizeLines(in: $0) })
            }
        }
    }

    /// The first frame, the middle and near the end of a recording.
    nonisolated private static func videoFrames(_ item: CaptureLibraryItem) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.fileURL))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let duration = item.duration ?? 0
        var frames: [CGImage] = []
        for fraction in [0, 0.5, 0.9].prefix(duration > 2 ? 3 : 1) {
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { frames.append(image) }
        }
        return frames
    }
}
