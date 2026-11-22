//
//  RecordingTimelineThumbnails.swift
//  Screendrop
//
//  Level-of-detail thumbnail source for the Studio clip lane. Instead of one
//  fixed overview pass stretched to whatever width the lane happens to have,
//  the lane asks for the strip it is about to draw at the density the current
//  zoom needs. Requests are sampled in the background and cached per level, so
//  zooming in fills in sharper tiles while the coarse pass stands in.
//

import AVFoundation
import AppKit

/// Only cancellation crosses executors. Configuration and image requests
/// stay on the render task; AVFoundation owns cancellation of pending work.
nonisolated struct ImageGenerationCancellation: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    func cancel() { generator.cancelAllCGImageGeneration() }
}

@MainActor
final class RecordingTimelineThumbnailStore {
    nonisolated static let primarySourceKey = ""
    /// Shared decoded-bitmap byte cap across primary and all imported video sources.
    nonisolated static let defaultByteLimit = 48 * 1024 * 1024

    /// A tile of one video source: level 0 splits the whole movie into
    /// `baseTileCount` tiles and every level after it halves the spacing, so a
    /// tile at level *n* always sits inside tile `index / 2` of level *n - 1*.
    /// That nesting is what lets a missing dense tile fall back to the coarse
    /// image covering the same moment.
    nonisolated struct Key: Hashable, Sendable {
        var sourceKey: String = ""
        var level: Int
        var index: Int
    }

    nonisolated struct Request: Sendable {
        var key: Key
        var sourceTime: TimeInterval
        var tolerance: TimeInterval
    }

    nonisolated struct Sample: @unchecked Sendable {
        var key: Key
        var image: NSImage
    }

    private struct SourceEntry {
        var url: URL
        var duration: TimeInterval
        var redactions: [RecordingRedaction]
        /// Monotonic per-registration token so a late batch from an evicted or
        /// superseded registration (e.g. unredacted primary frames finishing
        /// after a mask was added) can never overwrite cache or retire newer
        /// pending requests.
        var generation: UInt64

        func matchesContent(url: URL, duration: TimeInterval, redactions: [RecordingRedaction]) -> Bool {
            self.url == url && self.duration == duration && self.redactions == redactions
        }
    }

    /// Tile layout for the lane: tiles cover `spacing` of source time each and
    /// start at `index * spacing` in absolute source time, never at the clip's
    /// edge. Anchoring to time rather than to a pixel width is what lets a lane
    /// that is being pinched keep the same tiles - they widen with the zoom and
    /// only subdivide when the detail level actually changes.
    nonisolated struct Grid: Equatable, Sendable {
        var level: Int
        var spacing: TimeInterval
    }

    /// Tiles across one source at the coarsest level - the overview strip a
    /// fitted timeline shows.
    private static let baseTileCount = 32
    /// Finest spacing worth sampling; below this neighboring tiles would be
    /// the same displayed frame anyway.
    private static let finestSpacing: TimeInterval = 0.1
    private static let batchSize = 8
    /// Bounded retries for missed tiles before giving up (with progressively
    /// wider tolerances so sparse GOPs can settle on a redacted nearby frame).
    private static let maxRetries = 2
    /// Requests still waiting when this many pile up are already scrolled
    /// past, so the oldest are dropped rather than rendered.
    private static let queueLimit = 240
    /// Shared tile count ceiling across all sources in addition to `byteLimit`.
    private static let cacheLimit = 700

    let byteLimit: Int
    /// Invoked on the main actor when new tiles land, so the AppKit lane can
    /// redraw itself without pushing a SwiftUI update per batch.
    var onChange: (() -> Void)?
    /// Renderer hook (defaults to AVAssetImageGenerator; overridable in tests).
    var renderBatch: @Sendable (URL, [Request], [RecordingRedaction]) async -> [Sample] = RecordingTimelineThumbnailStore.render

    private var sources: [String: SourceEntry] = [:]
    private var nextGeneration: UInt64 = 0
    private var activeBatch: (sourceKey: String, generation: UInt64)?
    private var images: [Key: NSImage] = [:]
    private var imageBytes: [Key: Int] = [:]
    private(set) var cachedBytes = 0
    private var insertionOrder: [Key] = []
    private var pending: Set<Key> = []
    private var retryCounts: [Key: Int] = [:]
    private var queue: [Key] = []
    private var task: Task<Void, Never>?
    private var settledLevels: [String: Int] = [:]
    private var frozenLevels: [String: Int] = [:]
    private var thawTask: Task<Void, Never>?

    init(byteLimit: Int = RecordingTimelineThumbnailStore.defaultByteLimit) {
        self.byteLimit = max(0, byteLimit)
    }

    var cachedTileCount: Int { images.count }

    static func byteCost(of image: NSImage) -> Int {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(cgImage.bytesPerRow * cgImage.height, cgImage.width * cgImage.height * 4)
        }
        let width = max(1, Int(image.size.width.rounded()))
        let height = max(1, Int(image.size.height.rounded()))
        return width * height * 4
    }

    /// Prepares the primary recording source, preserving any still-registered
    /// imported sources while refreshing primary tiles (e.g. after redaction edits).
    func prepare(url: URL, duration: TimeInterval, redactions: [RecordingRedaction] = []) {
        evictSource(key: Self.primarySourceKey)
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        nextGeneration &+= 1
        sources[Self.primarySourceKey] = SourceEntry(
            url: url,
            duration: safeDuration,
            redactions: redactions,
            generation: nextGeneration
        )
        onChange?()
        guard safeDuration > 0 else { return }
        for index in 0..<Self.baseTileCount {
            enqueue(Key(sourceKey: Self.primarySourceKey, level: 0, index: index), shouldPump: false)
        }
        pump()
    }

    /// Registers an imported video source under the same shared cache budget.
    func registerSource(key: String, url: URL, duration: TimeInterval, redactions: [RecordingRedaction] = []) {
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        if let existing = sources[key], existing.matchesContent(url: url, duration: safeDuration, redactions: redactions) {
            return
        }
        evictSource(key: key)
        nextGeneration &+= 1
        sources[key] = SourceEntry(
            url: url,
            duration: safeDuration,
            redactions: redactions,
            generation: nextGeneration
        )
        guard safeDuration > 0 else { return }
        for index in 0..<Self.baseTileCount {
            enqueue(Key(sourceKey: key, level: 0, index: index), shouldPump: false)
        }
        pump()
    }

    /// Immediately drops every cached tile, pending request, and metadata entry
    /// for a removed or refreshed source, cancelling an in-flight batch only if
    /// it belongs to that source. Keeps the cancelled batch tracked in `task`
    /// until it finishes draining so a replacement never starts a second
    /// concurrent decoder; completion restarts `pump()` for remaining work.
    func evictSource(key: String) {
        if activeBatch?.sourceKey == key {
            task?.cancel()
        }
        sources.removeValue(forKey: key)
        settledLevels.removeValue(forKey: key)
        frozenLevels.removeValue(forKey: key)
        for existingKey in Array(images.keys) where existingKey.sourceKey == key {
            images.removeValue(forKey: existingKey)
            if let cost = imageBytes.removeValue(forKey: existingKey) {
                cachedBytes = max(0, cachedBytes - cost)
            }
        }
        insertionOrder.removeAll { $0.sourceKey == key }
        pending = pending.filter { $0.sourceKey != key }
        retryCounts = retryCounts.filter { $0.key.sourceKey != key }
        queue.removeAll { $0.sourceKey == key }
    }

    /// Evicts any imported sources no longer referenced by `activeKeys`, always
    /// keeping the primary source intact.
    func syncImportedSources(keeping activeKeys: Set<String>) {
        let stale = sources.keys.filter { $0 != Self.primarySourceKey && !activeKeys.contains($0) }
        for key in stale {
            evictSource(key: key)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeBatch = nil
        thawTask?.cancel()
        thawTask = nil
        frozenLevels.removeAll()
    }

    func releaseResources() {
        cancel()
        images.removeAll()
        imageBytes.removeAll()
        cachedBytes = 0
        insertionOrder.removeAll()
        pending.removeAll()
        retryCounts.removeAll()
        queue.removeAll()
        sources.removeAll()
        settledLevels.removeAll()
        onChange = nil
    }

    /// Tile grid for tiles that should each cover at least `targetSpan` of
    /// source time - normally "one thumbnail's width of the lane".
    func grid(forTargetSpan targetSpan: TimeInterval, sourceKey: String = RecordingTimelineThumbnailStore.primarySourceKey) -> Grid {
        let duration = sources[sourceKey]?.duration ?? 0
        let base = baseSpacing(forDuration: duration)
        guard duration > 0, targetSpan > 0, base > 0 else {
            return Grid(level: 0, spacing: max(base, 0))
        }
        let level = frozenLevels[sourceKey] ?? self.level(forSpacing: targetSpan, duration: duration)
        if frozenLevels[sourceKey] == nil {
            settledLevels[sourceKey] = level
        }
        // The coarsest level can still be finer than a tile wants at fitted
        // zoom; grouping whole powers of two keeps tiles aligned with the
        // level grid, so zooming subdivides tiles instead of reshuffling them.
        var spacing = spacing(forLevel: level, duration: duration)
        while spacing > 0, spacing < targetSpan {
            spacing *= 2
        }
        return Grid(level: level, spacing: spacing)
    }

    /// Best available image for one tile of `grid`. When the tile hasn't been
    /// sampled yet it is queued and the coarser frame covering the same moment
    /// stands in, so the strip never shows holes.
    func image(in grid: Grid, tileIndex: Int, sourceKey: String = RecordingTimelineThumbnailStore.primarySourceKey) -> NSImage? {
        guard let duration = sources[sourceKey]?.duration, duration > 0, grid.spacing > 0 else { return nil }
        let center = (Double(tileIndex) + 0.5) * grid.spacing
        let index = index(forSourceTime: center, level: grid.level, duration: duration)
        let key = Key(sourceKey: sourceKey, level: grid.level, index: index)
        if let image = images[key] {
            return image
        }
        // Chasing every intermediate scale of a pinch would queue a screenful
        // of tiles per frame, none of which survive long enough to be drawn.
        if frozenLevels[sourceKey] == nil {
            enqueue(key)
        }

        var fallbackLevel = grid.level - 1
        var fallbackIndex = index / 2
        while fallbackLevel >= 0 {
            if let image = images[Key(sourceKey: sourceKey, level: fallbackLevel, index: fallbackIndex)] {
                return image
            }
            fallbackLevel -= 1
            fallbackIndex /= 2
        }
        return nil
    }

    /// Holds the tile grid still while a zoom gesture is in flight, then
    /// resamples once it settles. Without this the strip re-tiles on every
    /// gesture frame and thrashes the decoder for frames nobody sees.
    func deferSampling(for interval: TimeInterval = 0.22) {
        for (sourceKey, level) in settledLevels where frozenLevels[sourceKey] == nil {
            frozenLevels[sourceKey] = level
        }
        thawTask?.cancel()
        thawTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            self.thawTask = nil
            guard !self.frozenLevels.isEmpty else { return }
            self.frozenLevels.removeAll()
            // Redraw at the settled scale, which is what queues the tiles the
            // lane now actually needs.
            self.onChange?()
        }
    }

    // MARK: - Levels

    private func baseSpacing(forDuration duration: TimeInterval) -> TimeInterval {
        duration > 0 ? duration / Double(Self.baseTileCount) : 0
    }

    private func maxLevel(forDuration duration: TimeInterval) -> Int {
        let base = baseSpacing(forDuration: duration)
        guard base > Self.finestSpacing else { return 0 }
        return max(0, Int(log2(base / Self.finestSpacing).rounded(.down)))
    }

    private func spacing(forLevel level: Int, duration: TimeInterval) -> TimeInterval {
        baseSpacing(forDuration: duration) / pow(2, Double(level))
    }

    /// Coarsest level whose tiles are still wide enough to hold a thumbnail -
    /// its spacing lands in `[targetSpan, 2 * targetSpan)`. Tiles are one level
    /// tile each, so every tile is a distinct frame without oversampling.
    private func level(forSpacing targetSpan: TimeInterval, duration: TimeInterval) -> Int {
        let base = baseSpacing(forDuration: duration)
        guard base > 0, targetSpan > 0 else { return 0 }
        let steps = log2(base / max(targetSpan, Self.finestSpacing))
        return min(max(Int(steps.rounded(.down)), 0), maxLevel(forDuration: duration))
    }

    private func index(forSourceTime sourceTime: TimeInterval, level: Int, duration: TimeInterval) -> Int {
        let spacing = spacing(forLevel: level, duration: duration)
        guard spacing > 0 else { return 0 }
        let clamped = min(max(sourceTime, 0), max(0, duration - 0.000_1))
        return max(0, Int(clamped / spacing))
    }

    private func request(for key: Key, duration: TimeInterval) -> Request {
        let spacing = spacing(forLevel: key.level, duration: duration)
        let center = (Double(key.index) + 0.5) * spacing
        let attempt = retryCounts[key] ?? 0
        // Initial sampling stays inside the tile so neighboring tiles pick
        // distinct frames; retries widen the tolerance so sparse GOPs still
        // yield a redaction-filtered frame instead of staying grey forever.
        let tolerance: TimeInterval = switch attempt {
        case 0: min(0.25, spacing / 3)
        case 1: max(spacing, 1.0)
        default: .infinity
        }
        return Request(
            key: key,
            sourceTime: min(max(center, 0), max(0, duration - 0.05)),
            tolerance: tolerance
        )
    }

    // MARK: - Sampling

    private func enqueue(_ key: Key, atFront: Bool = false, shouldPump: Bool = true) {
        guard sources[key.sourceKey] != nil,
              images[key] == nil,
              !pending.contains(key),
              (retryCounts[key] ?? 0) <= Self.maxRetries else { return }
        pending.insert(key)
        if atFront {
            queue.insert(key, at: 0)
        } else {
            queue.append(key)
        }
        if queue.count > Self.queueLimit {
            let excess = queue.count - Self.queueLimit
            for stale in queue.prefix(excess) {
                pending.remove(stale)
            }
            queue.removeFirst(excess)
        }
        if shouldPump {
            pump()
        }
    }

    private func pump() {
        guard task == nil else { return }
        // Drop queued items for evicted sources before pulling a batch.
        while let last = queue.last, sources[last.sourceKey] == nil {
            pending.remove(last)
            queue.removeLast()
        }
        guard let targetSourceKey = queue.last?.sourceKey,
              let source = sources[targetSourceKey],
              source.duration > 0 else { return }

        // Pull up to `batchSize` newest requests belonging to `targetSourceKey`
        // so one AVAssetImageGenerator services one file at a time.
        var batch: [Key] = []
        batch.reserveCapacity(Self.batchSize)
        var scanIndex = queue.count - 1
        while scanIndex >= 0, batch.count < Self.batchSize {
            if queue[scanIndex].sourceKey == targetSourceKey {
                batch.append(queue.remove(at: scanIndex))
            }
            scanIndex -= 1
        }
        guard !batch.isEmpty else { return }
        let requests = batch.map { request(for: $0, duration: source.duration) }
        let url = source.url
        let regions = source.redactions
        let batchGeneration = source.generation
        let renderer = renderBatch
        activeBatch = (sourceKey: targetSourceKey, generation: batchGeneration)

        task = Task { [weak self] in
            let renderTask = Task.detached(priority: .userInitiated) {
                await renderer(url, requests, regions)
            }
            let samples = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard let self else { return }
            if self.activeBatch?.sourceKey == targetSourceKey && self.activeBatch?.generation == batchGeneration {
                self.task = nil
                self.activeBatch = nil
            }
            if !Task.isCancelled {
                self.absorb(
                    samples,
                    completedKeys: batch,
                    sourceKey: targetSourceKey,
                    generation: batchGeneration
                )
            }
            // Restart queued work for surviving sources even when this batch
            // was cancelled or discarded.
            if !self.sources.isEmpty {
                self.pump()
            }
        }
    }

    private func absorb(
        _ samples: [Sample],
        completedKeys: [Key],
        sourceKey: String,
        generation: UInt64
    ) {
        // Ignore stale batches from an evicted or superseded source registration
        // without touching the current generation's pending keys or cache.
        guard sources[sourceKey]?.generation == generation else { return }
        // Always retire every completed batch key for this generation so misses
        // never stay wedged in `pending` forever.
        for key in completedKeys {
            pending.remove(key)
        }
        var addedAny = false
        for sample in samples {
            guard sample.key.sourceKey == sourceKey,
                  sources[sourceKey]?.generation == generation else { continue }
            retryCounts.removeValue(forKey: sample.key)
            let cost = Self.byteCost(of: sample.image)
            let hadPrevious = images.updateValue(sample.image, forKey: sample.key) != nil
            if let oldCost = imageBytes.updateValue(cost, forKey: sample.key) {
                cachedBytes = max(0, cachedBytes - oldCost) + cost
            } else {
                cachedBytes += cost
            }
            if !hadPrevious {
                insertionOrder.append(sample.key)
            }
            addedAny = true
        }
        for key in completedKeys where images[key] == nil && sources[sourceKey]?.generation == generation {
            let nextAttempt = (retryCounts[key] ?? 0) + 1
            retryCounts[key] = nextAttempt
            if nextAttempt <= Self.maxRetries {
                enqueue(key, atFront: true, shouldPump: false)
            }
        }
        evictIfNeeded()
        if addedAny {
            onChange?()
        }
    }

    private func evictIfNeeded() {
        func overBudget() -> Bool {
            images.count > Self.cacheLimit || cachedBytes > byteLimit
        }
        guard overBudget() else { return }

        // Pass 1: evict dense detail tiles (level > 0) first so coarse overviews survive.
        var survivors: [Key] = []
        survivors.reserveCapacity(insertionOrder.count)
        for key in insertionOrder {
            if overBudget(), key.level > 0 {
                images.removeValue(forKey: key)
                if let cost = imageBytes.removeValue(forKey: key) {
                    cachedBytes = max(0, cachedBytes - cost)
                }
            } else {
                survivors.append(key)
            }
        }
        insertionOrder = survivors

        // Pass 2: if many imported sources still push level-0 overviews above the
        // shared byte cap, evict oldest level-0 tiles so the cap is never exceeded.
        if overBudget() {
            var remaining: [Key] = []
            remaining.reserveCapacity(insertionOrder.count)
            for key in insertionOrder {
                if overBudget() {
                    images.removeValue(forKey: key)
                    if let cost = imageBytes.removeValue(forKey: key) {
                        cachedBytes = max(0, cachedBytes - cost)
                    }
                } else {
                    remaining.append(key)
                }
            }
            insertionOrder = remaining
        }
    }

    nonisolated private static func render(url: URL, requests: [Request], redactions: [RecordingRedaction]) async -> [Sample] {
        guard !requests.isEmpty, !Task.isCancelled else { return [] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        if !redactions.isEmpty {
            do { generator.videoComposition = try await RecordingRedactionFilter.composition(asset: generator.asset, redactions: redactions) }
            catch { return [] }
        }
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 110)
        let cancellation = ImageGenerationCancellation(generator: generator)

        return await withTaskCancellationHandler {
            var samples: [Sample] = []
            // Ascending times let the decoder walk forward through a GOP instead
            // of seeking backwards for every tile.
            for request in requests.sorted(by: { $0.sourceTime < $1.sourceTime }) {
                if Task.isCancelled { return [] }
                let tolerance = request.tolerance.isFinite
                    ? CMTime(seconds: max(0, request.tolerance), preferredTimescale: 600)
                    : .positiveInfinity
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance
                let time = CMTime(seconds: request.sourceTime, preferredTimescale: 600)
                guard let image = try? await generator.image(at: time).image else { continue }
                guard !Task.isCancelled else { return [] }
                samples.append(Sample(key: request.key, image: NSImage(cgImage: image, size: .zero)))
            }
            return samples
        } onCancel: {
            cancellation.cancel()
        }
    }
}
