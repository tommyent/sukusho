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

    @Test func tallCapturesKeepAReadableShortSide() {
        #expect(CaptureTextIndexPlan.readingSize(width: 3420, height: 2214) == 3420)
        #expect(CaptureTextIndexPlan.readingSize(width: 5120, height: 2880) == 4096)
        #expect(CaptureTextIndexPlan.readingSize(width: 800, height: 600) == 800)
        // The review's 2000 × 30000 scrolling capture reads at 1600 × 24000, not 273 × 4096.
        #expect(CaptureTextIndexPlan.readingSize(width: 2000, height: 30000) == 24000)
        #expect(CaptureTextIndexPlan.readingSize(width: 30000, height: 2000) == 24000)
        #expect(CaptureTextIndexPlan.readingSize(width: 1000, height: 30000) == 30000)
        // Extreme shapes stop at about 40 MP decoded.
        let extreme = Double(CaptureTextIndexPlan.readingSize(width: 1000, height: 100_000))
        #expect(extreme < 100_000 && extreme * extreme / 100 <= 40_000_000 * 1.001)
        #expect(CaptureTextIndexPlan.readingSize(width: 0, height: 0) == 4096)
    }

    @Test func longImagesAreReadInOverlappingTiles() throws {
        // An ordinary screenshot is one tile.
        #expect(CaptureTextTiling.tiles(width: 3420, height: 2214).map(\.rect) == [CGRect(x: 0, y: 0, width: 3420, height: 2214)])
        // A 1000 × 15000 scrolling capture: tiles at most 1500 long whose bands cover it once.
        for (width, height) in [(1000, 15000), (15000, 1000), (1000, 2001)] {
            let tiles = CaptureTextTiling.tiles(width: width, height: height)
            let long = CGFloat(max(width, height))
            #expect(tiles.count > 1)
            #expect(tiles.first?.owned.lowerBound == 0 && tiles.last?.owned.upperBound == long)
            for (tile, next) in zip(tiles, tiles.dropFirst()) {
                #expect(tile.owned.upperBound == next.owned.lowerBound)
            }
            for tile in tiles {
                let along = height >= width ? tile.rect.height : tile.rect.width
                #expect(along <= 1500 && tile.rect.minX >= 0 && tile.rect.minY >= 0)
                #expect(tile.rect.maxX <= CGFloat(width) && tile.rect.maxY <= CGFloat(height))
            }
        }
        // A line in the overlap is read by both tiles and kept once, with its box in the whole image.
        let tiles = CaptureTextTiling.tiles(width: 1000, height: 15000)
        let first = tiles[0], second = tiles[1]
        let overlapY: CGFloat = first.owned.upperBound - 20  // in the first tile's band, inside the second tile too
        func lineAt(_ y: CGFloat, in tile: CaptureTextTiling.Tile) -> CaptureTextLine {
            CaptureTextLine(text: "Glacier hike permit", box: CGRect(x: 0.1, y: (y - 15 - tile.rect.minY) / tile.rect.height,
                                                                       width: 0.5, height: 30 / tile.rect.height))
        }
        let merged = CaptureTextTiling.merge([(first, [lineAt(overlapY, in: first)]), (second, [lineAt(overlapY, in: second)])],
                                             width: 1000, height: 15000)
        let line = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(abs(line.box.midY * 15000 - overlapY) < 0.001 && abs(line.box.height * 15000 - 30) < 0.001)
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

    // MARK: Reading

    @Test func framesThatFailBesideATranscriptStayUnread() throws {
        let transcript = "Welcome to the walkthrough"
        // Vision failed on every frame: not stored, so it's read again later.
        #expect(CaptureTextEntry(id: "r", fingerprint: "r:1", frames: [nil, nil, nil], transcript: transcript) == nil)
        #expect(CaptureTextEntry(id: "r", fingerprint: "r:1", frames: [], transcript: transcript) == nil)
        // One frame read is enough; a blank read is a real answer.
        let partial = try #require(CaptureTextEntry(id: "r", fingerprint: "r:1",
            frames: [nil, [line("Okavango delta itinerary", y: 0.1)], [line("Okavango delta itinerary", y: 0.1)]], transcript: transcript))
        #expect(partial.paragraphs == ["Okavango delta itinerary"] && partial.transcript == transcript)
        let blank = try #require(CaptureTextEntry(id: "s", fingerprint: "s:1", frames: [[]], transcript: ""))
        #expect(blank.paragraphs.isEmpty && blank.transcript == nil)
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

    @Test func aMissingRecordingsFolderIsACompleteEmptyListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryIDs = ["kept", "deleted"]
        // Never recorded: no folder yet, which is a complete listing, so a delete clears its text.
        let missing = root.appendingPathComponent("Recordings", isDirectory: true)
        let listed = try ScreendropStorage.folderContents(at: missing)
        #expect(listed.isEmpty)
        #expect(CaptureTextIndexPlan.removed(entryIDs: entryIDs, liveIDs: ["kept"], isComplete: true) == ["deleted"])
        // There but unreadable: the listing throws and every entry stays.
        let notAFolder = root.appendingPathComponent("Recordings-file")
        try Data().write(to: notAFolder)
        let locked = root.appendingPathComponent("Recordings-locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        for folder in [notAFolder, locked] {
            #expect(throws: (any Error).self) { try ScreendropStorage.folderContents(at: folder) }
            let complete = (try? ScreendropStorage.folderContents(at: folder)) != nil
            #expect(CaptureTextIndexPlan.removed(entryIDs: entryIDs, liveIDs: ["kept"], isComplete: complete).isEmpty)
        }
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

    @Test func proseWithCodeWordsStillFlows() {
        // Keywords mid-sentence, or starting a wrapped line without code after them, are prose.
        let lines = [
            line("Please return the form and let", y: 0.10),
            line("return receipts go to finance before", y: 0.125),
            line("import duties are due.", y: 0.15),
        ]
        #expect(CaptureReadableText.paragraphs(from: lines) == [
            "Please return the form and let return receipts go to finance before import duties are due.",
        ])
        // Brackets and colons in a sentence aren't code either, capitalized or wrapped.
        let punctuated = [
            line("Return the form (signed).", y: 0.10),
            line("Import duties: pay by Friday, and", y: 0.125),
            line("return the form (signed) or", y: 0.15),
            line("import duties: pay at the desk.", y: 0.175),
        ]
        #expect(CaptureReadableText.paragraphs(from: punctuated) == [
            "Return the form (signed). Import duties: pay by Friday, and return the form (signed) or import duties: pay at the desk.",
        ])
        // A definition is still code, and keeps its indented body.
        let python = [
            line("def greet(name):", y: 0.10),
            line("print(name)", x: 0.14, y: 0.125),
            line("return name", x: 0.14, y: 0.15),
        ]
        #expect(CaptureReadableText.paragraphs(from: python) == ["def greet(name):\nprint(name)\nreturn name"])
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
