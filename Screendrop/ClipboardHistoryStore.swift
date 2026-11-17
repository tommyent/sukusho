import Foundation
import SQLite3

/// A clipboard history entry as stored.
nonisolated struct ClipboardEntry: Sendable, Equatable, Identifiable {
    let id: String
    let kind: ClipboardEntryKind
    let text: String?
    /// A snippet's name.
    let title: String?
    /// The kept image, in the history's Blobs folder.
    let imageURL: URL?
    /// A Sukusho capture's file, when the image stays in the Library.
    let libraryPath: String?
    let byteSize: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceBundleID: String?
    let isRemote: Bool
    let firstCopiedAt: Date
    let lastCopiedAt: Date
    let timesCopied: Int
    let pinnedAt: Date?
}

/// Clipboard history on disk: one SQLite database for entries, and images as
/// files named by their hash. Entries carry a UUID, the Mac they came from and
/// a change number, so sync between Macs can come later without a migration.
actor ClipboardHistoryStore {
    nonisolated enum RecordOutcome: Equatable, Sendable {
        /// `replaced`: the copy was a rewrite of the image copied just before it, which now holds the new bytes.
        case inserted(String), bumped(String), replaced(String)
    }

    /// How long after an image copy a same-size image counts as its rewrite rather than a new copy. Image
    /// optimisers such as Clop put a smaller version back on the clipboard: 0.5 s and 1.1 s after Sukusho's
    /// copies on the owner's Air (2026-11-16), where history kept both. The owner's rule: keep only the rewrite.
    static let rewriteWindow: TimeInterval = 10

    nonisolated struct StoreError: Error, CustomStringConvertible {
        let description: String
    }

    let directory: URL
    private let deviceID: String
    private let db: OpaquePointer
    private var blobs: URL { directory.appendingPathComponent("Blobs", isDirectory: true) }

    init(directory: URL, deviceID: String) throws {
        self.directory = directory
        self.deviceID = deviceID
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Blobs", isDirectory: true),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("clipboard.sqlite").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw StoreError(description: "can't open \(path)")
        }
        db = handle
        try Self.execute(handle, """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                hash TEXT NOT NULL,
                text TEXT,
                title TEXT,
                blob TEXT,
                library_path TEXT,
                byte_size INTEGER NOT NULL DEFAULT 0,
                stored_bytes INTEGER NOT NULL DEFAULT 0,
                pixel_width INTEGER NOT NULL DEFAULT 0,
                pixel_height INTEGER NOT NULL DEFAULT 0,
                source_bundle_id TEXT,
                is_remote INTEGER NOT NULL DEFAULT 0,
                first_copied_at REAL NOT NULL,
                last_copied_at REAL NOT NULL,
                times_copied INTEGER NOT NULL DEFAULT 1,
                pinned_at REAL,
                origin_device TEXT NOT NULL,
                change_seq INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS entries_kind_hash ON entries(kind, hash) WHERE kind != 'snippet';
            CREATE INDEX IF NOT EXISTS entries_last_copied ON entries(last_copied_at);
            CREATE TABLE IF NOT EXISTS rich_text (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (entry_id, type)
            );
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    /// Adds a copy, or moves the same content's entry to the top.
    @discardableResult
    func record(_ capture: ClipboardCapture, at date: Date = .now) throws -> RecordOutcome {
        try transaction {
            let existing = try query("SELECT id FROM entries WHERE kind = ? AND hash = ?",
                                     [capture.kind.rawValue, capture.hash]) { $0.text(0) }.first
            let rewritten = try rewrittenEntry(by: capture, at: date)
            if let id = existing ?? nil {
                // The rewrite of a copy whose rewrite history already holds: the fresh original goes.
                if let rewritten, rewritten.id != id { try delete(ids: [rewritten.id]) }
                try run("UPDATE entries SET last_copied_at = ?, times_copied = times_copied + 1, change_seq = ? WHERE id = ?",
                        [date.timeIntervalSince1970, try nextChange(), id])
                return .bumped(id)
            }
            let blob = try writeBlob(of: capture)
            if let rewritten {
                // The earlier entry keeps its source, first copy time and Library link; the bytes are the rewrite's.
                try run("""
                    UPDATE entries SET hash = ?, blob = ?, byte_size = ?, stored_bytes = ?,
                        library_path = COALESCE(library_path, ?), last_copied_at = ?, change_seq = ? WHERE id = ?
                    """, [capture.hash, blob, capture.byteSize, capture.storedBytes, capture.libraryPath,
                          date.timeIntervalSince1970, try nextChange(), rewritten.id])
                if let old = rewritten.blob, old != blob { try? FileManager.default.removeItem(at: blobs.appendingPathComponent(old)) }
                return .replaced(rewritten.id)
            }
            let id = UUID().uuidString
            try run("""
                INSERT INTO entries (id, kind, hash, text, blob, library_path, byte_size, stored_bytes, pixel_width,
                    pixel_height, source_bundle_id, is_remote, first_copied_at, last_copied_at, origin_device, change_seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [id, capture.kind.rawValue, capture.hash, capture.text, blob, capture.libraryPath, capture.byteSize,
                      capture.storedBytes, capture.pixelWidth, capture.pixelHeight, capture.sourceBundleID,
                      capture.isRemote ? 1 : 0, date.timeIntervalSince1970, date.timeIntervalSince1970, deviceID,
                      try nextChange()])
            for (type, data) in capture.richText {
                try run("INSERT INTO rich_text (entry_id, type, data) VALUES (?, ?, ?)", [id, type, data])
            }
            return .inserted(id)
        }
    }

    /// A saved text snippet. Snippets never expire and are never de-duplicated.
    @discardableResult
    func addSnippet(title: String, text: String, at date: Date = .now) throws -> String {
        let id = UUID().uuidString
        try run("""
            INSERT INTO entries (id, kind, hash, text, title, byte_size, stored_bytes, first_copied_at, last_copied_at,
                origin_device, change_seq)
            VALUES (?, 'snippet', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [id, id, text, title, text.utf8.count, text.utf8.count, date.timeIntervalSince1970,
                  date.timeIntervalSince1970, deviceID, try nextChange()])
        return id
    }

    func updateSnippet(_ id: String, title: String, text: String) throws {
        try run("UPDATE entries SET title = ?, text = ?, byte_size = ?, stored_bytes = ?, change_seq = ? WHERE id = ? AND kind = 'snippet'",
                [title, text, text.utf8.count, text.utf8.count, try nextChange(), id])
    }

    func setPinned(_ id: String, _ pinned: Bool, at date: Date = .now) throws {
        try run("UPDATE entries SET pinned_at = ?, change_seq = ? WHERE id = ?",
                [pinned ? date.timeIntervalSince1970 : nil, try nextChange(), id])
    }

    /// A clip added to the Library: it shows as in the Library and isn't added twice.
    func linkToLibrary(_ id: String, path: String) throws {
        try run("UPDATE entries SET library_path = ?, change_seq = ? WHERE id = ?", [path, try nextChange(), id])
    }

    /// Pasted or copied again from history: to the top, one more copy.
    func touch(_ id: String, at date: Date = .now) throws {
        try run("UPDATE entries SET last_copied_at = ?, times_copied = times_copied + 1, change_seq = ? WHERE id = ?",
                [date.timeIntervalSince1970, try nextChange(), id])
    }

    /// Everything but snippets, and the images kept for it.
    func deleteHistory() throws {
        try delete(ids: try query("SELECT id FROM entries WHERE kind != 'snippet'", []) { $0.text(0) ?? "" })
    }

    func delete(_ id: String) throws {
        try delete(ids: [id])
    }

    /// Drops unpinned copies older than `retention` (nil keeps them), then the
    /// oldest unpinned copies until the total is under `maxBytes`, then copies
    /// whose Sukusho capture is gone. Snippets and pins are never dropped.
    @discardableResult
    func sweep(now: Date = .now, retention: TimeInterval?, maxBytes: Int64) throws -> Int {
        var doomed: [String] = []
        if let retention {
            doomed += try query("SELECT id FROM entries WHERE kind != 'snippet' AND pinned_at IS NULL AND last_copied_at < ?",
                                [now.timeIntervalSince1970 - retention]) { $0.text(0) ?? "" }
        }
        try delete(ids: doomed)
        var total = try totalBytes()
        var evicted: [String] = []
        if total > maxBytes {
            let oldest = try query("""
                SELECT id, stored_bytes FROM entries WHERE kind != 'snippet' AND pinned_at IS NULL ORDER BY last_copied_at
                """, []) { ($0.text(0) ?? "", $0.int(1)) }
            for (id, bytes) in oldest where total > maxBytes {
                evicted.append(id)
                total -= Int64(bytes)
            }
        }
        try delete(ids: evicted)
        // Only references: a clip that was added to the Library keeps its own image.
        let gone = try query("SELECT id, library_path FROM entries WHERE library_path IS NOT NULL AND blob IS NULL", []) {
            ($0.text(0) ?? "", $0.text(1) ?? "")
        }.filter { !FileManager.default.fileExists(atPath: $0.1) }.map(\.0)
        try delete(ids: gone)
        return doomed.count + evicted.count + gone.count
    }

    // MARK: - Reading

    /// Newest first.
    func entries(limit: Int = 500, offset: Int = 0) throws -> [ClipboardEntry] {
        try query("""
            SELECT id, kind, text, title, blob, library_path, byte_size, pixel_width, pixel_height, source_bundle_id,
                is_remote, first_copied_at, last_copied_at, times_copied, pinned_at
            FROM entries ORDER BY last_copied_at DESC LIMIT ? OFFSET ?
            """, [limit, offset]) { row in
            ClipboardEntry(
                id: row.text(0) ?? "",
                kind: ClipboardEntryKind(rawValue: row.text(1) ?? "") ?? .text,
                text: row.text(2),
                title: row.text(3),
                imageURL: row.text(4).map { blobs.appendingPathComponent($0) },
                libraryPath: row.text(5),
                byteSize: row.int(6),
                pixelWidth: row.int(7),
                pixelHeight: row.int(8),
                sourceBundleID: row.text(9),
                isRemote: row.int(10) != 0,
                firstCopiedAt: Date(timeIntervalSince1970: row.double(11)),
                lastCopiedAt: Date(timeIntervalSince1970: row.double(12)),
                timesCopied: row.int(13),
                pinnedAt: row.isNull(14) ? nil : Date(timeIntervalSince1970: row.double(14))
            )
        }
    }

    func richText(for id: String) throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try query("SELECT type, data FROM rich_text WHERE entry_id = ?", [id]) {
            ($0.text(0) ?? "", $0.data(1))
        })
    }

    func totalBytes() throws -> Int64 {
        Int64(try query("SELECT COALESCE(SUM(stored_bytes), 0) FROM entries", []) { $0.int(0) }.first ?? 0)
    }

    // MARK: - SQLite

    /// The entry `capture` rewrites, if any: the latest copy, an unpinned image copied once with the same
    /// pixel size, under `rewriteWindow` ago. Any other copy in between makes it a new copy.
    private func rewrittenEntry(by capture: ClipboardCapture, at date: Date) throws -> (id: String, blob: String?)? {
        guard capture.kind == .image else { return nil }
        let latest = try query("""
            SELECT id, kind, pixel_width, pixel_height, times_copied, pinned_at IS NULL, last_copied_at, blob
            FROM entries WHERE kind != 'snippet' ORDER BY last_copied_at DESC LIMIT 1
            """, []) { row in
            (id: row.text(0) ?? "", kind: row.text(1), width: row.int(2), height: row.int(3), times: row.int(4),
             unpinned: row.int(5) != 0, copiedAt: row.double(6), blob: row.text(7))
        }.first
        guard let latest, latest.kind == ClipboardEntryKind.image.rawValue, latest.unpinned, latest.times == 1,
              latest.width == capture.pixelWidth, latest.height == capture.pixelHeight,
              (0..<Self.rewriteWindow).contains(date.timeIntervalSince1970 - latest.copiedAt) else { return nil }
        return (latest.id, latest.blob)
    }

    /// Writes a copy's image under its hash and returns the name, or nil for a copy without one.
    private func writeBlob(of capture: ClipboardCapture) throws -> String? {
        guard let image = capture.image else { return nil }
        let name = "\(capture.hash.prefix(2))/\(capture.hash).\(capture.imageExtension ?? "img")"
        let url = blobs.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url, options: .atomic)
        return name
    }

    private func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            let blob = try query("SELECT blob FROM entries WHERE id = ?", [id]) { $0.text(0) }.first ?? nil
            try run("DELETE FROM entries WHERE id = ?", [id])
            if let blob { try? FileManager.default.removeItem(at: blobs.appendingPathComponent(blob)) }
        }
    }

    private func nextChange() throws -> Int {
        (try query("SELECT COALESCE(MAX(change_seq), 0) + 1 FROM entries", []) { $0.int(0) }.first) ?? 1
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Self.execute(db, "COMMIT")
            return result
        } catch {
            try? Self.execute(db, "ROLLBACK")
            throw error
        }
    }

    nonisolated private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw StoreError(description: text)
        }
    }

    private func run(_ sql: String, _ values: [Any?]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Any?], _ map: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, transient)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            default: throw StoreError(description: "unsupported value \(String(describing: value))")
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(map(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw StoreError(description: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    nonisolated private struct Row {
        let statement: OpaquePointer
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
