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

@MainActor
final class RecordingTimelineThumbnailStore {
    /// A tile of the recording: level 0 splits the whole movie into
    /// `baseTileCount` tiles and every level after it halves the spacing, so a
    /// tile at level *n* always sits inside tile `index / 2` of level *n - 1*.
    /// That nesting is what lets a missing dense tile fall back to the coarse
    /// image covering the same moment.
    nonisolated struct Key: Hashable, Sendable {
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

    /// Only cancellation crosses executors. Configuration and image requests
    /// stay on the render task; AVFoundation owns cancellation of pending work.
    nonisolated private struct ImageGenerationCancellation: @unchecked Sendable {
        let generator: AVAssetImageGenerator
        func cancel() { generator.cancelAllCGImageGeneration() }
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

    /// Tiles across the whole recording at the coarsest level - the overview
    /// strip a fitted timeline shows.
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
    /// Roughly a few screenfuls of dense tiles. The coarse level is never
    /// evicted, so the overview survives.
    private static let cacheLimit = 700

    /// Invoked on the main actor when new tiles land, so the AppKit lane can
    /// redraw itself without pushing a SwiftUI update per batch.
    var onChange: (() -> Void)?
    /// Renderer hook (defaults to AVAssetImageGenerator; overridable in tests).
    var renderBatch: @Sendable (URL, [Request], [RecordingRedaction]) async -> [Sample] = RecordingTimelineThumbnailStore.render

    private var url: URL?
    private var redactions: [RecordingRedaction] = []
    private var duration: TimeInterval = 0
    private var images: [Key: NSImage] = [:]
    private var insertionOrder: [Key] = []
    private var pending: Set<Key> = []
    private var retryCounts: [Key: Int] = [:]
    private var queue: [Key] = []
    private var task: Task<Void, Never>?
    private var settledLevel: Int?
    private var frozenLevel: Int?
    private var thawTask: Task<Void, Never>?

    func prepare(url: URL, duration: TimeInterval, redactions: [RecordingRedaction] = []) {
        cancel()
        self.url = url
        self.redactions = redactions
        self.duration = max(0, duration.isFinite ? duration : 0)
        images.removeAll()
        insertionOrder.removeAll()
        pending.removeAll()
        retryCounts.removeAll()
        queue.removeAll()
        settledLevel = nil
        frozenLevel = nil
        onChange?()
        guard self.duration > 0 else { return }
        for index in 0..<Self.baseTileCount {
            enqueue(Key(level: 0, index: index), shouldPump: false)
        }
        pump()
    }

    func cancel() {
        task?.cancel()
        task = nil
        thawTask?.cancel()
        thawTask = nil
        frozenLevel = nil
    }

    func releaseResources() {
        cancel()
        images.removeAll()
        insertionOrder.removeAll()
        pending.removeAll()
        retryCounts.removeAll()
        queue.removeAll()
        url = nil
        duration = 0
        settledLevel = nil
        onChange = nil
    }

    /// Tile grid for tiles that should each cover at least `targetSpan` of
    /// source time - normally "one thumbnail's width of the lane".
    func grid(forTargetSpan targetSpan: TimeInterval) -> Grid {
        guard duration > 0, targetSpan > 0, baseSpacing > 0 else {
            return Grid(level: 0, spacing: max(baseSpacing, 0))
        }
        let level = frozenLevel ?? self.level(forSpacing: targetSpan)
        if frozenLevel == nil {
            settledLevel = level
        }
        // The coarsest level can still be finer than a tile wants at fitted
        // zoom; grouping whole powers of two keeps tiles aligned with the
        // level grid, so zooming subdivides tiles instead of reshuffling them.
        var spacing = spacing(forLevel: level)
        while spacing > 0, spacing < targetSpan {
            spacing *= 2
        }
        return Grid(level: level, spacing: spacing)
    }

    /// Best available image for one tile of `grid`. When the tile hasn't been
    /// sampled yet it is queued and the coarser frame covering the same moment
    /// stands in, so the strip never shows holes.
    func image(in grid: Grid, tileIndex: Int) -> NSImage? {
        guard duration > 0, grid.spacing > 0 else { return nil }
        let center = (Double(tileIndex) + 0.5) * grid.spacing
        let index = index(forSourceTime: center, level: grid.level)
        let key = Key(level: grid.level, index: index)
        if let image = images[key] {
            return image
        }
        // Chasing every intermediate scale of a pinch would queue a screenful
        // of tiles per frame, none of which survive long enough to be drawn.
        if frozenLevel == nil {
            enqueue(key)
        }

        var fallbackLevel = grid.level - 1
        var fallbackIndex = index / 2
        while fallbackLevel >= 0 {
            if let image = images[Key(level: fallbackLevel, index: fallbackIndex)] {
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
        frozenLevel = frozenLevel ?? settledLevel
        thawTask?.cancel()
        thawTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            self.thawTask = nil
            guard self.frozenLevel != nil else { return }
            self.frozenLevel = nil
            // Redraw at the settled scale, which is what queues the tiles the
            // lane now actually needs.
            self.onChange?()
        }
    }

    // MARK: - Levels

    private var baseSpacing: TimeInterval {
        duration > 0 ? duration / Double(Self.baseTileCount) : 0
    }

    private var maxLevel: Int {
        guard baseSpacing > Self.finestSpacing else { return 0 }
        return max(0, Int(log2(baseSpacing / Self.finestSpacing).rounded(.down)))
    }

    private func spacing(forLevel level: Int) -> TimeInterval {
        baseSpacing / pow(2, Double(level))
    }

    /// Coarsest level whose tiles are still wide enough to hold a thumbnail -
    /// its spacing lands in `[targetSpan, 2 * targetSpan)`. Tiles are one level
    /// tile each, so every tile is a distinct frame without oversampling.
    private func level(forSpacing targetSpan: TimeInterval) -> Int {
        guard baseSpacing > 0, targetSpan > 0 else { return 0 }
        let steps = log2(baseSpacing / max(targetSpan, Self.finestSpacing))
        return min(max(Int(steps.rounded(.down)), 0), maxLevel)
    }

    private func index(forSourceTime sourceTime: TimeInterval, level: Int) -> Int {
        let spacing = spacing(forLevel: level)
        guard spacing > 0 else { return 0 }
        let clamped = min(max(sourceTime, 0), max(0, duration - 0.000_1))
        return max(0, Int(clamped / spacing))
    }

    private func request(for key: Key) -> Request {
        let spacing = spacing(forLevel: key.level)
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
        guard images[key] == nil,
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
        guard task == nil, let url, duration > 0, !queue.isEmpty else { return }

        // Newest requests first: they are the tiles under the pointer right
        // now, while anything older has usually been scrolled away from.
        let batch = Array(queue.suffix(Self.batchSize))
        queue.removeLast(batch.count)
        let requests = batch.map { request(for: $0) }
        let regions = redactions
        let renderer = renderBatch

        task = Task { [weak self] in
            let renderTask = Task.detached(priority: .userInitiated) {
                await renderer(url, requests, regions)
            }
            let samples = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.absorb(samples, completedKeys: batch)
            self.pump()
        }
    }

    private func absorb(_ samples: [Sample], completedKeys: [Key]) {
        // Always retire every completed batch key so misses never stay wedged
        // in `pending` forever.
        for key in completedKeys {
            pending.remove(key)
        }
        for sample in samples {
            retryCounts.removeValue(forKey: sample.key)
            guard images.updateValue(sample.image, forKey: sample.key) == nil else { continue }
            insertionOrder.append(sample.key)
        }
        for key in completedKeys where images[key] == nil {
            let nextAttempt = (retryCounts[key] ?? 0) + 1
            retryCounts[key] = nextAttempt
            if nextAttempt <= Self.maxRetries {
                enqueue(key, atFront: true, shouldPump: false)
            }
        }
        evictIfNeeded()
        if !samples.isEmpty {
            onChange?()
        }
    }

    private func evictIfNeeded() {
        guard images.count > Self.cacheLimit else { return }
        var remaining = images.count - Self.cacheLimit
        var survivors: [Key] = []
        survivors.reserveCapacity(insertionOrder.count)
        for key in insertionOrder {
            if remaining > 0, key.level > 0 {
                images.removeValue(forKey: key)
                remaining -= 1
            } else {
                survivors.append(key)
            }
        }
        insertionOrder = survivors
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
