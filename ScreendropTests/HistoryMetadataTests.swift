import Foundation
import Testing

@MainActor
struct HistoryMetadataTests {
    private struct Row: Codable, Equatable {
        enum Kind: String, Codable { case image, video }
        var name: String
        var kind: Kind = .image
        var tags: [String] = ["client"]
        var cloudURL = "https://example.invalid/share"
    }

    private func withIndex(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Screendrop-HistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("history.json"))
    }

    @Test func failedUploadCleanupRetriesWithoutLosingLegacyOrUnrelatedFields() throws {
        try withIndex { history in
            let folder = history.deletingLastPathComponent()
            let suite = "UploadRetry-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let date = Date(timeIntervalSinceReferenceDate: 1234)
            let row = ScreenshotHistoryItem(id: UUID(), createdAt: date, updatedAt: date, fileName: "demo.mov",
                pixelWidth: 1, pixelHeight: 1, kind: .video, cloudURL: "https://example.invalid/clip",
                recordingSessionPath: folder.path)
            var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            raw["librarySavedAt"] = 1234
            raw["future"] = "keep me"
            let original = try JSONSerialization.data(withJSONObject: [raw])
            try original.write(to: history)
            let project = folder.appendingPathComponent("project.json")
            try Data("corrupt".utf8).write(to: project)
            var files = MarkedHistory<ScreenshotHistoryItem>(historyURL: history,
                marksURL: folder.appendingPathComponent("library-saved.json"))
            var rows = files.load()
            #expect(throws: (any Error).self) { try files.clearBetaOneUploadMarks(in: &rows, defaults: defaults) }
            #expect(rows.first?.librarySavedAt == date)
            #expect(try Data(contentsOf: history) == original)

            let explicit = ISO8601DateFormatter().string(from: date + 203)
            let fixed = try JSONSerialization.data(withJSONObject: ["librarySavedAt": explicit])
            try fixed.write(to: project)
            try files.clearBetaOneUploadMarks(in: &rows, defaults: defaults)
            #expect(files.load().first?.librarySavedAt == nil)
            #expect(try Data(contentsOf: project) == fixed)
            let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [[String: Any]])
            #expect(rewritten.first?["future"] as? String == "keep me" && rewritten.first?["librarySavedAt"] == nil)
        }
    }

    @Test func betaOneUploadMarksClearOnceBeforeTheLibraryScan() throws {
        try withIndex { history in
            let folder = history.deletingLastPathComponent()
            let marksURL = folder.appendingPathComponent("library-saved.json")
            let ids = ["2E8CC7B6", "2D69D162", "12C68304", "12345678", "12345679"].map {
                UUID(uuidString: $0 + "-0000-0000-0000-000000000000")!
            }
            let base = try #require(ISO8601DateFormatter().date(from: "2026-11-18T05:01:00Z"))
            let marks = [base + 8.564, base + 30.874, base + 203, base, base + 203]
            let updated = [base + 8.572, base + 30.884, base, base, base]
            var source: [ScreenshotHistoryItem] = []
            for i in ids.indices {
                let package = folder.appendingPathComponent(ids[i].uuidString)
                if i < 2 {
                    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                    let project: [String: Any] = ["librarySavedAt": ISO8601DateFormatter().string(from: marks[i]),
                                                  "futureKey": ["unchanged"], "displayName": "Demo"]
                    try JSONSerialization.data(withJSONObject: project).write(to: package.appendingPathComponent("project.json"))
                }
                source.append(ScreenshotHistoryItem(id: ids[i], createdAt: base, updatedAt: updated[i],
                    fileName: "fixture", pixelWidth: 10, pixelHeight: 10, kind: i < 2 ? .video : .image,
                    cloudURL: [0, 1, 4].contains(i) ? "https://example.invalid/test" : nil,
                    recordingSessionPath: i < 2 ? package.path : nil))
            }
            let original = try JSONEncoder().encode(source)
            try original.write(to: history)
            var files = MarkedHistory<ScreenshotHistoryItem>(historyURL: history, marksURL: marksURL)
            try files.marks.write(Dictionary(uniqueKeysWithValues: zip(ids, marks)))
            let suite = "SavedMigrationTest-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var rows = files.load()
            try files.clearBetaOneUploadMarks(in: &rows, defaults: defaults)
            #expect(rows.map(\.librarySavedAt) == [nil, nil, marks[2], marks[3], marks[4]])
            #expect(files.load() == rows)
            #expect(try Data(contentsOf: history) == original)
            for i in 0..<2 {
                let project = folder.appendingPathComponent(ids[i].uuidString).appendingPathComponent("project.json")
                let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
                #expect(object["librarySavedAt"] == nil && object["futureKey"] as? [String] == ["unchanged"])
                #expect(object["displayName"] as? String == "Demo")
            }
            try files.marks.write(Dictionary(uniqueKeysWithValues: zip(ids, marks)))
            rows = files.load()
            try files.clearBetaOneUploadMarks(in: &rows, defaults: defaults)
            #expect(rows.map(\.librarySavedAt) == marks.map(Optional.some))
        }
    }

    @Test func oneUndoRestoresCaptureSelectionAndRecordingProject() throws {
        try withIndex { history in
            let folder = history.deletingLastPathComponent()
            let project = folder.appendingPathComponent("project.json")
            let originalProject = Data(#"{"displayName":"Recording","future":17}"#.utf8)
            try originalProject.write(to: project)
            let existingMtime = try project.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let items = [false, true].enumerated().map { i, recording in
                ScreenshotHistoryItem(id: UUID(), createdAt: date + Double(i), updatedAt: date + Double(i),
                    fileName: "fixture-\(i)", pixelWidth: 8, pixelHeight: 8, kind: recording ? .video : .image,
                    recordingSessionPath: recording ? folder.path : nil)
            }
            try JSONEncoder().encode(items).write(to: history)
            var files = MarkedHistory<ScreenshotHistoryItem>(historyURL: history,
                marksURL: folder.appendingPathComponent("library-saved.json"))
            var rows = files.load()
            let newProject = folder.appendingPathComponent("PreviouslyMissing.json")
            let targets = CaptureSavedTargets(ids: Set(items.map(\.id)), projects: [project, newProject])
            let manager = UndoManager()
            manager.groupsByEvent = false
            let changed = try files.changeSaved(targets, rows: &rows, from: nil, to: date)
            manager.beginUndoGrouping()
            manager.registerMoveToSaved { saved in
                do { _ = try files.changeSaved(changed, rows: &rows, from: saved ? nil : date, to: saved ? date : nil) }
                catch { Issue.record(error) }
            }
            manager.endUndoGrouping()
            #expect(rows.allSatisfy { $0.librarySavedAt == date })
            #expect(manager.undoActionName == "Move to Saved")
            manager.undo()
            #expect(!manager.canUndo && manager.redoActionName == "Move to Saved")
            #expect(!FileManager.default.fileExists(atPath: newProject.path))
            #expect(rows == items && files.load() == items)
            let restored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? NSDictionary)
            #expect(restored == (try JSONSerialization.jsonObject(with: originalProject) as? NSDictionary))
            #expect(try project.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == existingMtime)
            manager.redo()
            #expect(files.load().allSatisfy { $0.librarySavedAt == date })
            let redone = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
            #expect(redone["librarySavedAt"] as? String == ISO8601DateFormatter().string(from: date))
        }
    }

    @Test func oneFutureRowKeepsReadableRowsAndCannotRewriteOriginal() throws {
        try withIndex { url in
            let good = (0..<1000).map { Row(name: "capture-\($0)") }
            var rows = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [[String: Any]])
            rows.insert(["name": "future", "kind": "gif", "tags": ["important"]], at: 500)
            let original = try JSONSerialization.data(withJSONObject: rows)
            try original.write(to: url)
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url) == good)
            #expect(index.isReadOnly && index.unreadableRowIndices == [500])
            #expect(throws: (any Error).self) { try index.save([Row(name: "next-capture")], to: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func scalarAndMalformedRowsStayOnDisk() throws {
        try withIndex { url in
            let original = Data(#"[null,42,{"name":"good","kind":"image","tags":[],"cloudURL":"link"},{"name":false}]"#.utf8)
            try original.write(to: url)
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url).map(\.name) == ["good"])
            #expect(index.unreadableRowIndices == [0, 1, 3])
            #expect(throws: (any Error).self) { try index.save([], to: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test(arguments: ["[", "{}", "null"])
    func unreadableWholeIndexCannotBeOverwritten(_ text: String) throws {
        try withIndex { url in
            let original = Data(text.utf8)
            try original.write(to: url)
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url).isEmpty)
            #expect(index.isReadOnly)
            #expect(throws: (any Error).self) { try index.save([Row(name: "new")], to: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func missingOrFullyReadableIndexCanSaveAndReload() throws {
        try withIndex { url in
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url).isEmpty && !index.isReadOnly)
            let rows = [Row(name: "capture")]
            try index.save(rows, to: url)
            #expect(index.load(from: url) == rows && !index.isReadOnly)
            try index.save([], to: url)
            #expect(index.load(from: url).isEmpty && !index.isReadOnly)
        }
    }

    /// A History row coded as the app's is: the mark is read from a row that still has one, and never written.
    private struct MarkedRow: SavedMarkRow, Equatable {
        var id: UUID
        var name: String
        var librarySavedAt: Date?
        enum CodingKeys: String, CodingKey { case id, name }
        private enum LegacyKeys: String, CodingKey { case librarySavedAt }
        init(id: UUID, name: String) { self.id = id; self.name = name }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            librarySavedAt = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Date.self, forKey: .librarySavedAt)
        }
    }

    private let saved = UUID(), legacy = UUID(), plain = UUID()
    private let savedAt = Date(timeIntervalSinceReferenceDate: 800_000_000), legacyAt = Date(timeIntervalSinceReferenceDate: 800_000_100)

    /// History with three rows, one still carrying its mark from before the marks file, and the files' URLs.
    private func markedFiles(_ body: (URL, URL) throws -> Void) throws {
        try withIndex { url in
            let rows: [[String: Any]] = [["id": saved.uuidString, "name": "saved"],
                                         ["id": legacy.uuidString, "name": "legacy", "librarySavedAt": legacyAt.timeIntervalSinceReferenceDate],
                                         ["id": plain.uuidString, "name": "plain"]]
            try JSONSerialization.data(withJSONObject: rows).write(to: url)
            try body(url, url.deletingLastPathComponent().appendingPathComponent("library-saved.json"))
        }
    }

    private func marks(_ rows: [MarkedRow]) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.librarySavedAt.map { (row.id, $0) } })
    }

    /// An older build rewrites history.json with only the keys it knows. The Saved marks live in their own file, so
    /// they're still there afterwards; a mark a row still carried from before moves into that file.
    @Test func savedMarksOutliveAnOlderBuildRewritingHistory() throws {
        try markedFiles { url, marksURL in
            try Data(#"{"\#(saved.uuidString)":\#(savedAt.timeIntervalSinceReferenceDate)}"#.utf8).write(to: marksURL)
            var files = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            let rows = files.load()
            #expect(marks(rows) == [saved: savedAt, legacy: legacyAt])
            try files.save(rows)
            #expect(!(String(data: try Data(contentsOf: url), encoding: .utf8) ?? "").contains("librarySavedAt"))
            // An older build's encoder: the shape it knows, nothing else.
            try JSONEncoder().encode(rows.map { MarkedRow(id: $0.id, name: $0.name) }).write(to: url)
            var reopened = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            #expect(marks(reopened.load()) == [saved: savedAt, legacy: legacyAt])
        }
    }

    /// Astra M1: one bad value in the marks file took the valid ones with it, and the next save replaced the file.
    /// Now the valid ones are read, the file is left as it is, and the reason is there to show.
    @Test func aPartlyInvalidMarksFileKeepsItsValidMarksAndIsNotReplaced() throws {
        try markedFiles { url, marksURL in
            let original = Data(#"{"\#(saved.uuidString)":\#(savedAt.timeIntervalSinceReferenceDate),"\#(plain.uuidString)":"later"}"#.utf8)
            try original.write(to: marksURL)
            var files = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            let rows = files.load()
            #expect(marks(rows)[saved] == savedAt && marks(rows)[plain] == nil)
            #expect(files.marks.state == .unreadable && files.problem != nil)
            #expect(throws: (any Error).self) { try files.save(rows) }
            #expect(try Data(contentsOf: marksURL) == original)
        }
    }

    /// Astra M1: a marks file that can't be opened read as no marks, and an atomic save replaced it.
    @Test func anUnreadableMarksFileIsNotReplaced() throws {
        try markedFiles { url, marksURL in
            let original = Data(#"{"\#(saved.uuidString)":\#(savedAt.timeIntervalSinceReferenceDate)}"#.utf8)
            try original.write(to: marksURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marksURL.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marksURL.path) }
            var files = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            let rows = files.load()
            #expect(files.marks.state == .unreadable && files.problem != nil)
            #expect(throws: (any Error).self) { try files.save(rows) }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marksURL.path)
            #expect(try Data(contentsOf: marksURL) == original)
        }
    }

    /// Astra M2: a migration whose marks file couldn't be written was followed by a History save that dropped the legacy
    /// mark, so it was in neither file. Now History isn't rewritten until the marks file durably holds the mark.
    @Test func aFailedMigrationKeepsTheMarkInHistory() throws {
        try markedFiles { url, marksURL in
            // Something in the way of the marks file, as in Astra's fault injection.
            try FileManager.default.createDirectory(at: marksURL, withIntermediateDirectories: false)
            var files = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            let rows = files.load()
            #expect(marks(rows)[legacy] == legacyAt && files.historyHoldsMarks && files.problem != nil)
            let history = try Data(contentsOf: url)
            #expect(throws: (any Error).self) { try files.save(rows) }
            #expect(try Data(contentsOf: url) == history)
            try FileManager.default.removeItem(at: marksURL)
            var reopened = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            #expect(marks(reopened.load())[legacy] == legacyAt)
            #expect(!reopened.historyHoldsMarks)
            var file = SavedMarksFile(url: marksURL)
            #expect(file.load()[legacy] == legacyAt)
        }
    }

    /// A mark that couldn't be written is reported to the caller rather than shown as kept. History, which holds no
    /// marks of its own any more, is still saved, so new captures aren't held up.
    @Test func aMarkThatCouldntBeWrittenIsReported() throws {
        try withIndex { url in
            let marksURL = url.deletingLastPathComponent().appendingPathComponent("library-saved.json")
            try JSONEncoder().encode([MarkedRow(id: saved, name: "saved"), MarkedRow(id: plain, name: "plain")]).write(to: url)
            var files = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            var rows = files.load()
            #expect(files.marks.state == .missing && !files.historyHoldsMarks)
            try FileManager.default.createDirectory(at: marksURL, withIntermediateDirectories: false)
            rows[0].librarySavedAt = savedAt
            rows.append(MarkedRow(id: UUID(), name: "new capture"))
            #expect(try files.save(rows) == false)
            #expect(files.problem != nil)
            #expect(try JSONDecoder().decode([MarkedRow].self, from: Data(contentsOf: url)).count == 3)
        }
    }

    /// Astra R5: History with one readable legacy-marked row and one it can't read moves nothing: the marks file stays
    /// as it was, or absent, while the readable row still shows its mark.
    @Test func aPartlyReadableHistoryLeavesTheMarksFileAlone() throws {
        try withIndex { url in
            let marksURL = url.deletingLastPathComponent().appendingPathComponent("library-saved.json")
            let rows: [[String: Any]] = [["id": legacy.uuidString, "name": "legacy", "librarySavedAt": legacyAt.timeIntervalSinceReferenceDate],
                                         ["id": plain.uuidString, "name": 42]]
            try JSONSerialization.data(withJSONObject: rows).write(to: url)
            var files = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            #expect(marks(files.load()) == [legacy: legacyAt])
            #expect(files.history.isReadOnly)
            #expect(!FileManager.default.fileExists(atPath: marksURL.path))
            let existing = Data(#"{"\#(saved.uuidString)":\#(savedAt.timeIntervalSinceReferenceDate)}"#.utf8)
            try existing.write(to: marksURL)
            var again = MarkedHistory<MarkedRow>(historyURL: url, marksURL: marksURL)
            #expect(marks(again.load()) == [legacy: legacyAt])
            #expect(try Data(contentsOf: marksURL) == existing)
        }
    }

    @Test func editingAndUploadingDoNotArchiveOnDiskOrAfterRelaunch() throws {
        try withIndex { url in
            let domain = "Sukusho-HistoryTests-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let marks = url.deletingLastPathComponent().appendingPathComponent("library-saved.json")
            var history = MarkedHistory<ScreenshotHistoryItem>(historyURL: url, marksURL: marks)
            var row = ScreenshotHistoryItem(id: UUID(), createdAt: .now, updatedAt: .now, fileName: "sample.png", pixelWidth: 2, pixelHeight: 2)
            _ = history.load()
            func reopen() throws -> ScreenshotHistoryItem {
                let saved = try history.save([row])
                try #require(saved)
                var reopened = MarkedHistory<ScreenshotHistoryItem>(historyURL: url, marksURL: marks)
                let stored = try #require(reopened.load(launchDefaults: defaults).first)
                #expect(stored.librarySavedAt == nil)
                return stored
            }
            row.rename(to: "  Sample  ")
            #expect(try reopen().displayName == "Sample")
            row.setTag("Delete later", applied: true)
            #expect(try reopen().tags == ["Delete later"])
            row.setLibraryCloudURL("https://example.invalid/first")
            #expect(try reopen().cloudURL == "https://example.invalid/first")
            row.recordCloudUpload(url: "https://example.invalid/next", redactions: [])
            let uploaded = try reopen()
            #expect(uploaded.cloudURL == "https://example.invalid/next" && uploaded.cloudRedactions == [])
            #expect(defaults.bool(forKey: "libraryRetroSave.v1"))

            let project = url.deletingLastPathComponent().appendingPathComponent("project.json")
            var recording = RecordingProjectMetadata()
            recording.rename(to: "Recording")
            try JSONEncoder().encode(recording).write(to: project)
            let stored = try JSONDecoder().decode(RecordingProjectMetadata.self, from: Data(contentsOf: project))
            #expect(stored.displayName == "Recording" && stored.librarySavedAt == nil)
        }
    }

    @Test func onlyMarkedCapturesAppearInSaved() {
        for mark in [false, true] {
            #expect(LibraryArchive.includes(isSaved: mark, inSavedPage: true) == mark)
            #expect(LibraryArchive.includes(isSaved: mark, inSavedPage: false) != mark)
        }
    }

    @Test func starringANewRecordingDoesNotStampProjectJSONWith1970() throws {
        try withIndex { history in
            let folder = history.deletingLastPathComponent()
            let newProject = folder.appendingPathComponent("new-project.json")
            let now = Date()
            #expect(try RecordingLibraryMark.change(at: newProject, from: nil, to: now))
            let mtime = try #require(newProject.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            #expect(mtime > now.addingTimeInterval(-60), "New project.json received bogus mtime: \(mtime)")
            #expect(mtime.timeIntervalSince1970 > 1_000_000_000)

            // Existing project.json still preserves its original modification time.
            let past = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: newProject.path)
            #expect(try RecordingLibraryMark.change(at: newProject, from: now, to: nil))
            let preserved = try #require(
                URL(fileURLWithPath: newProject.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            )
            #expect(abs(preserved.timeIntervalSince(past)) < 1)
        }
    }

    @Test func captureSessionSnapshotsEncodeDatesAsISO8601AndReadLegacyNumericMetadata() throws {
        struct DatedDoc: Codable, Equatable { var updatedAt: Date }
        let sampleDate = Date(timeIntervalSince1970: 1_800_000_000)
        let encoded = try CaptureSessionSnapshots.encode(DatedDoc(updatedAt: sampleDate))
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        #expect(try isoDecoder.decode(DatedDoc.self, from: encoded) == DatedDoc(updatedAt: sampleDate))

        // Fractional openedAt keeps exact precision so the current session never appears as a previous session,
        // and multiple sessions within the same second preserve chronological order.
        try withIndex { history in
            let store = CaptureSessionSnapshots(directory: history.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true))
            let firstOpenedAt = Date(timeIntervalSince1970: 1_800_000_123.375)
            let kept = try store.keep(document: encoded, openedAt: firstOpenedAt)
            let first = try #require(kept.first)
            #expect(first.openedAt == firstOpenedAt)
            #expect(kept.filter { $0.openedAt != firstOpenedAt }.isEmpty)
            let restored = try store.read(first)
            #expect(restored.document == encoded)

            let secondOpenedAt = Date(timeIntervalSince1970: 1_800_000_123.825)
            let secondDoc = try CaptureSessionSnapshots.encode(DatedDoc(updatedAt: Date(timeIntervalSince1970: 1_800_000_050)))
            let both = try store.keep(document: secondDoc, openedAt: secondOpenedAt)
            #expect(both.map(\.openedAt) == [secondOpenedAt, firstOpenedAt])
            #expect(both.filter { $0.openedAt != secondOpenedAt }.map(\.openedAt) == [firstOpenedAt])

            // Both numeric-date and ISO-8601 session.json files remain readable.
            let legacyID = UUID()
            let legacyFolder = store.directory.appendingPathComponent(legacyID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
            let legacyEntry = CaptureSessionSnapshot(id: legacyID, openedAt: Date(timeIntervalSince1970: 1_799_000_000), fingerprint: "abc", baseExtension: nil)
            try CaptureSessionSnapshots.encode(legacyEntry).write(to: legacyFolder.appendingPathComponent("session.json"))
            try encoded.write(to: legacyFolder.appendingPathComponent("document.json"))
            let entries = try store.entries()
            let loadedLegacy = try #require(entries.first { $0.id == legacyID })
            #expect(try store.read(loadedLegacy).document == encoded)
        }
    }
}
