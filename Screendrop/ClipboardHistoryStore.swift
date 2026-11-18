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
    var imageURL: URL?
    /// The editable capture associated with this clip, if any.
    var libraryPath: String?
    var byteSize: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceBundleID: String?
    let isRemote: Bool
    let firstCopiedAt: Date
    let lastCopiedAt: Date
    let timesCopied: Int
    /// When the copy was saved (★, Library › Saved); stored as pinned_at, the name it had before option A.
    let pinnedAt: Date?
    var isArchived: Bool { kind != .snippet && pinnedAt != nil }
    var canMoveToSaved: Bool { kind != .snippet && pinnedAt == nil }
    /// An image's text, read on this Mac as the Library reads captures'; nil until read.
    var readText: String? = nil
    /// Apple Intelligence's title, keywords and category for an image, as the Library has for captures.
    var modelTitle: String? = nil
    var keywords: [String] = []
    var category: String? = nil
    /// The model answered or declined, so it isn't asked again.
    var isDescribed = false
    /// SHA-256 of the newest version's content.
    var hash = ""
    /// Versions this card held before an optimiser's re-encode stacked a newer one on it, newest first. Each keeps
    /// its own hash, image and Library link (owner, 2026-11-16: two versions on one card, nothing deleted).
    var earlierVersions: [ClipboardEntryVersion] = []
    /// The newest version is Sukusho's own Optimize, not another app's re-encode (Fable 15 #3).
    var isOptimizedHere = false
    var cloudLinks: [String] = []
    var snippetEditedAt: Date? = nil
}

/// An earlier version of an image entry: what was copied before an optimiser put its re-encode back.
nonisolated struct ClipboardEntryVersion: Sendable, Equatable {
    let hash: String
    let imageURL: URL?
    let libraryPath: String?
    let byteSize: Int
    let copiedAt: Date
}

/// Clipboard history on disk: one SQLite database for entries, and images as
/// files named by their hash. Entries carry a UUID, the Mac they came from and
/// a change number, so sync between Macs can come later without a migration.
actor ClipboardHistoryStore {
    nonisolated enum RecordOutcome: Equatable, Sendable {
        /// `stacked`: the copy looked like a re-encode of the image copied just before it, so it became that card's
        /// newest version; the earlier one is kept beside it.
        case inserted(String), bumped(String), stacked(String)
    }

    /// How long after an image copy a re-encode of the same picture stacks on its card rather than making a new one.
    /// Image optimisers such as Clop put a smaller version back on the clipboard: 0.5 s and 1.1 s after Sukusho's
    /// copies on the owner's Air (2026-11-16). The owner's rule: one card, two versions, nothing deleted.
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
                change_seq INTEGER NOT NULL,
                read_text TEXT,
                model_title TEXT,
                model_keywords TEXT,
                model_category TEXT,
                described INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX IF NOT EXISTS entries_kind_hash ON entries(kind, hash) WHERE kind != 'snippet' AND pinned_at IS NULL;
            CREATE INDEX IF NOT EXISTS entries_saved_hash ON entries(kind, hash) WHERE pinned_at IS NOT NULL;
            CREATE INDEX IF NOT EXISTS entries_last_copied ON entries(last_copied_at);
            CREATE TABLE IF NOT EXISTS clip_cloud_links (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                url TEXT NOT NULL,
                PRIMARY KEY(entry_id, position)
            );
            CREATE TABLE IF NOT EXISTS rich_text (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (entry_id, type)
            );
            CREATE TABLE IF NOT EXISTS versions (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                hash TEXT NOT NULL,
                blob TEXT,
                library_path TEXT,
                byte_size INTEGER NOT NULL DEFAULT 0,
                stored_bytes INTEGER NOT NULL DEFAULT 0,
                copied_at REAL NOT NULL,
                PRIMARY KEY (entry_id, hash)
            );
            """)
        // Keep the index name beta 1 checks, so it can reopen an archive containing identical copies.
        var definition: OpaquePointer?
        let lookup = "SELECT 1 FROM sqlite_master WHERE name = 'entries_kind_hash' AND sql NOT LIKE '%pinned_at IS NULL%'"
        guard sqlite3_prepare_v2(handle, lookup, -1, &definition, nil) == SQLITE_OK else {
            throw StoreError(description: String(cString: sqlite3_errmsg(handle)))
        }
        let indexStatus = sqlite3_step(definition)
        sqlite3_finalize(definition)
        if indexStatus == SQLITE_ROW {
            try Self.execute(handle, """
                BEGIN IMMEDIATE;
                DROP INDEX entries_kind_hash;
                CREATE UNIQUE INDEX entries_kind_hash ON entries(kind, hash) WHERE kind != 'snippet' AND pinned_at IS NULL;
                COMMIT;
                """)
        } else if indexStatus != SQLITE_DONE {
            throw StoreError(description: String(cString: sqlite3_errmsg(handle)))
        }
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else {
            throw StoreError(description: String(cString: sqlite3_errmsg(handle)))
        }
        let status = sqlite3_step(version)
        let schemaVersion = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard status == SQLITE_ROW else { throw StoreError(description: String(cString: sqlite3_errmsg(handle))) }
        if schemaVersion == 0 {
            try Self.execute(handle, """
                BEGIN IMMEDIATE;
                UPDATE entries SET pinned_at = NULL WHERE kind = 'snippet' AND pinned_at IS NOT NULL;
                PRAGMA user_version = 1;
                COMMIT;
                """)
        }
        if schemaVersion < 2 {
            try Self.execute(handle, "BEGIN IMMEDIATE")
            do {
                for table in ["entries", "versions"] {
                    let rows = try Self.query(handle, """
                        SELECT rowid, library_path, hash FROM \(table) WHERE library_path IS NOT NULL AND blob IS NULL
                        """, []) { ($0.int(0), $0.text(1)!, $0.text(2)!) }
                    for (row, path, previousHash) in rows {
                        let file = URL(fileURLWithPath: path)
                        let data: Data
                        do { data = try Data(contentsOf: file) }
                        catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                        let hash = ClipboardPasteboardReader.digest(data)
                        let blob = try Self.writeBlob(data, hash: hash,
                                                      ext: file.pathExtension, in: directory)
                        _ = try Self.query(handle, """
                            UPDATE \(table) SET blob = ?, byte_size = ? WHERE rowid = ?
                            """, [blob, data.count, row]) { _ in () }
                        if table == "entries", let size = ClipboardPasteboardReader.pixelSize(of: data) {
                            _ = try Self.query(handle, "UPDATE entries SET pixel_width = ?, pixel_height = ? WHERE rowid = ?",
                                               [size.width, size.height, row]) { _ in () }
                        }
                        if hash != previousHash {
                            // A pre-upgrade edit changed the bytes. A new copy of the old bytes must get its own card.
                            _ = try Self.query(handle, "UPDATE OR IGNORE \(table) SET hash = ? WHERE rowid = ?", [hash, row]) { _ in () }
                            if sqlite3_changes(handle) == 0 {
                                // Another row already indexes these bytes. Keep both histories and one canonical copy target.
                                _ = try Self.query(handle, "UPDATE \(table) SET hash = ? WHERE rowid = ?",
                                                   ["legacy-\(row)-\(hash)", row]) { _ in () }
                            }
                        }
                    }
                }
                try Self.execute(handle, "PRAGMA user_version = 2; COMMIT")
            } catch {
                try? Self.execute(handle, "ROLLBACK")
                throw error
            }
        }
        // Histories from before the image descriptions get their columns; on a newer one each is a duplicate.
        for column in ["read_text TEXT", "model_title TEXT", "model_keywords TEXT", "model_category TEXT",
                       "described INTEGER NOT NULL DEFAULT 0", "optimized_here INTEGER NOT NULL DEFAULT 0", "snippet_edited_at REAL"] {
            try? Self.execute(handle, "ALTER TABLE entries ADD COLUMN \(column)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    /// Adds a copy, or moves the same content's entry to the top.
    @discardableResult
    func record(_ capture: ClipboardCapture, at date: Date = .now) throws -> RecordOutcome {
        try transaction {
            let key = [capture.kind.rawValue, capture.hash]
            let existing = try query("SELECT id, blob FROM entries WHERE kind != 'snippet' AND kind = ? AND hash = ? AND pinned_at IS NULL",
                                     key) { ($0.text(0)!, $0.text(1)) }.first
            if let (id, existingBlob) = existing {
                if existingBlob == nil, let blob = try writeBlob(of: capture) {
                    try run("UPDATE entries SET blob = ?, stored_bytes = ?, byte_size = ? WHERE id = ?",
                            [blob, capture.storedBytes, capture.byteSize, id])
                }
                // Content history already holds: that card goes to the top. A fresh copy it looks like stays as it is.
                try run("""
                    UPDATE entries SET last_copied_at = ?, times_copied = times_copied + 1,
                        library_path = COALESCE(?, library_path), change_seq = ? WHERE id = ?
                    """, [date.timeIntervalSince1970, capture.libraryPath, try nextChange(), id])
                return .bumped(id)
            }
            let blob = try writeBlob(of: capture)
            let archivedImage = try capture.kind == .image && (query(
                "SELECT 1 FROM entries WHERE kind = ? AND hash = ? AND pinned_at IS NOT NULL LIMIT 1", key) { $0.int(0) }.first != nil)
            if !archivedImage, let rewritten = try rewrittenEntry(by: capture, at: date) {
                try stack(capture, blob: blob, on: rewritten, at: date, here: false)
                return .stacked(rewritten.id)
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

    /// Puts `capture` on the card `id` as its newest version, for an image Sukusho made smaller itself: the same
    /// picture, so history gains no entry. The card keeps its place. False, with nothing changed, when another
    /// card already holds exactly that content: two cards can't hold one content.
    @discardableResult
    func stack(_ capture: ClipboardCapture, on id: String) throws -> Bool {
        try transaction {
            let elsewhere = try query("SELECT id FROM entries WHERE kind = 'image' AND hash = ? AND id != ? AND pinned_at IS NULL", [capture.hash, id]) { $0.text(0) }
            guard elsewhere.isEmpty else { return false }
            let rows = try query("SELECT hash, blob, library_path, last_copied_at FROM entries WHERE id = ? AND kind = 'image'", [id]) { row in
                (hash: row.text(0) ?? "", blob: row.text(1), libraryPath: row.text(2), copiedAt: row.double(3))
            }
            guard let current = rows.first, current.hash != capture.hash else { return true }
            let blob = try writeBlob(of: capture)
            try stack(capture, blob: blob, on: (id, current.hash, current.blob == nil ? current.libraryPath : nil),
                      at: Date(timeIntervalSince1970: current.copiedAt), here: true)
            return true
        }
    }

    private func stack(_ capture: ClipboardCapture, blob: String?, on rewritten: (id: String, hash: String, libraryPath: String?),
                       at date: Date, here: Bool) throws {
        // The card's current version, with its own hash, image and Library link, becomes an earlier one; the
        // new copy is the newest, shown and pasted. The card keeps its source and first copy time.
        try run("""
            INSERT OR IGNORE INTO versions (entry_id, hash, blob, library_path, byte_size, stored_bytes, copied_at)
            SELECT id, hash, blob, library_path, byte_size, stored_bytes, last_copied_at FROM entries WHERE id = ?
            """, [rewritten.id])
        // A kept Original owns its bytes: a capture file can be edited or trashed later (Astra L1).
        if let owned = try snapshot(rewritten.libraryPath, hash: rewritten.hash) {
            try run("UPDATE versions SET blob = ?, stored_bytes = ? WHERE entry_id = ? AND hash = ?",
                    [owned.blob, owned.bytes, rewritten.id, rewritten.hash])
        }
        // What was read or said about the earlier image is cleared, so the newest is read and described
        // afresh (Astra L3); late answers for the earlier image are kept out by their hash guard.
        try run("""
            UPDATE entries SET hash = ?, blob = ?, library_path = ?, byte_size = ?, stored_bytes = ?,
                last_copied_at = ?, change_seq = ?, read_text = NULL, model_title = NULL, model_keywords = NULL,
                model_category = NULL, described = 0, optimized_here = ? WHERE id = ?
            """, [capture.hash, blob, capture.libraryPath, capture.byteSize, capture.storedBytes,
                  date.timeIntervalSince1970, try nextChange(), here ? 1 : 0, rewritten.id])
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

    func updateSnippet(_ id: String, title: String, text: String, at date: Date = .now) throws {
        try run("UPDATE entries SET title = ?, text = ?, byte_size = ?, stored_bytes = ?, snippet_edited_at = ?, change_seq = ? WHERE id = ? AND kind = 'snippet'",
                [title, text, text.utf8.count, text.utf8.count, date.timeIntervalSince1970, try nextChange(), id])
    }

    /// Saving a copy that only refers to a capture file snapshots that file, so the Saved card keeps its picture when
    /// the capture is edited or trashed (Astra L1). The capture link stays as it was.
    func moveToSaved(ids: [String], at date: Date = .now) throws {
        try transaction {
            for id in ids {
                try run("UPDATE entries SET pinned_at = ?, change_seq = ? WHERE id = ? AND kind != 'snippet' AND pinned_at IS NULL",
                        [date.timeIntervalSince1970, try nextChange(), id])
                guard sqlite3_changes(db) > 0, let reference = try query(
                    "SELECT library_path, hash FROM entries WHERE id = ? AND blob IS NULL AND library_path IS NOT NULL", [id],
                    { ($0.text(0), $0.text(1) ?? "") }).first,
                      let owned = try snapshot(reference.0, hash: reference.1) else { continue }
                try run("UPDATE entries SET blob = ?, stored_bytes = ? WHERE id = ?", [owned.blob, owned.bytes, id])
            }
        }
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
    /// Every copy but the saved ones (pinned_at) and snippets, which belong to the Library.
    func deleteHistory() throws {
        try delete(ids: try query("SELECT id FROM entries WHERE kind != 'snippet' AND pinned_at IS NULL", []) { $0.text(0) ?? "" })
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
        // Measured again after each eviction: cards can share an image file, so what a card frees depends on what's left
        // (Astra L2: counting a shared file twice evicted a stack while the files were within the cap).
        var evicted: [String] = []
        if try totalBytes() > maxBytes {
            let oldest = try query(
                "SELECT id FROM entries WHERE kind != 'snippet' AND pinned_at IS NULL ORDER BY last_copied_at", []) { $0.text(0) ?? "" }
            for id in oldest {
                guard try totalBytes() > maxBytes else { break }
                try delete(ids: [id])
                evicted.append(id)
            }
        }
        return doomed.count + evicted.count
    }

    // MARK: - Reading

    /// Newest first, each with its earlier versions.
    func entries(limit: Int = 500, offset: Int = 0, includeArchive: Bool = false) throws -> [ClipboardEntry] {
        // Versions come newest first, in the order they were set aside (the table's row order), not by their
        // copy times: Optimize keeps a card's copy time, so those can all be equal, and the last one must be
        // the original.
        let versions = Dictionary(grouping: try query("""
            SELECT entry_id, hash, blob, library_path, byte_size, copied_at FROM versions ORDER BY rowid DESC
            """, []) { row in
            (row.text(0) ?? "", ClipboardEntryVersion(hash: row.text(1) ?? "", imageURL: row.text(2).map { blobs.appendingPathComponent($0) },
                                                       libraryPath: row.text(3), byteSize: row.int(4),
                                                       copiedAt: Date(timeIntervalSince1970: row.double(5))))
        }, by: \.0).mapValues { $0.map(\.1) }
        let links = Dictionary(grouping: try query("SELECT entry_id, url FROM clip_cloud_links ORDER BY position", []) {
            ($0.text(0) ?? "", $0.text(1) ?? "")
        }, by: \.0).mapValues { $0.map(\.1) }
        let page = includeArchive
            ? """
              WHERE pinned_at IS NOT NULL OR kind = 'snippet' OR id IN (
                  SELECT id FROM entries WHERE pinned_at IS NULL AND kind != 'snippet' ORDER BY last_copied_at DESC LIMIT ? OFFSET ?)
              ORDER BY last_copied_at DESC
              """
            : "ORDER BY last_copied_at DESC LIMIT ? OFFSET ?"
        return try query("""
            SELECT id, kind, text, title, blob, library_path, byte_size, pixel_width, pixel_height, source_bundle_id,
                is_remote, first_copied_at, last_copied_at, times_copied, pinned_at,
                read_text, model_title, model_keywords, model_category, described, hash, optimized_here, snippet_edited_at
            FROM entries \(page)
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
                pinnedAt: row.isNull(14) ? nil : Date(timeIntervalSince1970: row.double(14)),
                readText: row.text(15),
                modelTitle: row.text(16),
                keywords: (row.text(17) ?? "").split(separator: "\n").map(String.init),
                category: row.text(18),
                isDescribed: row.int(19) != 0,
                hash: row.text(20) ?? "",
                earlierVersions: versions[row.text(0) ?? ""] ?? [],
                isOptimizedHere: row.int(21) != 0,
                cloudLinks: links[row.text(0) ?? ""] ?? [],
                snippetEditedAt: row.isNull(22) ? nil : Date(timeIntervalSince1970: row.double(22))
            )
        }
    }

    /// The text read in an image; empty when it has none, so it isn't read again.
    /// With `hash`, nothing is written when the entry's content changed while its text was read: the answer
    /// belongs to the image it was asked about (Astra, 2026-11-16).
    func setReadText(_ id: String, _ text: String, forHash hash: String? = nil) throws {
        try run("UPDATE entries SET read_text = ?, change_seq = ? WHERE id = ? AND (? IS NULL OR hash = ?)",
                [text, try nextChange(), id, hash, hash])
    }

    /// The model's answer for an image, or its refusal (no title), after which it isn't asked again; with `hash`,
    /// only while the entry still holds that content.
    func setDescription(_ id: String, title: String?, keywords: [String], category: String?, forHash hash: String? = nil) throws {
        try run("""
            UPDATE entries SET model_title = ?, model_keywords = ?, model_category = ?, described = 1, change_seq = ?
            WHERE id = ? AND (? IS NULL OR hash = ?)
            """, [title, keywords.isEmpty ? nil : keywords.joined(separator: "\n"), category, try nextChange(), id, hash, hash])
    }

    func setCloudLink(_ url: String, entry: String, position: Int) throws {
        try run("INSERT OR REPLACE INTO clip_cloud_links(entry_id, position, url) VALUES(?, ?, ?)", [entry, position, url])
    }

    func removeCloudLink(_ url: String) throws {
        try run("DELETE FROM clip_cloud_links WHERE url = ?", [url])
    }

    func richText(for id: String) throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try query("SELECT type, data FROM rich_text WHERE entry_id = ?", [id]) {
            ($0.text(0) ?? "", $0.data(1))
        })
    }

    func totalBytes() throws -> Int64 {
        // Count each blob once. Migrated capture references keep their pre-upgrade charge of zero.
        Int64(try query("""
            WITH history AS (SELECT * FROM entries WHERE pinned_at IS NULL AND kind != 'snippet'),
                 history_versions AS (SELECT v.* FROM versions v JOIN history h ON h.id = v.entry_id)
            SELECT COALESCE((SELECT SUM(bytes) FROM (
                       SELECT MAX(stored_bytes) AS bytes FROM (
                           SELECT blob, stored_bytes FROM history WHERE blob IS NOT NULL
                           UNION ALL SELECT blob, stored_bytes FROM history_versions WHERE blob IS NOT NULL)
                       GROUP BY blob)), 0)
                 + COALESCE((SELECT SUM(stored_bytes) FROM history WHERE blob IS NULL), 0)
                 + COALESCE((SELECT SUM(stored_bytes) FROM history_versions WHERE blob IS NULL), 0)
            """, []) { $0.int(0) }.first ?? 0)
    }

    // MARK: - SQLite

    /// The entry `capture` stacks on as a newer version, if any: the latest copy, an unpinned image copied once under
    /// `rewriteWindow` ago, with nothing copied in between, that looks like the same picture (`ClipboardImageMatch`).
    /// The match is approximate (Astra C1/C2: a low-contrast word, a faint selection, transparency), which is why it
    /// only ever stacks and never deletes. A copy of a Library capture is never a rewrite: an optimiser's version
    /// has no file in History.
    private func rewrittenEntry(by capture: ClipboardCapture, at date: Date) throws
        -> (id: String, hash: String, libraryPath: String?)? {
        guard capture.kind == .image, capture.libraryPath == nil, let incoming = capture.image else { return nil }
        let latest = try query("""
            SELECT id, kind, pixel_width, pixel_height, times_copied, pinned_at IS NULL, last_copied_at, blob, library_path, hash
            FROM entries WHERE kind != 'snippet' ORDER BY last_copied_at DESC LIMIT 1
            """, []) { row in
            (id: row.text(0) ?? "", kind: row.text(1), width: row.int(2), height: row.int(3), times: row.int(4),
             unpinned: row.int(5) != 0, copiedAt: row.double(6), blob: row.text(7), libraryPath: row.text(8),
             hash: row.text(9) ?? "")
        }.first
        guard let latest, latest.kind == ClipboardEntryKind.image.rawValue, latest.unpinned, latest.times == 1,
              latest.width == capture.pixelWidth, latest.height == capture.pixelHeight,
              (0..<Self.rewriteWindow).contains(date.timeIntervalSince1970 - latest.copiedAt),
              let picture = latest.blob.map({ blobs.appendingPathComponent($0) }) ?? latest.libraryPath.map(URL.init(fileURLWithPath:)),
              ClipboardImageMatch.isSamePicture(incoming, picture) else { return nil }
        return (latest.id, latest.hash, latest.blob == nil ? latest.libraryPath : nil)
    }

    /// Copies a capture file into the blob store under its content's name, when it still holds the content `hash`
    /// names; nil when it's gone or changed, since then the bytes it stood for are already lost.
    private func snapshot(_ path: String?, hash: String) throws -> (blob: String, bytes: Int)? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              ClipboardPasteboardReader.digest(data) == hash else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension
        return (try Self.writeBlob(data, hash: hash, ext: ext, in: directory), data.count)
    }

    private func writeBlob(of capture: ClipboardCapture) throws -> String? {
        guard let image = capture.image else { return nil }
        return try Self.writeBlob(image, hash: ClipboardPasteboardReader.digest(image),
                                  ext: capture.imageExtension ?? "img", in: directory)
    }

    nonisolated private static func writeBlob(_ image: Data, hash: String, ext: String, in directory: URL) throws -> String {
        let name = "\(hash.prefix(2))/\(hash).\(ext.isEmpty ? "img" : ext)"
        let url = directory.appendingPathComponent("Blobs").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try image.write(to: url, options: .atomic) }
        return name
    }

    /// Deletes the entries with their versions. An image file goes only when nothing else uses it: blobs are named
    /// by content, so a version and a later copy of the same picture share one.
    private func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            let files = try query("""
                SELECT blob FROM entries WHERE id = ? AND blob IS NOT NULL
                UNION SELECT blob FROM versions WHERE entry_id = ? AND blob IS NOT NULL
                """, [id, id]) { $0.text(0) ?? "" }
            try run("DELETE FROM versions WHERE entry_id = ?", [id])
            try run("DELETE FROM entries WHERE id = ?", [id])
            for file in files {
                let uses = try query("""
                    SELECT (SELECT COUNT(*) FROM entries WHERE blob = ?) + (SELECT COUNT(*) FROM versions WHERE blob = ?)
                    """, [file, file]) { $0.int(0) }.first ?? 0
                if uses == 0 { try? FileManager.default.removeItem(at: blobs.appendingPathComponent(file)) }
            }
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
        try Self.query(db, sql, values, map)
    }

    nonisolated private static func query<T>(_ db: OpaquePointer, _ sql: String, _ values: [Any?], _ map: (Row) -> T) throws -> [T] {
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
