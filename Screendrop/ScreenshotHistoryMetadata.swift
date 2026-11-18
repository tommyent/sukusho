import Darwin
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
    /// The file's marks, plus any a row still carries from when they lived in history.json and the file doesn't have.
    static func merged(file: [UUID: Date]?, rows: [(id: UUID, savedAt: Date?)]) -> [UUID: Date] {
        var marks = file ?? [:]
        for row in rows { if let date = row.savedAt, marks[row.id] == nil { marks[row.id] = date } }
        return marks
    }
}

/// A row that can carry a Saved mark: History's, read from the row only when it predates the marks file.
nonisolated protocol SavedMarkRow: Codable {
    var id: UUID { get }
    var librarySavedAt: Date? { get set }
}

/// library-saved.json. A file that can't be fully read is never replaced: like History's read-only guard, it keeps
/// marks this build couldn't read, and says why (Astra M1).
nonisolated struct SavedMarksFile {
    enum State: Equatable { case missing, loaded, unreadable }

    let url: URL
    private(set) var state = State.missing
    /// Why the file is unreadable, for the Library to show.
    private(set) var problem: String?

    init(url: URL) { self.url = url }

    /// The marks that could be read, entry by entry, so one bad value doesn't take the others with it.
    mutating func load() -> [UUID: Date] {
        problem = nil
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                state = .missing
                return [:]
            }
            return unreadable("it couldn't be opened (\(error.localizedDescription))")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return unreadable("it isn't a list of marks")
        }
        var marks: [UUID: Date] = [:]
        for (key, value) in object {
            // A date is a number of seconds, as JSONEncoder writes it; true and false aren't.
            guard let id = UUID(uuidString: key), let seconds = value as? NSNumber,
                  CFGetTypeID(seconds) != CFBooleanGetTypeID() else { continue }
            marks[id] = Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }
        guard marks.count == object.count else {
            _ = unreadable("\(object.count - marks.count) of its \(object.count) entries couldn't be read")
            return marks
        }
        state = .loaded
        return marks
    }

    private mutating func unreadable(_ reason: String) -> [UUID: Date] {
        state = .unreadable
        problem = "Saved marks in \(url.lastPathComponent) can't be fully read: \(reason). Saved is read-only until it's fixed."
        return [:]
    }

    /// Throws, and leaves the file as it is, while it's unreadable.
    mutating func write(_ marks: [UUID: Date]) throws {
        guard state != .unreadable else {
            throw NSError(domain: "Sukusho.SavedMarks", code: 1, userInfo: [NSLocalizedDescriptionKey: problem ?? "Saved marks can't be read."])
        }
        let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: marks.map { ($0.key.uuidString, $0.value) }))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        state = .loaded
    }
}

/// Change only the Saved field. Other Studio metadata, including keys from newer builds, stays in the project.
enum RecordingLibraryMark {
    @discardableResult
    static func change(at url: URL, from expected: Date?, to newDate: Date?) throws -> Bool {
        var project: [String: Any]
        var original: stat?
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            project = object
            var attributes = stat()
            guard stat(url.path, &attributes) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            original = attributes
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard newDate != nil else { return false }
            project = [:]
        }
        let formatter = ISO8601DateFormatter()
        // Studio writes whole seconds. An explicitly different project mark belongs to another save.
        if let value = project["librarySavedAt"] {
            guard let stamp = value as? String else { throw CocoaError(.fileReadCorruptFile) }
            guard let expected, stamp == formatter.string(from: expected) else { return false }
        } else if expected != nil { return false }
        project["librarySavedAt"] = newDate.map { formatter.string(from: $0) }
        let data = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        // Modified order includes project.json. Saving a card isn't a content edit.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if original != nil { try FileManager.default.copyItem(at: url, to: temporary) }
        try data.write(to: temporary)
        let times = [original?.st_atimespec ?? timespec(), original?.st_mtimespec ?? timespec()]
        guard utimensat(AT_FDCWD, temporary.path, times, 0) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if original != nil {
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        return true
    }
}

/// History and its Saved marks, read and written together.
struct MarkedHistory<Row: SavedMarkRow> {
    let historyURL: URL
    var history = ScreenshotHistoryMetadata<Row>()
    var marks: SavedMarksFile

    init(historyURL: URL, marksURL: URL) {
        self.historyURL = historyURL
        marks = SavedMarksFile(url: marksURL)
    }

    /// History still holds marks from before the marks file that the file hasn't durably taken yet. Until it has,
    /// History isn't rewritten, since that drops them (Astra M2).
    private(set) var historyHoldsMarks = false
    private var writeProblem: String?

    /// What the Library should show about the files, if anything.
    var problem: String? { marks.problem ?? writeProblem }

    /// The rows with their marks. Marks still in History from before the marks file move into it.
    mutating func load(launchDefaults: UserDefaults? = nil) -> [Row] {
        // Disable beta 1’s automatic marks if it opens this Library after a downgrade.
        launchDefaults?.set(true, forKey: "libraryRetroSave.v1")
        var rows = history.load(from: historyURL)
        let fileMarks = marks.load()
        let merged = CaptureSavedMarks.merged(file: fileMarks, rows: rows.map { ($0.id, $0.librarySavedAt) })
        historyHoldsMarks = rows.contains { $0.librarySavedAt != nil }
        writeProblem = nil
        // A History that couldn't be fully read changes nothing on disk, the marks file included: its unread rows may
        // carry marks the file doesn't, and the move waits for a launch that reads it all (Astra R5). The marks it did
        // read still show.
        if history.isReadOnly {
            for index in rows.indices { rows[index].librarySavedAt = merged[rows[index].id] }
            return rows
        }
        if merged != fileMarks {
            do {
                try marks.write(merged)
                historyHoldsMarks = false
            } catch {
                writeProblem = Self.problem(error)
            }
        } else if marks.state != .unreadable {
            historyHoldsMarks = false
        }
        for index in rows.indices { rows[index].librarySavedAt = merged[rows[index].id] }
        return rows
    }

    /// Writes the marks first, then History. Returns false when History was written but the marks couldn't be, so a
    /// mark just changed isn't kept. Throws, writing nothing, when History couldn't be fully read; and, leaving
    /// History as it is, when the marks couldn't be written while History still holds marks from before.
    @discardableResult
    mutating func save(_ rows: [Row]) throws -> Bool {
        // A History that couldn't be fully read holds rows `rows` doesn't, whose marks must stay: nothing is written.
        guard !history.isReadOnly else {
            try history.save(rows, to: historyURL)
            return false
        }
        var marksKept = true
        do {
            try marks.write(Dictionary(rows.compactMap { row in row.librarySavedAt.map { (row.id, $0) } }, uniquingKeysWith: max))
            historyHoldsMarks = false
            writeProblem = nil
        } catch {
            writeProblem = Self.problem(error)
            if historyHoldsMarks { throw error }
            marksKept = false
        }
        try history.save(rows, to: historyURL)
        return marksKept
    }

    private static func problem(_ error: any Error) -> String {
        "Saved marks couldn't be written (\(error.localizedDescription)). Saved changes aren't kept until that's fixed."
    }
}

extension MarkedHistory where Row == ScreenshotHistoryItem {
    /// Run before the first scan. Keep the sidecar marks until both embedded copies are cleared, so a failed
    /// write can retry on the next launch without losing the IDs it still has to process.
    mutating func clearBetaOneUploadMarks(in rows: inout [Row], defaults: UserDefaults) throws {
        let key = "libraryClearedBetaOneUploadMarks.v1"
        guard !defaults.bool(forKey: key), !history.isReadOnly, marks.state != .unreadable, problem == nil else { return }
        let matching = rows.filter { row in
            guard let mark = row.librarySavedAt, let link = row.cloudURL, !link.isEmpty else { return false }
            return abs(mark.timeIntervalSince(row.updatedAt)) <= 1
        }
        if !matching.isEmpty {
            let ids = Set(matching.map(\.id))
            var sidecar = marks.load()
            guard marks.state == .loaded else { throw CocoaError(.fileReadCorruptFile) }
            for row in matching {
                if row.isVideo, let path = row.recordingSessionPath {
                    let project = URL(fileURLWithPath: path).appendingPathComponent("project.json")
                    try RecordingLibraryMark.change(at: project, from: row.librarySavedAt, to: nil)
                }
                sidecar.removeValue(forKey: row.id)
            }
            // A legacy copy of a mark in history.json would otherwise be imported again on the next open.
            let data = try Data(contentsOf: historyURL)
            guard var raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var changed = false
            for i in raw.indices {
                if let key = raw[i]["id"] as? String, let id = UUID(uuidString: key), ids.contains(id),
                   raw[i].removeValue(forKey: "librarySavedAt") != nil { changed = true }
            }
            if changed { try JSONSerialization.data(withJSONObject: raw).write(to: historyURL, options: .atomic) }
            try marks.write(sidecar)
            for i in rows.indices where ids.contains(rows[i].id) {
                rows[i].librarySavedAt = nil
                NSLog("[Sukusho] Cleared beta 1 upload-only Saved mark %@", rows[i].id.uuidString)
            }
        }
        defaults.set(true, forKey: key)
    }
}
