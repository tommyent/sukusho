import AppIntents
@preconcurrency import CoreSpotlight
import Foundation
import ImageIO

/// Puts the Library's captures in Spotlight, and opens the one picked there.
/// `CaptureLibraryIndex` hands over every scan and every newly read capture;
/// nothing is indexed until the app starts it, so checks that compile the
/// app's sources never reach the system index.
@MainActor
final class CaptureLibrarySpotlight: NSObject, CSSearchableIndexDelegate {
    static let shared = CaptureLibrarySpotlight()

    private let indexer = CaptureSpotlightIndexer(
        backend: CoreSpotlightCaptureBackend(associate: { attributes, record in
            attributes.associateAppEntity(CaptureEntity(record))
        }),
        stateURL: ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Spotlight Index.json"),
        thumbnail: { record in await CaptureLibrarySpotlight.thumbnail(for: record.id) })
    private var started = false
    private var items: [String: CaptureLibraryItem] = [:]
    private var latest: (records: [CaptureSpotlightRecord], isComplete: Bool)?

    func start() {
        started = true
        CoreSpotlightCaptureBackend.index.indexDelegate = self
        if let latest { sync(latest.records, isComplete: latest.isComplete) }
    }

    /// `insight` gives the model's output for a capture while it may show.
    /// shortcut: every record and its signature is rebuilt on the main actor at each scan and each capture read
    /// (measured 12 ms for 500 captures, 62 ms for 5,000); move it off the main actor if Libraries grow past that.
    func sync(_ items: [CaptureLibraryItem], entries: [String: CaptureTextEntry], insight: (String) -> CaptureInsight?, isComplete: Bool) {
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sync(items.map { CaptureSpotlightRecord($0, entry: entries[$0.id], insight: insight($0.id)) }, isComplete: isComplete)
    }

    func settingsDidChange() {
        if let latest { sync(latest.records, isComplete: latest.isComplete) }
    }

    private func sync(_ records: [CaptureSpotlightRecord], isComplete: Bool) {
        latest = (records, isComplete)
        guard started else { return }
        indexer.sync(records, isComplete: isComplete, isEnabled: ScreendropPreferences.libraryShowsInSpotlight)
    }

    /// Every capture, newest first, for Shortcuts: waits for the first scan
    /// when Shortcuts started the app, and gives up after five seconds.
    func records() async -> [CaptureSpotlightRecord] {
        for _ in 0..<100 where latest == nil { try? await Task.sleep(for: .milliseconds(50)) }
        return (latest?.records ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    /// A small JPEG of the Library's own thumbnail; nil once the capture is gone.
    private static func thumbnail(for id: String) async -> Data? {
        guard let item = shared.items[id],
              let image = await CaptureLibraryThumbnails.shared.image(for: item, maxPixelSize: 320) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: The system asks for the index again

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex,
                                     reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        reindex(nil, then: acknowledgementHandler)
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String],
                                     acknowledgementHandler: @escaping () -> Void) {
        reindex(identifiers, then: acknowledgementHandler)
    }

    nonisolated private func reindex(_ ids: [String]?, then acknowledge: @escaping () -> Void) {
        nonisolated(unsafe) let acknowledge = acknowledge
        Task { @MainActor in
            indexer.forget(ids: ids)
            if let latest { sync(latest.records, isComplete: latest.isComplete) }
            await indexer.settled()
            acknowledge()
        }
    }

    // MARK: Opening a result

    /// A capture picked in Spotlight arrives as a search-result activity
    /// when the system doesn't run `OpenCaptureIntent` for it.
    func open(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        CaptureLibraryModel.shared.reveal(id)
        return true
    }
}

extension CaptureSpotlightRecord {
    init(_ item: CaptureLibraryItem, entry: CaptureTextEntry?, insight: CaptureInsight?) {
        self.init(id: item.id,
                  title: CaptureInsightRules.title(customName: item.customName, modelTitle: insight?.title, dateTitle: item.dateTitle),
                  isVideo: item.isVideo, createdAt: item.createdAt, modifiedAt: item.modifiedAt, tags: item.tags,
                  source: item.source, entry: entry, insight: insight, duration: item.duration,
                  pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, contentKey: item.thumbnailKey)
    }
}
