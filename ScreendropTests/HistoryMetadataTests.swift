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

    /// An older build rewrites history.json with only the keys it knows. The Saved marks live in their own file, so
    /// they're still there afterwards; marks a row still carried from before move into that file.
    @Test func savedMarksOutliveAnOlderBuildRewritingHistory() throws {
        try withIndex { url in
            let marksURL = url.deletingLastPathComponent().appendingPathComponent("library-saved.json")
            let saved = UUID(), legacy = UUID(), plain = UUID()
            let savedAt = Date(timeIntervalSinceReferenceDate: 800_000_000), legacyAt = Date(timeIntervalSinceReferenceDate: 800_000_100)
            // A row from this branch before the move still carries its mark in history.json.
            let rows: [[String: Any]] = [["id": saved.uuidString, "name": "saved"],
                                         ["id": legacy.uuidString, "name": "legacy", "librarySavedAt": legacyAt.timeIntervalSinceReferenceDate],
                                         ["id": plain.uuidString, "name": "plain"]]
            try JSONSerialization.data(withJSONObject: rows).write(to: url)
            try CaptureSavedMarks.save([saved: savedAt], to: marksURL)
            struct LegacyRow: Decodable { let id: UUID; let librarySavedAt: Date? }
            let read = try JSONDecoder().decode([LegacyRow].self, from: Data(contentsOf: url))
            var marks = CaptureSavedMarks.merged(file: CaptureSavedMarks.load(from: marksURL), rows: read.map { ($0.id, $0.librarySavedAt) })
            #expect(marks == [saved: savedAt, legacy: legacyAt])
            try CaptureSavedMarks.save(marks, to: marksURL)
            // An older build's encoder: the shape it knows, nothing else.
            struct OldRow: Codable { let id: UUID; let name: String }
            try JSONEncoder().encode([OldRow(id: saved, name: "saved"), OldRow(id: legacy, name: "legacy"),
                                      OldRow(id: plain, name: "plain")]).write(to: url)
            #expect(!(String(data: try Data(contentsOf: url), encoding: .utf8) ?? "").contains("librarySavedAt"))
            let after = try JSONDecoder().decode([LegacyRow].self, from: Data(contentsOf: url))
            marks = CaptureSavedMarks.merged(file: CaptureSavedMarks.load(from: marksURL), rows: after.map { ($0.id, $0.librarySavedAt) })
            #expect(marks == [saved: savedAt, legacy: legacyAt])
        }
    }
}
