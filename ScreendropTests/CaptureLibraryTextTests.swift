import CoreGraphics
import Foundation
import Testing

struct CaptureLibraryTextTests {
    private func line(_ text: String, x: CGFloat = 0.1, y: CGFloat, height: CGFloat = 0.02) -> CaptureTextLine {
        CaptureTextLine(text: text, box: CGRect(x: x, y: y, width: 0.3, height: height))
    }

    // MARK: Fingerprints

    @Test func anEditedOrOlderEntryIsStale() {
        let entry = CaptureTextEntry(id: "a", fingerprint: "/History/a.png:100.0", paragraphs: ["Hello"])
        #expect(entry.isCurrent(fingerprint: "/History/a.png:100.0"))
        // An edit changes the modification date; a move changes the path.
        #expect(!entry.isCurrent(fingerprint: "/History/a.png:250.0"))
        #expect(!entry.isCurrent(fingerprint: "/History/b.png:100.0"))
        var old = entry
        old.version = CaptureTextEntry.currentVersion - 1
        #expect(!old.isCurrent(fingerprint: "/History/a.png:100.0"))
    }

    @Test func staleCapturesAreReadNewestFirstAndUnreadableOnesWait() {
        let now = Date()
        let captures: [CaptureTextIndexPlan.Capture] = [
            .init(id: "old", fingerprint: "old:1", createdAt: now.addingTimeInterval(-100)),
            .init(id: "read", fingerprint: "read:1", createdAt: now.addingTimeInterval(-50)),
            .init(id: "edited", fingerprint: "edited:2", createdAt: now.addingTimeInterval(-20)),
            .init(id: "new", fingerprint: "new:1", createdAt: now),
            .init(id: "broken", fingerprint: "broken:1", createdAt: now.addingTimeInterval(10)),
        ]
        let entries = [
            "read": CaptureTextEntry(id: "read", fingerprint: "read:1", paragraphs: []),
            "edited": CaptureTextEntry(id: "edited", fingerprint: "edited:1", paragraphs: ["before"]),
        ]
        let stale = CaptureTextIndexPlan.stale(captures, entries: entries, skipping: ["broken:1"])
        #expect(stale.map(\.id) == ["new", "edited", "old"])
    }

    // MARK: Index rules

    @Test func deletedCapturesLeaveTheIndexButAnEmptyScanKeepsIt() {
        let entryIDs = ["kept", "deleted"]
        #expect(CaptureTextIndexPlan.removed(entryIDs: entryIDs, liveIDs: ["kept", "new"], isComplete: true) == ["deleted"])
        #expect(CaptureTextIndexPlan.removed(entryIDs: entryIDs, liveIDs: [], isComplete: true).isEmpty)
    }

    @Test func aPartialScanKeepsEveryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureTextIndexStore(directory: directory)
        for id in ["recording", "screenshot"] {
            try store.save(CaptureTextEntry(id: id, fingerprint: "\(id):1", paragraphs: ["text"]))
        }
        // history.json failed to read, or a row didn't decode: only the recording was scanned.
        store.remove(ids: CaptureTextIndexPlan.removed(entryIDs: store.loadAll().keys, liveIDs: ["recording"], isComplete: false))
        #expect(store.loadAll().keys.sorted() == ["recording", "screenshot"])
        store.remove(ids: CaptureTextIndexPlan.removed(entryIDs: store.loadAll().keys, liveIDs: ["recording"], isComplete: true))
        #expect(store.loadAll().keys.sorted() == ["recording"])
    }

    @Test func storeSavesLoadsRemovesAndRebuilds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureTextIndexStore(directory: directory)
        let screenshot = CaptureTextEntry(id: UUID().uuidString, fingerprint: "a:1", paragraphs: ["Quarterly invoice"])
        let recording = CaptureTextEntry(id: "recording:/Users/x/Recordings/Demo.sdrecording", fingerprint: "b:1",
                                         paragraphs: [], transcript: "Hello there")
        try store.save(screenshot)
        try store.save(recording)
        // Paths in IDs never become paths on disk.
        #expect(store.url(for: recording.id).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        // A damaged file is skipped and read again, not fatal.
        try Data("{".utf8).write(to: directory.appendingPathComponent("damaged.json"))
        #expect(store.loadAll() == [screenshot.id: screenshot, recording.id: recording])

        var edited = screenshot
        edited.fingerprint = "a:2"
        try store.save(edited)
        #expect(store.loadAll()[screenshot.id] == edited)

        store.remove(ids: [recording.id])
        #expect(store.loadAll().keys.sorted() == [screenshot.id])
        // Deleting the folder loses nothing but time: it rebuilds empty.
        try FileManager.default.removeItem(at: directory)
        #expect(store.loadAll().isEmpty)
        try store.save(recording)
        #expect(store.loadAll() == [recording.id: recording])
    }

    // MARK: Search

    @Test func searchMatchesRecognizedTextIgnoringCaseAndAccents() {
        let entry = CaptureTextEntry(id: "a", fingerprint: "a:1", paragraphs: ["Menu du Café", "TOTAL DUE $42"],
                                     transcript: "Let's open the Résumé")
        let text = CaptureLibraryQuery.fold(entry.displayParagraphs.joined(separator: "\n"))
        #expect(CaptureLibraryQuery("cafe").matches(fields: ["Screenshot.png"], foldedText: text))
        #expect(CaptureLibraryQuery("  total due ").matches(fields: [], foldedText: text))
        #expect(CaptureLibraryQuery("resume").matches(fields: [], foldedText: text))
        #expect(CaptureLibraryQuery("CAFÉ").matches(fields: [], foldedText: text))
        #expect(!CaptureLibraryQuery("receipt").matches(fields: ["Screenshot.png"], foldedText: text))
        // Name, file name and tags still match without any text.
        #expect(CaptureLibraryQuery("travel").matches(fields: ["Oct 13", "Travel"], foldedText: nil))
        #expect(!CaptureLibraryQuery("travel").matches(fields: ["Oct 13"], foldedText: nil))
        #expect(CaptureLibraryQuery("").matches(fields: [], foldedText: nil))
    }

    @Test func matchingParagraphsComeFirst() {
        let paragraphs = ["Sign in", "Invoice 1042", "Footer", "Pay the invoice"]
        #expect(CaptureLibraryQuery("INVOICE").ordered(paragraphs) == ["Invoice 1042", "Pay the invoice", "Sign in", "Footer"])
        #expect(CaptureLibraryQuery("").ordered(paragraphs) == paragraphs)
    }

    // MARK: Paragraphs

    @Test func wrappedProseBecomesOneParagraph() {
        let lines = [
            line("Screenshots are saved as loss-", y: 0.10),
            line("less PNG files first, then", y: 0.125),
            line("compressed on export.", y: 0.15),
            line("Settings", y: 0.30),
        ]
        #expect(CaptureReadableText.paragraphs(from: lines) == [
            "Screenshots are saved as lossless PNG files first, then compressed on export.",
            "Settings",
        ])
    }

    @Test func codeKeepsItsLines() {
        let lines = [
            line("func greet() {", y: 0.10),
            line("print(\"hi\")", x: 0.14, y: 0.125),
            line("return", x: 0.14, y: 0.15),
            line("}", y: 0.175),
            line("Indented prose stays apart", x: 0.14, y: 0.30),
            line("from what it sits under.", x: 0.10, y: 0.325),
        ]
        // Code may indent; a lone brace is a stray fragment.
        #expect(CaptureReadableText.paragraphs(from: lines) == [
            "func greet() {\nprint(\"hi\")\nreturn", "Indented prose stays apart", "from what it sits under.",
        ])
        let longer = [
            line("let total = items.count", y: 0.10),
            line("return total * 2", y: 0.125),
        ]
        #expect(CaptureReadableText.paragraphs(from: longer) == ["let total = items.count\nreturn total * 2"])
    }

    @Test func columnsAndStrayFragmentsStayApart() {
        // Reading order interleaves the two columns row by row.
        let lines = [
            line("Inbox", x: 0.05, y: 0.10),
            line("The quarterly report is", x: 0.4, y: 0.10),
            line("Archive", x: 0.05, y: 0.125),
            line("ready for review.", x: 0.4, y: 0.125),
            line("G", x: 0.9, y: 0.5),
            line("2026-10-23", x: 0.4, y: 0.6),
        ]
        #expect(CaptureReadableText.paragraphs(from: lines) == [
            "Inbox Archive", "The quarterly report is ready for review.", "2026-10-23",
        ])
    }
}
