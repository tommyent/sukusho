import CryptoKit
import Foundation
import OSLog

/// What Spotlight holds about one capture: its title, tags, the words read
/// in it, the app it came from, its date and its kind. The index is this
/// Mac's own; nothing here reaches a file name, an upload or a share page.
nonisolated struct CaptureSpotlightRecord: Sendable, Equatable {
    var id: String
    var title: String
    var isVideo: Bool
    var createdAt: Date
    var modifiedAt: Date
    var tags: [String]
    var appName: String?
    var windowTitle: String?
    /// The model's category and keywords, while they may show.
    var modelKeywords: [String]
    /// The words read in it and a recording's captions, a paragraph each.
    var paragraphs: [String]
    var duration: Double?
    var pixelWidth: Int
    var pixelHeight: Int
    /// Changes with the capture's pixels, so its thumbnail is made again.
    var contentKey: String
    /// Changes with the words read in it.
    var textKey: String

    /// `insight` is the model's output only while it may show
    /// (`CaptureInsightRules.visible`): hidden titles aren't searchable.
    init(id: String, title: String, isVideo: Bool, createdAt: Date, modifiedAt: Date, tags: [String] = [],
         source: CaptureSource? = nil, entry: CaptureTextEntry? = nil, insight: CaptureInsight? = nil,
         duration: Double? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0, contentKey: String) {
        self.id = id
        self.title = title
        self.isVideo = isVideo
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tags = tags
        appName = source?.appName
        windowTitle = source?.windowTitle
        modelKeywords = [insight?.category].compactMap { $0 } + (insight?.keywords ?? [])
        paragraphs = entry?.displayParagraphs ?? []
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentKey = contentKey
        textKey = entry.map { "\($0.version):\($0.fingerprint):\($0.transcript?.utf8.count ?? -1)" } ?? ""
    }

    var kind: String { isVideo ? "Recording" : "Screenshot" }

    /// Tags first, then the app and what the model added, each once.
    var keywords: [String] {
        var seen = Set<String>()
        return (tags + [appName].compactMap { $0 } + modelKeywords).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Everything read in it, bounded: a long scrolling capture can hold a book.
    var text: String? {
        paragraphs.isEmpty ? nil : String(paragraphs.joined(separator: "\n").prefix(Self.textLimit))
    }

    /// The line under the title in Spotlight: where it came from, then how it starts.
    var summary: String {
        let from = [kind, appName, windowTitle].compactMap { $0 }.joined(separator: " · ")
        let start = paragraphs.first.map { String($0.prefix(200)) }
        return [from, start].compactMap { $0 }.joined(separator: "\n")
    }

    /// Changes when anything Spotlight shows or matches does. The words are
    /// stood in for by `textKey`, so a pass over the Library hashes no text.
    var signature: String {
        let fields = [id, title, kind, String(createdAt.timeIntervalSince1970), String(modifiedAt.timeIntervalSince1970),
                      tags.joined(separator: "\u{1F}"), appName ?? "", windowTitle ?? "", modelKeywords.joined(separator: "\u{1F}"),
                      String(duration ?? -1), "\(pixelWidth)x\(pixelHeight)", contentKey, textKey]
        return SHA256.hash(data: Data(fields.joined(separator: "\u{1E}").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static let textLimit = 100_000
}

/// What to send to Spotlight and what to take out after a Library scan.
nonisolated enum CaptureSpotlightPlan {
    /// Bump to index every capture again after what's indexed changes.
    static let currentVersion = 1

    /// `indexed` is each capture's signature as Spotlight last got it.
    /// Captures are taken out only after a complete scan (History and the
    /// Recordings folder both read in full). Unlike the text index, an empty
    /// complete scan does empty Spotlight: a deleted capture must not stay
    /// findable, and one taken out wrongly is sent again by the next scan.
    static func changes(_ records: [CaptureSpotlightRecord], indexed: [String: String],
                        isComplete: Bool) -> (index: [CaptureSpotlightRecord], delete: [String]) {
        let live = Set(records.map(\.id))
        return (records.filter { indexed[$0.id] != $0.signature },
                isComplete ? indexed.keys.filter { !live.contains($0) }.sorted() : [])
    }
}

/// What Spotlight was last sent, kept beside the Library so a launch sends
/// only what changed.
nonisolated struct CaptureSpotlightState: Codable, Equatable, Sendable {
    var version = CaptureSpotlightPlan.currentVersion
    var signatures: [String: String] = [:]

    /// Nil when there's none, it can't be read, or it's another version's:
    /// Spotlight is then emptied and filled again.
    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == CaptureSpotlightPlan.currentVersion else { return nil }
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The Spotlight index, as far as keeping it true needs it. Tests use a fake.
nonisolated protocol CaptureSpotlightBackend: Sendable {
    func index(_ records: [CaptureSpotlightRecord], thumbnails: [String: Data]) async throws
    func delete(ids: [String]) async throws
    func deleteAll() async throws
}

/// Keeps Spotlight matching the Library: a new capture goes in, a renamed,
/// retagged or newly read one is sent again, a trashed or deleted one comes
/// out, and switching it off empties it. One pass at a time; a scan that
/// lands meanwhile is applied next, and only the latest one.
@MainActor
final class CaptureSpotlightIndexer {
    private let backend: any CaptureSpotlightBackend
    private let stateURL: URL
    private let thumbnail: @Sendable (CaptureSpotlightRecord) async -> Data?
    private var state: CaptureSpotlightState?
    private var stateLoaded = false
    private var pending: (records: [CaptureSpotlightRecord], isComplete: Bool, isEnabled: Bool)?
    private var runner: Task<Void, Never>?
    /// Counts `forget` calls, so a batch sent before one isn't recorded as current.
    private var generation = 0

    init(backend: any CaptureSpotlightBackend, stateURL: URL,
         thumbnail: @escaping @Sendable (CaptureSpotlightRecord) async -> Data? = { _ in nil }) {
        self.backend = backend
        self.stateURL = stateURL
        self.thumbnail = thumbnail
    }

    func sync(_ records: [CaptureSpotlightRecord], isComplete: Bool, isEnabled: Bool) {
        pending = (records, isComplete, isEnabled)
        if runner == nil { runner = Task { await drain() } }
    }

    /// The system lost these entries (all of them for nil): the next pass
    /// sends them again.
    func forget(ids: [String]?) {
        loadState()
        generation += 1
        guard let ids else { return state = nil }
        for id in ids { state?.signatures[id] = nil }
    }

    /// Returns once every pass asked for so far has finished.
    func settled() async {
        while let runner { await runner.value }
    }

    private func drain() async {
        while let input = pending {
            pending = nil
            do {
                try await apply(input.records, isComplete: input.isComplete, isEnabled: input.isEnabled)
            } catch {
                // What was sent is recorded; the rest goes with the next scan.
                Self.logger.error("Spotlight indexing stopped: \(String(describing: error), privacy: .public)")
            }
        }
        runner = nil
    }

    private func loadState() {
        guard !stateLoaded else { return }
        stateLoaded = true
        state = CaptureSpotlightState.load(from: stateURL)
    }

    private func apply(_ records: [CaptureSpotlightRecord], isComplete: Bool, isEnabled: Bool) async throws {
        loadState()
        guard isEnabled else {
            // Switched off: Spotlight forgets every capture, once.
            guard state?.signatures.isEmpty != true else { return }
            try await backend.deleteAll()
            return save(CaptureSpotlightState())
        }
        if state == nil {
            try await backend.deleteAll()
            save(CaptureSpotlightState())
        }
        let plan = CaptureSpotlightPlan.changes(records, indexed: state?.signatures ?? [:], isComplete: isComplete)
        if !plan.delete.isEmpty {
            try await backend.delete(ids: plan.delete)
            for id in plan.delete { state?.signatures[id] = nil }
            save(state)
        }
        var rest = plan.index[...]
        while !rest.isEmpty, pending?.isEnabled != false {
            let batch = Array(rest.prefix(Self.batchSize))
            rest = rest.dropFirst(Self.batchSize)
            let sentAt = generation
            var thumbnails: [String: Data] = [:]
            for record in batch { thumbnails[record.id] = await thumbnail(record) }
            try await backend.index(batch, thumbnails: thumbnails)
            // Forgotten meanwhile: whoever asked starts the pass that sends it all again.
            guard sentAt == generation, state != nil else { return }
            for record in batch { state?.signatures[record.id] = record.signature }
            save(state)
        }
    }

    private func save(_ new: CaptureSpotlightState?) {
        state = new
        do { try new?.save(to: stateURL) } catch {
            // Costs a full pass at the next launch, nothing more.
            Self.logger.error("Spotlight state not saved: \(String(describing: error), privacy: .public)")
        }
    }

    static let batchSize = 50
    nonisolated private static let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "Spotlight")
}
