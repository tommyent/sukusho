@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The app's own Core Spotlight index. It lives on this Mac, per bundle ID,
/// so a Dev build's captures never mix with the installed app's.
nonisolated struct CoreSpotlightCaptureBackend: CaptureSpotlightBackend {
    /// One instance for the app's life: it holds the delegate the system
    /// asks to index again.
    nonisolated(unsafe) static let index = CSSearchableIndex(name: "Captures")
    static let domain = "captures"

    /// Ties an entry to its App Intents entity, where the app has one.
    var associate: @Sendable (CSSearchableItemAttributeSet, CaptureSpotlightRecord) -> Void = { _, _ in }

    func index(_ records: [CaptureSpotlightRecord], thumbnails: [String: Data]) async throws {
        try await Self.index.indexSearchableItems(records.map { record in
            let attributes = Self.attributes(for: record, thumbnail: thumbnails[record.id])
            associate(attributes, record)
            return CSSearchableItem(uniqueIdentifier: record.id, domainIdentifier: Self.domain, attributeSet: attributes)
        })
    }

    func delete(ids: [String]) async throws {
        try await Self.index.deleteSearchableItems(withIdentifiers: ids)
    }

    func deleteAll() async throws {
        try await Self.index.deleteAllSearchableItems()
    }

    static func attributes(for record: CaptureSpotlightRecord, thumbnail: Data?) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: record.isVideo ? .movie : .image)
        attributes.title = record.title
        attributes.displayName = record.title
        attributes.alternateNames = record.windowTitle.map { [$0] }
        attributes.kind = record.kind
        attributes.keywords = record.keywords
        attributes.creator = record.appName
        attributes.contentDescription = record.summary
        attributes.textContent = record.text
        attributes.contentCreationDate = record.createdAt
        attributes.contentModificationDate = record.modifiedAt
        attributes.duration = record.duration.map { NSNumber(value: $0) }
        if record.pixelWidth > 0, record.pixelHeight > 0 {
            attributes.pixelWidth = NSNumber(value: record.pixelWidth)
            attributes.pixelHeight = NSNumber(value: record.pixelHeight)
        }
        attributes.thumbnailData = thumbnail
        return attributes
    }
}
