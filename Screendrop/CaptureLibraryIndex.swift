@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation
import OSLog

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
        let work = Task.detached(priority: .background) {
            await CaptureIntelligence.describe(paragraphs: paragraphs, transcript: transcript, source: source, isVideo: isVideo, image: image)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
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
    /// A cancelled framework call can outlive its deadline. Allow one replacement, without piling up stuck calls.
    @ObservationIgnored private var outstandingInsights = 0
    @ObservationIgnored private var insightDeadline: Task<Void, Never>?
    @ObservationIgnored var insightTimeout: Duration = .seconds(60)
    @ObservationIgnored var retryDelay = CaptureTextIndexPlan.retryDelay
    @ObservationIgnored private var modelCooldown = InsightModelCooldown()
    @ObservationIgnored private var lastModelFailure: [String: Date] = [:]
    /// The earliest retry for each unreadable fingerprint.
    @ObservationIgnored private var unreadable: [String: Date] = [:]
    /// The earliest retry for each insight fingerprint whose preview frame could not be produced.
    @ObservationIgnored private var unavailableInsightFrames: [String: Date] = [:]
    /// Plans again once failed reads may be retried, should nothing else
    /// change in the Library before then.
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var runner: Task<Void, Never>?
    /// The last write to the store queued; each waits for the one before.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private let writeFence = CaptureTextIndexWriteFence()

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
        modelCooldown.reset()
        UserDefaults.standard.set(true, forKey: ScreendropPreferences.libraryInsightsIncludeExistingKey)
        settingsDidChange()
    }

    /// What the model wrote about a capture, while it may show.
    func visibleInsight(_ id: String) -> CaptureInsight? {
        CaptureInsightRules.visible(entries[id]?.insight, enabled: usesIntelligence)
    }

    /// What the model wrote about a recording session, only when the stored entry still matches
    /// the expected redaction state (`redactionTag` when resolving against an in-memory export
    /// document, otherwise the session's current on-disk edit).
    func visibleInsight(for session: RecordingSession, redactionTag: String? = nil) -> CaptureInsight? {
        let id = "recording:" + session.directoryURL.standardizedFileURL.path
        let currentTag = redactionTag ?? CaptureLibraryScanner.redactionTag(for: session)
        guard currentTag != CaptureTextIndexPlan.unreadableRedactionTag else { return nil }
        let expected: String? = currentTag.isEmpty ? nil : currentTag
        guard CaptureTextIndexPlan.redactionTag(in: entries[id]?.fingerprint) == expected else { return nil }
        return visibleInsight(id)
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
        save(entry)
    }

    /// Runs a store write after every write queued before it, so the file
    /// ends as the entry's latest state whatever order detached saves would
    /// finish in. Entries change in memory first, without an await between
    /// reading one and setting it, so no change is written over. A failed
    /// save only costs a re-read or a new model pass at the next launch.
    @discardableResult
    private func write(_ work: @escaping @Sendable (CaptureTextIndexStore) throws -> Void) -> Task<Void, Never> {
        let previous = lastWrite, store = store
        let task = Task.detached(priority: .utility) {
            await previous?.value
            try? work(store)
        }
        lastWrite = task
        return task
    }

    @discardableResult
    private func save(_ entry: CaptureTextEntry) -> Task<Void, Never> {
        let fence = writeFence
        let generation = fence.generation(for: entry.id)
        return write { store in
            try fence.saveIfCurrent(entry, generation: generation, in: store)
        }
    }

    private func matchesCurrentDiskRedactions(_ item: CaptureLibraryItem) -> Bool {
        guard item.isVideo,
              let session = item.session ?? RecordingDeliverable.session(for: item.fileURL) else { return true }
        let currentTag = CaptureLibraryScanner.redactionTag(for: session)
        guard currentTag != CaptureTextIndexPlan.unreadableRedactionTag else { return false }
        let expected: String? = currentTag.isEmpty ? nil : currentTag
        return CaptureTextIndexPlan.redactionTag(in: item.thumbnailKey) == expected
    }

    /// A recording open in Studio can hold edits its files don't have yet, such as a new mask, so its
    /// frames aren't read until the editor closes.
    private func isHeldByEditor(_ item: CaptureLibraryItem) -> Bool {
        guard item.isVideo, let session = item.session ?? RecordingDeliverable.session(for: item.fileURL) else { return false }
        return StudioProjectRegistry.shared.hasLoadedEditor(for: session.directoryURL)
    }

    private func purgeStaleRedaction(for item: CaptureLibraryItem) {
        let hadEntry = entries[item.id] != nil || foldedText[item.id] != nil
        lastModelFailure[item.id] = nil
        entries[item.id] = nil
        foldedText[item.id] = nil
        writeFence.purgeNow(ids: [item.id], in: store)
        if hadEntry {
            CaptureLibraryModel.shared.textIndexDidChange()
            CaptureLibraryModel.shared.insightsDidChange()
        }
        CaptureLibraryModel.shared.refresh()
    }

    /// Forgets captures that are gone and queues every capture whose text is
    /// missing or stale. `isComplete` is false when History or the Recordings
    /// folder couldn't be read in full, so missing captures may still exist.
    func sync(_ items: [CaptureLibraryItem], isComplete: Bool) {
        latestItems = items
        latestIsComplete = isComplete
        guard isLoaded else { return }
        let gone = CaptureTextIndexPlan.removed(entryIDs: entries.keys, liveIDs: Set(items.map(\.id)), isComplete: isComplete)
        let redactionPurged = CaptureTextIndexPlan.redactionInvalidated(
            items.map { .init(id: $0.id, fingerprint: $0.thumbnailKey, createdAt: $0.createdAt) },
            entries: entries
        )
        let removedIDs = Array(Set(gone + redactionPurged))
        if !removedIDs.isEmpty {
            for id in removedIDs {
                lastModelFailure[id] = nil
                entries[id] = nil
                foldedText[id] = nil
            }
            // Atomically bump each removed ID's write generation and unlink from disk under
            // the write fence so no earlier queued save can resurrect purged bytes.
            writeFence.purgeNow(ids: removedIDs, in: store)
            if !redactionPurged.isEmpty {
                CaptureLibraryModel.shared.textIndexDidChange()
                CaptureLibraryModel.shared.insightsDidChange()
            }
        }
        scheduleRetries()
        let held = Set(items.filter(isHeldByEditor).map(\.thumbnailKey))
        planInsights(items, skipping: held)
        guard ScreendropPreferences.libraryReadsText else {
            queue = []
            updatePending()
            return
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = CaptureTextIndexPlan.stale(
            items.filter { $0.id != inFlight?.id }.map { .init(id: $0.id, fingerprint: $0.thumbnailKey, createdAt: $0.createdAt) },
            entries: entries, skipping: Set(unreadable.keys).union(held)
        )
        queue = stale.compactMap { byID[$0.id] }
        updatePending()
        if !queue.isEmpty || canStartInsight, runner == nil { runner = Task { await drain() } }
    }

    /// Queues captures the model hasn't seen, when it may run.
    private func planInsights(_ items: [CaptureLibraryItem], skipping held: Set<String>) {
        let available = modelAvailability(), enabled = ScreendropPreferences.libraryUsesIntelligence
        if available != modelAvailable { modelAvailable = available }
        if enabled != usesIntelligence {
            if enabled { modelCooldown.reset() }
            usesIntelligence = enabled
            CaptureLibraryModel.shared.insightsDidChange()
        }
        var older = 0
        if CaptureInsightRules.runs(modelAvailable: available, enabled: enabled, readsText: ScreendropPreferences.libraryReadsText) {
            let plan = CaptureTextIndexPlan.dueForInsight(
                items.filter { $0.id != describing?.id }.map { .init(id: $0.id, fingerprint: $0.thumbnailKey, createdAt: $0.createdAt) },
                entries: entries, since: ScreendropPreferences.libraryInsightsSince,
                includesExisting: ScreendropPreferences.libraryInsightsIncludeExisting,
                lastFailure: lastModelFailure, skipping: Set(unavailableInsightFrames.keys).union(held))
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            insightQueue = plan.due.compactMap { byID[$0.id] }
            older = plan.older
        } else {
            insightQueue = []
        }
        if older != olderWithoutInsight { olderWithoutInsight = older }
        updatePending()
    }

    private var canStartInsight: Bool {
        modelCooldown.retryAt == nil && describing == nil && outstandingInsights < 2 && !insightQueue.isEmpty
    }

    private func scheduleRetries() {
        let now = Date()
        unreadable = CaptureTextIndexPlan.waiting(retryAt: unreadable, now: now)
        unavailableInsightFrames = CaptureTextIndexPlan.waiting(retryAt: unavailableInsightFrames, now: now)
        modelCooldown.expire(at: now)
        let next = [unreadable.values.min(), unavailableInsightFrames.values.min(), modelCooldown.retryAt].compactMap { $0 }.min()
        guard next != retryAt else { return }
        retry?.cancel()
        retryAt = next
        guard let next else { return }
        retry = Task {
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
            retryAt = nil
            settingsDidChange()
        }
    }

    private func drain() async {
        defer { runner = nil }
        while !Task.isCancelled, !queue.isEmpty || canStartInsight {
            if Self.shouldPause() {
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            // Every capture's text is read before the model sees any.
            guard !queue.isEmpty else {
                startInsight()
                return
            }
            let item = queue.removeFirst()
            // Opened in Studio since it was queued; closing the editor plans it again.
            guard !isHeldByEditor(item) else {
                updatePending()
                continue
            }
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
                unreadable[item.thumbnailKey] = Date().addingTimeInterval(retryDelay)
            case .read(var entry):
                // Fence publication by the current fingerprint so an in-flight OCR read
                // started before a redaction change (or deletion) can never publish stale text.
                let isStillCurrent = latestItems?.contains(where: {
                    $0.id == item.id && $0.thumbnailKey == item.thumbnailKey
                }) == true
                let isUnreadableRedaction = item.isVideo
                    && CaptureTextIndexPlan.redactionTag(in: item.thumbnailKey) == CaptureTextIndexPlan.unreadableRedactionTag
                if isStillCurrent && !isUnreadableRedaction && !isHeldByEditor(item) {
                    if !matchesCurrentDiskRedactions(item) {
                        purgeStaleRedaction(for: item)
                    } else {
                        let previous = entries[item.id]
                        // Routine edits keep the title the user has seen, unless redactions changed
                        // (a prior insight could reflect redacted text or frames).
                        let redactionsChanged = item.isVideo
                            && CaptureTextIndexPlan.redactionTag(in: previous?.fingerprint) != CaptureTextIndexPlan.redactionTag(in: entry.fingerprint)
                        entry.insight = redactionsChanged ? nil : previous?.insight
                        entry.dismissedSuggestions = previous?.dismissedSuggestions
                        entries[item.id] = entry
                        foldedText[item.id] = Self.fold(entry)
                        CaptureLibraryModel.shared.textIndexDidChange()
                        await save(entry).value
                    }
                }
            }
            // Re-plans, so a capture edited while it was read is read again.
            if let latestItems { sync(latestItems, isComplete: latestIsComplete) }
        }
        updatePending()
    }

    private func deferModel(for item: CaptureLibraryItem) {
        let now = Date()
        if entries[item.id]?.isCurrent(fingerprint: item.thumbnailKey) == true { lastModelFailure[item.id] = now }
        modelCooldown.recordFailure(at: now, retryDelay: retryDelay)
    }

    private func startInsight() {
        var nextCandidate: (item: CaptureLibraryItem, entry: CaptureTextEntry)?
        while !insightQueue.isEmpty {
            let candidate = insightQueue.removeFirst()
            guard let candidateEntry = entries[candidate.id], !isHeldByEditor(candidate) else { continue }
            if !matchesCurrentDiskRedactions(candidate) {
                purgeStaleRedaction(for: candidate)
                continue
            }
            nextCandidate = (candidate, candidateEntry)
            break
        }
        guard let (item, entry) = nextCandidate else {
            updatePending()
            return
        }
        describing = item
        outstandingInsights += 1
        updatePending()
        let request = Task(priority: .background) {
            defer {
                outstandingInsights -= 1
                settingsDidChange()
            }
            let image = await Self.image(for: item)
            guard !Task.isCancelled else { return }
            let isStillCurrent = latestItems?.contains(where: {
                $0.id == item.id && $0.thumbnailKey == item.thumbnailKey
            }) == true && entries[item.id]?.isCurrent(fingerprint: item.thumbnailKey) == true
            // The frame is never shown to the model while Studio may hold edits it lacks.
            guard isStillCurrent, !isHeldByEditor(item) else {
                insightDeadline?.cancel()
                insightDeadline = nil
                describing = nil
                return
            }
            if !matchesCurrentDiskRedactions(item) {
                insightDeadline?.cancel()
                insightDeadline = nil
                describing = nil
                purgeStaleRedaction(for: item)
                return
            }
            guard !item.isVideo || image != nil else {
                insightDeadline?.cancel()
                insightDeadline = nil
                describing = nil
                unavailableInsightFrames[item.thumbnailKey] = Date().addingTimeInterval(retryDelay)
                return
            }
            let outcome = Self.shouldPause() ? nil : await describer(item, entry, image)
            // A timed-out answer must never replace a retry's answer or clear its deadline.
            guard !Task.isCancelled else { return }
            insightDeadline?.cancel()
            insightDeadline = nil
            describing = nil
            switch outcome {
            case .later:
                deferModel(for: item)
            case .insight(let insight):
                modelCooldown.reset()
                lastModelFailure[item.id] = nil
                guard latestItems?.contains(where: { $0.id == item.id && $0.thumbnailKey == item.thumbnailKey }) == true,
                      var current = entries[item.id], current.isCurrent(fingerprint: item.thumbnailKey),
                      !isHeldByEditor(item) else { return }
                guard matchesCurrentDiskRedactions(item) else {
                    purgeStaleRedaction(for: item)
                    return
                }
                current.insight = insight
                entries[item.id] = current
                CaptureLibraryModel.shared.insightsDidChange()
                save(current)
            case nil: break
            }
        }
        insightDeadline = Task {
            do { try await Task.sleep(for: insightTimeout) } catch { return }
            request.cancel()
            describing = nil
            deferModel(for: item)
            Self.logger.notice("Library insight timed out; retrying later")
            settingsDidChange()
        }
    }

    private func updatePending() {
        let ids = Set(queue.map(\.id) + (inFlight.map { [$0.id] } ?? []))
        if ids != pendingIDs { pendingIDs = ids }
        let insights = insightQueue.count + (describing == nil ? 0 : 1)
        if insights != insightsPending { insightsPending = insights }
    }

    /// Recording, Low Power Mode and a hot Mac all come before indexing (and the clipboard's descriptions).
    static func shouldPause() -> Bool {
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
        /// Nothing could be read: tried again in a few minutes rather than
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
            let preview: RecordingPreviewSource
            do { preview = try await RecordingPreviewSource(item.fileURL) }
            catch { return .unreadable }
            let asset = AVURLAsset(url: preview.url)
            let generator = AVAssetImageGenerator(asset: asset)
            if !preview.redactions.isEmpty {
                do {
                    generator.videoComposition = try await RecordingRedactionFilter.composition(
                        asset: asset,
                        redactions: preview.redactions
                    )
                } catch {
                    return .unreadable
                }
            }
            generator.appliesPreferredTrackTransform = true
            let size = CaptureTextIndexPlan.readingSize(width: item.pixelWidth, height: item.pixelHeight)
            generator.maximumSize = CGSize(width: size, height: size)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let assetDuration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let duration = assetDuration ?? item.duration ?? 0
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

    /// What the model looks at: the screenshot, or a recording's first frame (redacted).
    nonisolated static func image(for item: CaptureLibraryItem) async -> CGImage? {
        let size = 1280
        guard item.isVideo else { return await decode(item.fileURL, maxSize: size) }
        let preview: RecordingPreviewSource
        do { preview = try await RecordingPreviewSource(item.fileURL) }
        catch { return nil }
        let asset = AVURLAsset(url: preview.url)
        let generator = AVAssetImageGenerator(asset: asset)
        if !preview.redactions.isEmpty {
            do {
                generator.videoComposition = try await RecordingRedactionFilter.composition(
                    asset: asset,
                    redactions: preview.redactions
                )
            } catch {
                return nil
            }
        }
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
                do {
                    continuation.resume(returning: try ImageTextRecognizer.recognizeLines(in: image))
                } catch {
                    Self.logger.error("Text read failed; retrying in a few minutes: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "LibraryIndex")
}
