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
/// Once a capture's text is read, Apple Intelligence, where available,
/// gives it a title and tag suggestions, under the same rules.
@MainActor
@Observable
final class CaptureLibraryIndex {
    static let shared = CaptureLibraryIndex()

    private(set) var entries: [String: CaptureTextEntry] = [:]
    /// Captures waiting to be read, or being read now.
    private(set) var pendingIDs: Set<String> = []
    /// Each entry's text, folded once for search.
    @ObservationIgnored private(set) var foldedText: [String: String] = [:]
    /// The model can run here; Settings shows its switch only then. New
    /// captures wait for it, while stored output still shows.
    private(set) var modelAvailable = false
    /// The Settings switch for titles and suggestions, as of the last plan.
    /// It stays in force while the model is gone and Settings hides it.
    private(set) var usesIntelligence = false
    /// Captures from before the model first ran that it hasn't seen yet.
    private(set) var olderWithoutInsight = 0
    /// Captures waiting for the model, or with it now.
    private(set) var insightsPending = 0
    /// Whether the model can run. The windowless check swaps it for a fake.
    @ObservationIgnored var modelAvailability: () -> Bool = { CaptureIntelligence.isModelAvailable }
    @ObservationIgnored var describer: (CaptureLibraryItem, CaptureTextEntry, CGImage?) async -> CaptureIntelligence.Outcome = { item, entry, image in
        let (paragraphs, transcript, source, isVideo) = (entry.paragraphs, entry.transcript, item.source, item.isVideo)
        return await Task.detached(priority: .background) {
            await CaptureIntelligence.describe(paragraphs: paragraphs, transcript: transcript, source: source, isVideo: isVideo, image: image)
        }.value
    }

    @ObservationIgnored private let store = CaptureTextIndexStore(
        directory: ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Library Index", isDirectory: true)
    )
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var latestItems: [CaptureLibraryItem]?
    @ObservationIgnored private var latestIsComplete = false
    @ObservationIgnored private var queue: [CaptureLibraryItem] = []
    @ObservationIgnored private var inFlight: CaptureLibraryItem?
    @ObservationIgnored private var insightQueue: [CaptureLibraryItem] = []
    @ObservationIgnored private var describing: CaptureLibraryItem?
    /// Fingerprints the model was too busy for this session.
    @ObservationIgnored private var insightLater: Set<String> = []
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

    /// Opts older captures in to titles and suggestions.
    func includeExistingCaptures() {
        UserDefaults.standard.set(true, forKey: ScreendropPreferences.libraryInsightsIncludeExistingKey)
        settingsDidChange()
    }

    /// What the model wrote about a capture, while it may show.
    func visibleInsight(_ id: String) -> CaptureInsight? {
        CaptureInsightRules.visible(entries[id]?.insight, enabled: usesIntelligence)
    }

    func suggestedTags(for item: CaptureLibraryItem, libraryTags: [String]) -> [String] {
        CaptureInsightRules.suggestions(appName: item.source?.appName, insight: visibleInsight(item.id), tags: item.tags,
                                        libraryTags: libraryTags, dismissed: entries[item.id]?.dismissedSuggestions ?? [])
    }

    /// Remembers that a suggestion isn't wanted on this capture. One not
    /// read yet gets an entry that is stale on purpose, so it's still read.
    func dismissSuggestion(_ tag: String, for item: CaptureLibraryItem) {
        guard isLoaded else { return }
        var entry = entries[item.id] ?? CaptureTextEntry(id: item.id, fingerprint: "", paragraphs: [])
        entry.dismissedSuggestions = (entry.dismissedSuggestions ?? []) + [CaptureInsightRules.fold(tag)]
        entries[item.id] = entry
        let store = store
        Task.detached(priority: .utility) { try? store.save(entry) }
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
        planInsights(items)
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
        if !queue.isEmpty || !insightQueue.isEmpty, runner == nil { runner = Task { await drain() } }
    }

    /// Queues captures the model hasn't seen, when it may run.
    private func planInsights(_ items: [CaptureLibraryItem]) {
        let available = modelAvailability(), enabled = ScreendropPreferences.libraryUsesIntelligence
        if available != modelAvailable { modelAvailable = available }
        if enabled != usesIntelligence {
            usesIntelligence = enabled
            CaptureLibraryModel.shared.insightsDidChange()
        }
        var older = 0
        if CaptureInsightRules.runs(modelAvailable: available, enabled: enabled, readsText: ScreendropPreferences.libraryReadsText) {
            let plan = CaptureTextIndexPlan.dueForInsight(
                items.filter { $0.id != describing?.id }.map { .init(id: $0.id, fingerprint: $0.thumbnailKey, createdAt: $0.createdAt) },
                entries: entries, since: ScreendropPreferences.libraryInsightsSince,
                includesExisting: ScreendropPreferences.libraryInsightsIncludeExisting, skipping: insightLater)
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            insightQueue = plan.due.compactMap { byID[$0.id] }
            older = plan.older
        } else {
            insightQueue = []
        }
        if older != olderWithoutInsight { olderWithoutInsight = older }
        updatePending()
    }

    private func drain() async {
        defer { runner = nil }
        while !Task.isCancelled, !queue.isEmpty || !insightQueue.isEmpty {
            if Self.shouldPause() {
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            // Every capture's text is read before the model sees any.
            guard !queue.isEmpty else {
                await describeNext()
                if let latestItems { sync(latestItems, isComplete: latestIsComplete) }
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
            case .read(var entry):
                // A capture deleted while it was read keeps no entry.
                if latestItems?.contains(where: { $0.id == item.id }) == true {
                    // An edit keeps the title the user has seen, and their dismissals.
                    entry.insight = entries[item.id]?.insight
                    entry.dismissedSuggestions = entries[item.id]?.dismissedSuggestions
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
        insightQueue = []
        updatePending()
    }

    /// Asks the model about the next capture and stores its answer, or its
    /// refusal, so it isn't asked again.
    private func describeNext() async {
        let item = insightQueue.removeFirst()
        guard let entry = entries[item.id] else { return }
        describing = item
        updatePending()
        defer {
            describing = nil
            updatePending()
        }
        let image = await Self.image(for: item)
        guard !Self.shouldPause() else { return insightQueue.insert(item, at: 0) }
        switch await describer(item, entry, image) {
        case .later:
            insightLater.insert(item.thumbnailKey)
        case .insight(let insight):
            // A capture deleted while the model looked keeps no answer.
            guard latestItems?.contains(where: { $0.id == item.id }) == true, var current = entries[item.id] else { return }
            current.insight = insight
            let store = store
            try? await Task.detached(priority: .utility) { [current] in try store.save(current) }.value
            entries[item.id] = current
            CaptureLibraryModel.shared.insightsDidChange()
        }
    }

    private func updatePending() {
        let ids = Set(queue.map(\.id) + (inFlight.map { [$0.id] } ?? []))
        if ids != pendingIDs { pendingIDs = ids }
        let insights = insightQueue.count + (describing == nil ? 0 : 1)
        if insights != insightsPending { insightsPending = insights }
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

    /// What the model looks at: the screenshot, or a recording's first frame.
    nonisolated private static func image(for item: CaptureLibraryItem) async -> CGImage? {
        let size = 1280
        guard item.isVideo else { return await decode(item.fileURL, maxSize: size) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        return try? await generator.image(at: .zero).image
    }

    /// The image upright, at `CaptureTextIndexPlan.readingSize` or `maxSize`.
    nonisolated private static func decode(_ url: URL, maxSize: Int = .max) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    return continuation.resume(returning: nil)
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let size = min(maxSize, CaptureTextIndexPlan.readingSize(width: properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                                                         height: properties?[kCGImagePropertyPixelHeight] as? Int ?? 0))
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
