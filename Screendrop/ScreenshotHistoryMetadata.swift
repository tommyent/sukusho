import Foundation

/// Keep an index this build cannot fully read intact, even when later mutations try to save it.
struct ScreenshotHistoryMetadata<Row: Codable> {
    private(set) var isReadOnly = true
    private(set) var unreadableRowIndices: [Int] = []

    mutating func load(from url: URL) -> [Row] {
        isReadOnly = true
        unreadableRowIndices = []
        do {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                    isReadOnly = false
                    return []
                }
                throw error
            }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var items: [Row] = []
            for (index, row) in rows.enumerated() {
                do {
                    let rowData = try JSONSerialization.data(withJSONObject: row, options: .fragmentsAllowed)
                    items.append(try JSONDecoder().decode(Row.self, from: rowData))
                } catch {
                    unreadableRowIndices.append(index)
                    NSLog("[Screendrop] Could not read history row %d; keeping the original index read-only: %@", index, error.localizedDescription)
                }
            }
            isReadOnly = !unreadableRowIndices.isEmpty
            return items
        } catch {
            NSLog("[Screendrop] Could not read history; keeping the original index read-only: %@", error.localizedDescription)
            return []
        }
    }

    func save(_ items: [Row], to url: URL) throws {
        guard !isReadOnly else {
            throw NSError(domain: "Screendrop.History", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The Library index could not be fully read. The original history.json has been preserved; use a compatible Sukusho build before saving Library changes."
            ])
        }
        let data = try JSONEncoder().encode(items)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Saved (★) marks for History rows, in their own file beside history.json and keyed by capture ID. Builds from before
/// Saved rewrite history.json with only the keys they know, which dropped a `librarySavedAt` kept in the rows (VM,
/// 2026-11-16); this file is one they never open.
nonisolated enum CaptureSavedMarks {
    /// Nil when there's no file, or it can't be read.
    static func load(from url: URL) -> [UUID: Date]? {
        guard let data = try? Data(contentsOf: url), let raw = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return nil
        }
        return Dictionary(raw.compactMap { key, date in UUID(uuidString: key).map { ($0, date) } }, uniquingKeysWith: max)
    }

    static func save(_ marks: [UUID: Date], to url: URL) throws {
        let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: marks.map { ($0.key.uuidString, $0.value) }))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The History rows that belong to a recording's package, whichever way their paths are written.
    static func rows(ofRecordingAt path: String, in rows: [(id: UUID, sessionPath: String?)]) -> Set<UUID> {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return Set(rows.filter { $0.sessionPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == target }.map(\.id))
    }

    /// The file's marks, plus any a row still carries from when they lived in history.json and the file doesn't have.
    static func merged(file: [UUID: Date]?, rows: [(id: UUID, savedAt: Date?)]) -> [UUID: Date] {
        var marks = file ?? [:]
        for row in rows { if let date = row.savedAt, marks[row.id] == nil { marks[row.id] = date } }
        return marks
    }
}
