import Foundation
import Testing

/// What Spotlight is sent for a capture, and when entries go in, are sent
/// again or come out. Spotlight itself is a fake here.
@MainActor
struct CaptureSpotlightTests {
    private let taken = Date(timeIntervalSince1970: 1_780_000_000)

    private func record(_ id: String = "a", title: String = "Payout settings", isVideo: Bool = false, tags: [String] = [],
                        source: CaptureSource? = nil, entry: CaptureTextEntry? = nil, insight: CaptureInsight? = nil,
                        contentKey: String = "/History/a.png:100.0") -> CaptureSpotlightRecord {
        CaptureSpotlightRecord(id: id, title: title, isVideo: isVideo, createdAt: taken, modifiedAt: taken, tags: tags,
                               source: source, entry: entry, insight: insight, contentKey: contentKey)
    }

    // MARK: What's indexed

    @Test func aCaptureIsIndexedByTitleTagsAppTextAndKind() {
        let entry = CaptureTextEntry(id: "a", fingerprint: "/History/a.png:100.0",
                                     paragraphs: ["Payouts", "Next payout Friday"], transcript: "Here I open the payouts page")
        let insight = CaptureInsight(title: "Payout settings", keywords: ["payouts", "bank"], category: "Finance")
        let capture = record(tags: ["Work", "bank"], source: CaptureSource(bundleIdentifier: "com.apple.Safari", appName: "Safari",
                                                                           windowTitle: "Payouts – Dashboard"),
                             entry: entry, insight: insight)
        #expect(capture.kind == "Screenshot")
        #expect(record(isVideo: true).kind == "Recording")
        // Tags, then the app, then what the model added; "bank" only once.
        #expect(capture.keywords == ["Work", "bank", "Safari", "Finance", "payouts"])
        // The words on screen and a recording's captions are both searchable.
        #expect(capture.text == "Payouts\nNext payout Friday\nHere I open the payouts page")
        #expect(capture.summary == "Screenshot · Safari · Payouts – Dashboard\nPayouts")
        #expect(capture.windowTitle == "Payouts – Dashboard")
    }

    @Test func aCaptureWithNothingReadStillHasItsBasics() {
        let capture = record(title: "Oct 13, 8:13 AM")
        #expect(capture.text == nil)
        #expect(capture.keywords.isEmpty)
        #expect(capture.summary == "Screenshot")
    }

    @Test func veryLongTextIsBounded() {
        let entry = CaptureTextEntry(id: "a", fingerprint: "f", paragraphs: [String(repeating: "word ", count: 40_000)])
        #expect(record(entry: entry).text?.count == CaptureSpotlightRecord.textLimit)
    }

    @Test func theSignatureChangesWithAnythingSpotlightShowsOrMatches() {
        let base = record()
        #expect(base.signature == record().signature)
        #expect(base.signature != record(title: "Q3 payouts").signature)
        #expect(base.signature != record(tags: ["Work"]).signature)
        #expect(base.signature != record(source: CaptureSource(bundleIdentifier: nil, appName: "Safari", windowTitle: nil)).signature)
        // An edit changes the pixels, so the thumbnail is made again.
        #expect(base.signature != record(contentKey: "/History/a.png:250.0").signature)
        // Newly read text, a re-read after an edit, and new captions.
        let read = CaptureTextEntry(id: "a", fingerprint: "/History/a.png:100.0", paragraphs: ["Hello"])
        #expect(base.signature != record(entry: read).signature)
        var reread = read
        reread.fingerprint = "/History/a.png:250.0"
        #expect(record(entry: read).signature != record(entry: reread).signature)
        var captioned = read
        captioned.transcript = "Hello there"
        #expect(record(entry: read).signature != record(entry: captioned).signature)
        // A model title or keywords that arrive later.
        #expect(base.signature != record(insight: CaptureInsight(keywords: ["payouts"])).signature)
    }

    // MARK: The plan

    @Test func onlyNewAndChangedCapturesAreSent() {
        let a = record("a"), b = record("b", title: "Old name")
        let plan = CaptureSpotlightPlan.changes([a, record("b", title: "New name"), record("c")],
                                                indexed: ["a": a.signature, "b": b.signature], isComplete: true)
        #expect(plan.index.map(\.id) == ["b", "c"])
        #expect(plan.delete.isEmpty)
    }

    @Test func goneCapturesComeOutOnlyAfterACompleteScan() {
        let a = record("a")
        let indexed = ["a": a.signature, "gone": "x", "gone2": "y"]
        #expect(CaptureSpotlightPlan.changes([a], indexed: indexed, isComplete: true).delete == ["gone", "gone2"])
        // History or the Recordings folder couldn't be read in full: they may still exist.
        #expect(CaptureSpotlightPlan.changes([a], indexed: indexed, isComplete: false).delete.isEmpty)
        // The last capture deleted: unlike the text index, Spotlight is emptied.
        #expect(CaptureSpotlightPlan.changes([], indexed: indexed, isComplete: true).delete == ["a", "gone", "gone2"])
    }

    // MARK: Keeping Spotlight true

    private func makeIndexer(_ backend: FakeSpotlight, stateURL: URL? = nil) -> (CaptureSpotlightIndexer, URL) {
        let url = stateURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlight-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("Spotlight Index.json")
        return (CaptureSpotlightIndexer(backend: backend, stateURL: url, thumbnail: { Data($0.id.utf8) }), url)
    }

    @Test func aNewCaptureGoesInAndAnUnchangedOneIsntSentAgain() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        indexer.sync([record("a")], isComplete: true, isEnabled: true)
        await indexer.settled()
        // A first run empties whatever an earlier install left, then fills it.
        #expect(await backend.log == ["deleteAll", "index a"])
        #expect(await backend.thumbnails["a"] == Data("a".utf8))
        indexer.sync([record("a"), record("b")], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.log == ["deleteAll", "index a", "index b"])
        #expect(await backend.titles == ["a": "Payout settings", "b": "Payout settings"])
    }

    @Test func aRenameRetagOrNewTextIsSentAgain() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        indexer.sync([record("a")], isComplete: true, isEnabled: true)
        indexer.sync([record("a", title: "Q3 payouts")], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles == ["a": "Q3 payouts"])
        indexer.sync([record("a", title: "Q3 payouts", tags: ["Work"])], isComplete: true, isEnabled: true)
        await indexer.settled()
        indexer.sync([record("a", title: "Q3 payouts", tags: ["Work"],
                             entry: CaptureTextEntry(id: "a", fingerprint: "f", paragraphs: ["Next payout Friday"]))],
                     isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.texts == ["a": "Next payout Friday"])
        #expect(await backend.log.filter { $0 == "index a" }.count >= 3)
    }

    @Test func aTrashedOrDeletedCaptureComesOut() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        indexer.sync([record("a"), record("b")], isComplete: true, isEnabled: true)
        await indexer.settled()
        indexer.sync([record("b")], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.keys.sorted() == ["b"])
        // An incomplete scan takes nothing out.
        indexer.sync([], isComplete: false, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.keys.sorted() == ["b"])
        // The last one deleted.
        indexer.sync([], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.isEmpty)
    }

    @Test func aRelaunchSendsOnlyWhatChanged() async {
        let backend = FakeSpotlight()
        let (first, url) = makeIndexer(backend)
        first.sync([record("a"), record("b")], isComplete: true, isEnabled: true)
        await first.settled()
        let (second, _) = makeIndexer(backend, stateURL: url)
        second.sync([record("a"), record("b", title: "Renamed")], isComplete: true, isEnabled: true)
        await second.settled()
        #expect(await backend.log == ["deleteAll", "index a,b", "index b"])
    }

    @Test func anotherIndexVersionOrAnUnreadableStateRebuildsEverything() async throws {
        let backend = FakeSpotlight()
        let (first, url) = makeIndexer(backend)
        first.sync([record("a")], isComplete: true, isEnabled: true)
        await first.settled()
        var old = try #require(CaptureSpotlightState.load(from: url))
        #expect(old.signatures.keys.sorted() == ["a"])
        old.version = CaptureSpotlightPlan.currentVersion - 1
        try old.save(to: url)
        #expect(CaptureSpotlightState.load(from: url) == nil)
        let (second, _) = makeIndexer(backend, stateURL: url)
        second.sync([record("a")], isComplete: true, isEnabled: true)
        await second.settled()
        #expect(await backend.log == ["deleteAll", "index a", "deleteAll", "index a"])
    }

    @Test func whatTheSystemLostIsSentAgain() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        let records = [record("a"), record("b")]
        indexer.sync(records, isComplete: true, isEnabled: true)
        await indexer.settled()
        // The system asks for some entries again.
        indexer.forget(ids: ["b"])
        indexer.sync(records, isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.log == ["deleteAll", "index a,b", "index b"])
        // The system asks for everything again.
        indexer.forget(ids: nil)
        indexer.sync(records, isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.log == ["deleteAll", "index a,b", "index b", "deleteAll", "index a,b"])
    }

    @Test func switchingItOffEmptiesSpotlightOnceAndOnFillsItAgain() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        indexer.sync([record("a")], isComplete: true, isEnabled: true)
        await indexer.settled()
        indexer.sync([record("a")], isComplete: true, isEnabled: false)
        indexer.sync([record("a"), record("b")], isComplete: true, isEnabled: false)
        await indexer.settled()
        #expect(await backend.titles.isEmpty)
        #expect(await backend.log == ["deleteAll", "index a", "deleteAll"])
        indexer.sync([record("a"), record("b")], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.keys.sorted() == ["a", "b"])
    }

    @Test func offFromTheStartNeverIndexes() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        indexer.sync([record("a")], isComplete: true, isEnabled: false)
        await indexer.settled()
        // Emptied once, in case an earlier install filled it.
        #expect(await backend.log == ["deleteAll"])
    }

    @Test func aFailedSendIsTriedAgainByTheNextScan() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        await backend.failNextIndex()
        indexer.sync([record("a")], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.isEmpty)
        indexer.sync([record("a")], isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.keys.sorted() == ["a"])
    }

    @Test func aLargeLibraryGoesInBatches() async {
        let backend = FakeSpotlight()
        let (indexer, _) = makeIndexer(backend)
        let count = CaptureSpotlightIndexer.batchSize * 2 + 1
        indexer.sync((0..<count).map { record("c\($0)") }, isComplete: true, isEnabled: true)
        await indexer.settled()
        #expect(await backend.titles.count == count)
        #expect(await backend.log.count == 4)
    }

}

private actor FakeSpotlight: CaptureSpotlightBackend {
    private(set) var titles: [String: String] = [:]
    private(set) var texts: [String: String] = [:]
    private(set) var thumbnails: [String: Data] = [:]
    private(set) var log: [String] = []
    private var failing = false

    struct Failure: Error {}

    func failNextIndex() { failing = true }

    func index(_ records: [CaptureSpotlightRecord], thumbnails: [String: Data]) async throws {
        if failing {
            failing = false
            throw Failure()
        }
        log.append("index " + records.map(\.id).joined(separator: ","))
        for record in records {
            titles[record.id] = record.title
            texts[record.id] = record.text
        }
        self.thumbnails.merge(thumbnails) { _, new in new }
    }

    func delete(ids: [String]) async throws {
        log.append("delete " + ids.joined(separator: ","))
        for id in ids {
            titles[id] = nil
            texts[id] = nil
        }
    }

    func deleteAll() async throws {
        log.append("deleteAll")
        titles = [:]
        texts = [:]
    }
}
