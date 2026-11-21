import Darwin
import Foundation

/// Which view the clipboard popup is showing when "Apps and folders in the clipboard panel" is enabled.
nonisolated enum ClipboardPopupMode: String, CaseIterable, Identifiable, Sendable {
    case clipboard, apps

    var id: Self { self }

    /// Toggles between Clipboard and Apps when enabled; stays in Clipboard when disabled.
    func toggled(launcherEnabled: Bool) -> Self {
        guard launcherEnabled else { return .clipboard }
        return self == .clipboard ? .apps : .clipboard
    }

    /// Plain Tab toggles Clipboard ↔ Apps when enabled; Shift-Tab leaves the mode unchanged.
    func afterTab(shifted: Bool = false, launcherEnabled: Bool) -> Self {
        guard launcherEnabled else { return .clipboard }
        return shifted ? self : toggled(launcherEnabled: true)
    }
}

// MARK: - App Catalog & Scanner (ported from Unleash)

/// One app or folder entry. `path` is the identity (favorites are kept by path).
nonisolated struct LauncherAppEntry: Codable, Hashable, Sendable {
    var path: String
    var name: String
    var version: String?

    init(path: String, name: String, version: String? = nil) {
        self.path = path
        self.name = name
        self.version = version
    }

    var folder: String { (path as NSString).deletingLastPathComponent }
}

nonisolated enum LauncherItemKind: Equatable, Sendable {
    case app
    case folder
}

/// Composite row identity so a favorited item listed under both Favorites and its source section has distinct IDs.
nonisolated struct LauncherRowID: Hashable, Sendable {
    let inFavorites: Bool
    let path: String
}

nonisolated struct LauncherRow: Identifiable, Equatable, Sendable {
    let id: LauncherRowID
    let kind: LauncherItemKind
    let path: String
    let title: String
    let detail: String?
    let isFavorite: Bool
}

nonisolated struct LauncherSection: Identifiable, Equatable, Sendable {
    let title: String
    let inFavorites: Bool
    let rows: [LauncherRow]
    var id: String { title }
}

/// Case- and accent-folded Unicode scalars, so matching is an integer loop and a subsequence can
/// never match half of a character. ASCII (most app names) skips Foundation.
nonisolated enum LauncherFold {
    static func scalars<S: StringProtocol>(_ s: S) -> [UInt32] {
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            return s.utf8.map { UInt32($0 &- 65 < 26 ? $0 | 0x20 : $0) }
        }
        return String(s).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: nil).unicodeScalars.map(\.value)
    }
}

private nonisolated let launcherSpaceScalar: UInt32 = 0x20

/// A name ready for matching: folded scalars, where each word starts, and the words' first letters.
/// Words split at spaces and punctuation, at lower-to-upper case ("TextEdit"), and between
/// letters and digits ("1Password").
nonisolated struct LauncherSearchKey: Sendable {
    let text: [UInt32]
    let wordStarts: [Int]  // offsets into `text`, excluding 0
    let initials: [UInt32]

    init(_ name: String) {
        var text: [UInt32] = []
        var starts: [Int] = []
        var initials: [UInt32] = []
        text.reserveCapacity(name.unicodeScalars.count)

        enum Kind { case sep, lower, upper, digit }
        func kind(_ c: Character) -> Kind {
            if c.isNumber { return .digit }
            if c.isLetter { return c.isUppercase ? .upper : .lower }
            return .sep
        }
        // Split into runs; fold each run on its own so word offsets stay exact.
        var runStart = name.startIndex
        var prev: Kind? = nil
        func flush(_ end: String.Index, isWord: Bool) {
            guard runStart < end else { return }
            let folded = LauncherFold.scalars(name[runStart..<end])
            if isWord, let first = folded.first {
                if !text.isEmpty { starts.append(text.count) }
                initials.append(first)
            }
            text += folded
        }
        for i in name.indices {
            let k = kind(name[i])
            if let p = prev {
                let wasWord = p != .sep, isWord = k != .sep
                let split = wasWord != isWord
                    || (wasWord && isWord && (
                        (p == .lower && k == .upper) || ((p == .digit) != (k == .digit))))
                if split {
                    flush(i, isWord: wasWord)
                    runStart = i
                }
            }
            prev = k
        }
        flush(name.endIndex, isWord: prev.map { $0 != .sep } ?? false)

        self.text = text
        self.wordStarts = starts
        self.initials = initials
    }

    func match(_ q: [UInt32], _ compact: [UInt32]) -> LauncherMatchTier? {
        text.withUnsafeBufferPointer { t in
            q.withUnsafeBufferPointer { q in
                if q.count <= t.count {
                    if Self.matches(q, t, at: 0) { return .prefix }
                    for s in wordStarts where Self.matches(q, t, at: s) { return .wordPrefix }
                    if t.count > q.count {
                        for s in 1...(t.count - q.count) where Self.matches(q, t, at: s) { return .substring }
                    }
                }
                if Self.hasPrefix(initials, compact) { return .initials }
                return compact.withUnsafeBufferPointer { Self.subsequence($0, t) } ? .subsequence : nil
            }
        }
    }

    private static func matches(_ q: UnsafeBufferPointer<UInt32>, _ t: UnsafeBufferPointer<UInt32>, at s: Int) -> Bool {
        if s + q.count > t.count { return false }
        for j in 0..<q.count where t[s + j] != q[j] { return false }
        return true
    }

    private static func hasPrefix(_ a: [UInt32], _ p: [UInt32]) -> Bool {
        p.count <= a.count && a.starts(with: p)
    }

    private static func subsequence(_ q: UnsafeBufferPointer<UInt32>, _ t: UnsafeBufferPointer<UInt32>) -> Bool {
        if q.isEmpty { return true }
        var j = 0
        for c in t where c == q[j] {
            j += 1
            if j == q.count { return true }
        }
        return false
    }
}

nonisolated enum LauncherMatchTier: Int, Sendable { case prefix, wordPrefix, substring, initials, subsequence }

nonisolated struct LauncherRankedMatch: Equatable, Sendable {
    let index: Int
    let tier: LauncherMatchTier
}

/// One list from several sources' ranked matches.
nonisolated enum LauncherRanking {
    /// Bucket = tier's place * 2 + not-favorite; initials and subsequence share the last tier but
    /// initials sort first within it.
    static func slot(_ tier: LauncherMatchTier, favorite: Bool) -> Int {
        switch tier {
        case .prefix, .wordPrefix, .substring: tier.rawValue * 2 + (favorite ? 0 : 1)
        case .initials: favorite ? 6 : 8
        case .subsequence: favorite ? 7 : 9
        }
    }

    /// By tier, favorites first within a tier (in pin order), then in source order, each source's
    /// own order kept. A `demoted` source's matches (folders) never outrank another source's
    /// prefix or word-prefix match, unless they're favorites: "Pro" stays on Premiere Pro rather
    /// than a Projects folder.
    static func merge<T>(_ sources: [(matches: [(value: T, id: String, tier: LauncherMatchTier)], demoted: Bool)],
                         favorites: [String]) -> [T] {
        let place = Dictionary(favorites.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var buckets = [[(value: T, place: Int)]](repeating: [], count: 10)
        for source in sources {
            for match in source.matches {
                let pin = place[match.id]
                var slot = slot(match.tier, favorite: pin != nil)
                if source.demoted, pin == nil { slot = max(slot, 4) }
                buckets[slot].append((match.value, pin ?? .max))
            }
        }
        return buckets.flatMap { bucket in
            bucket.enumerated().sorted { ($0.element.place, $0.offset) < ($1.element.place, $1.offset) }
                .map(\.element.value)
        }
    }
}

/// The scanned apps sorted A to Z (or folders in zoxide score order), with what each row needs precomputed:
/// the secondary label that tells same-named apps apart, and the folded scalars the search matches against.
nonisolated struct LauncherCatalog: Sendable {
    let apps: [LauncherAppEntry]
    /// Secondary text after the name, set only when another app has the same name.
    let details: [String?]
    let keys: [LauncherSearchKey]
    private let indexByPath: [String: Int]

    init(_ entries: [LauncherAppEntry], home: String = NSHomeDirectory(), sorted: Bool = true) {
        let apps = sorted ? LauncherCatalog.sortedAZ(entries) : entries
        self.apps = apps
        self.details = LauncherCatalog.details(apps, home: home)
        self.keys = apps.map { LauncherSearchKey($0.name) }
        self.indexByPath = Dictionary(apps.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static let empty = LauncherCatalog([])

    var count: Int { apps.count }

    func index(ofPath path: String) -> Int? { indexByPath[path] }

    /// Ranked matches with their match tiers, for interleaving apps and folders.
    func searchRanked(_ query: String, pinned: [Int?]) -> [LauncherRankedMatch] {
        let q = LauncherFold.scalars(query.drop(while: { $0 == " " }))
        let compact = q.filter { $0 != launcherSpaceScalar }
        if compact.isEmpty { return [] }
        var buckets = [[LauncherRankedMatch]](repeating: [], count: 10)
        for i in keys.indices {
            guard let tier = keys[i].match(q, compact) else { continue }
            let fav = i < pinned.count && pinned[i] != nil
            buckets[LauncherRanking.slot(tier, favorite: fav)].append(LauncherRankedMatch(index: i, tier: tier))
        }
        for slot in [0, 2, 4, 6, 7] where buckets[slot].count > 1 {
            buckets[slot].sort { pinned[$0.index]! < pinned[$1.index]! }
        }
        return Array(buckets.joined())
    }

    /// Ranked matches as indices into `apps`: name prefix, word prefix, substring, then initials or
    /// subsequence (initials first). Favorites come first within each tier, in pin order; the rest stay A to Z.
    func search(_ query: String, pinned: [Int?]) -> [Int] {
        searchRanked(query, pinned: pinned).map(\.index)
    }

    /// The tier `name` matches `query` at, for tests.
    static func tier(of name: String, for query: String) -> LauncherMatchTier? {
        let q = LauncherFold.scalars(query.drop(while: { $0 == " " }))
        return LauncherSearchKey(name).match(q, q.filter { $0 != launcherSpaceScalar })
    }

    /// Display-name order: case- and accent-insensitive, numbers by value, in the user's locale.
    /// Ties (same name) fall back to the path so the order is stable.
    static func sortedAZ(_ entries: [LauncherAppEntry]) -> [LauncherAppEntry] {
        let locale = Locale.current
        return entries.sorted { a, b in
            switch a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric],
                                  range: nil, locale: locale) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.path < b.path
            }
        }
    }

    /// For apps that share a (folded) name: the version when it is unique in that group,
    /// otherwise the folder, with the home folder written as `~`.
    static func details(_ apps: [LauncherAppEntry], home: String) -> [String?] {
        var groups: [[UInt32]: [Int]] = [:]
        for (i, app) in apps.enumerated() { groups[LauncherFold.scalars(app.name), default: []].append(i) }
        var out = [String?](repeating: nil, count: apps.count)
        for members in groups.values where members.count > 1 {
            var versionUses: [String: Int] = [:]
            for i in members {
                if let v = apps[i].version, !v.isEmpty { versionUses[v, default: 0] += 1 }
            }
            for i in members {
                if let v = apps[i].version, versionUses[v] == 1 {
                    out[i] = v
                } else {
                    out[i] = abbreviate(apps[i].folder, home: home)
                }
            }
        }
        return out
    }

    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Builds the Apps view's sections: Favorites + Applications + Folders when empty, `z ` full-path
/// zoxide matching in score order, or merged app+folder fuzzy search (matching Unleash's `Launcher.swift`).
nonisolated enum LauncherList {
    static func sections(
        query: String,
        apps: LauncherCatalog,
        folders: LauncherCatalog,
        favorites: LauncherFavorites,
        home: String = NSHomeDirectory()
    ) -> [LauncherSection] {
        let favSet = Set(favorites.paths)

        func appRow(_ i: Int, inFavorites: Bool) -> LauncherRow {
            let entry = apps.apps[i]
            return LauncherRow(
                id: LauncherRowID(inFavorites: inFavorites, path: entry.path),
                kind: .app,
                path: entry.path,
                title: entry.name,
                detail: apps.details[i],
                isFavorite: favSet.contains(entry.path)
            )
        }

        func folderRow(_ i: Int, inFavorites: Bool) -> LauncherRow {
            let entry = folders.apps[i]
            return LauncherRow(
                id: LauncherRowID(inFavorites: inFavorites, path: entry.path),
                kind: .folder,
                path: entry.path,
                title: entry.name,
                detail: LauncherCatalog.abbreviate(entry.folder, home: home),
                isFavorite: favSet.contains(entry.path)
            )
        }

        if query.allSatisfy({ $0 == " " }) {
            var out: [LauncherSection] = []
            let pinnedRows: [LauncherRow] = favorites.paths.compactMap { path in
                if let i = apps.index(ofPath: path) { return appRow(i, inFavorites: true) }
                if let i = folders.index(ofPath: path) { return folderRow(i, inFavorites: true) }
                return nil
            }
            if !pinnedRows.isEmpty {
                out.append(LauncherSection(title: "Favorites", inFavorites: true, rows: pinnedRows))
            }
            if apps.count > 0 {
                out.append(LauncherSection(title: "Applications", inFavorites: false,
                                           rows: apps.apps.indices.map { appRow($0, inFavorites: false) }))
            }
            if folders.count > 0 {
                out.append(LauncherSection(title: "Folders", inFavorites: false,
                                           rows: folders.apps.indices.map { folderRow($0, inFavorites: false) }))
            }
            return out
        }

        // Leading `z ` routes strictly to zoxide full-path matching in score order (ignoring favorites).
        if let zQuery = Zoxide.keywordQuery(query) {
            let rows = folders.apps.indices
                .filter { Zoxide.matches(folders.apps[$0].path, query: zQuery) }
                .map { folderRow($0, inFavorites: false) }
            guard !rows.isEmpty else { return [] }
            return [LauncherSection(title: "Folders", inFavorites: false, rows: rows)]
        }

        // Normal search: interleave apps and demoted folders by match tier, favorites first within tier.
        func pinnedIndices(in catalog: LauncherCatalog) -> [Int?] {
            var pinned = [Int?](repeating: nil, count: catalog.count)
            for (place, path) in favorites.paths.enumerated() {
                if let i = catalog.index(ofPath: path) { pinned[i] = place }
            }
            return pinned
        }

        let appMatches = apps.searchRanked(query, pinned: pinnedIndices(in: apps)).map {
            let row = appRow($0.index, inFavorites: false)
            return (value: row, id: row.path, tier: $0.tier)
        }
        let folderMatches = folders.searchRanked(query, pinned: pinnedIndices(in: folders)).map {
            let row = folderRow($0.index, inFavorites: false)
            return (value: row, id: row.path, tier: $0.tier)
        }
        let merged = LauncherRanking.merge(
            [(matches: appMatches, demoted: false), (matches: folderMatches, demoted: true)],
            favorites: favorites.paths
        )
        guard !merged.isEmpty else { return [] }
        return [LauncherSection(title: "Results", inFavorites: false, rows: merged)]
    }
}

/// Finds apps by listing folders. No Spotlight, no LaunchServices database walk.
nonisolated enum LauncherAppScanner {
    struct Root: Sendable {
        var path: String
        /// How many folder levels below `path` to look into for more apps.
        var depth: Int
        init(_ path: String, depth: Int) { self.path = path; self.depth = depth }
    }

    static let finder = "/System/Library/CoreServices/Finder.app"

    /// `/Applications` and `~/Applications` one level down (Utilities, `Chrome Apps.localized`,
    /// vendor folders), `/System/Applications` and its `Utilities`, plus Finder.
    static func defaultRoots(home: String = NSHomeDirectory()) -> [Root] {
        [Root("/Applications", depth: 1),
         Root("/System/Applications", depth: 1),
         Root(home + "/Applications", depth: 1)]
    }

    /// Every `.app` under the roots, plus `extras`, each once (a symlinked app counts once).
    static func scan(_ roots: [Root] = defaultRoots(), extras: [String] = [finder]) -> [LauncherAppEntry] {
        var seen = Set<String>()
        var out: [LauncherAppEntry] = []
        func add(_ path: String) {
            guard seen.insert(realPath(path)).inserted, let entry = entry(at: path) else { return }
            out.append(entry)
        }
        func walk(_ dir: String, _ depth: Int) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if depth > 0, isDirectory(path) {
                    walk(path, depth - 1)
                }
            }
        }
        for root in roots { walk(root.path, root.depth) }
        for path in extras { add(path) }
        return out
    }

    /// Name as Finder shows it (localized, no `.app`), and the short version string.
    static func entry(at path: String) -> LauncherAppEntry? {
        guard isDirectory(path) else { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        let version = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        return LauncherAppEntry(path: path, name: name, version: version?.isEmpty == false ? version : nil)
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }
}

/// Pinned apps and folders by path, in the order they were pinned. Saved as a JSON array of paths.
nonisolated struct LauncherFavorites: Equatable, Sendable {
    private(set) var paths: [String]

    init(_ paths: [String] = []) { self.paths = paths }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Pins at the end, or unpins. Returns whether it is pinned now.
    @discardableResult
    mutating func toggle(_ path: String) -> Bool {
        if let i = paths.firstIndex(of: path) {
            paths.remove(at: i)
            return false
        }
        paths.append(path)
        return true
    }

    /// A missing or unreadable file is an empty list, so a bad file never stops the app.
    static func load(_ url: URL) -> LauncherFavorites {
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return LauncherFavorites() }
        return LauncherFavorites(paths)
    }

    func save(_ url: URL) throws {
        try LauncherStore.write(paths, to: url)
    }
}

nonisolated enum LauncherStore {
    static func loadApps(_ url: URL) -> [LauncherAppEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LauncherAppEntry].self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - zoxide Folders (ported from Unleash)

/// The folders zoxide knows (`zoxide query --list --score --all`). An app gets no shell PATH, so the
/// binary is looked for where Homebrew (and cargo/local installs) put it.
nonisolated enum Zoxide {
    struct Folder: Equatable, Sendable {
        let path: String
        let score: Double

        init(path: String, score: Double) {
            self.path = path
            self.score = score
        }
    }

    static let candidates = ["/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide"]

    static func defaultCandidates(home: String = NSHomeDirectory()) -> [String] {
        candidates + [home + "/.local/bin/zoxide", home + "/.cargo/bin/zoxide"]
    }

    static func binary(in candidates: [String] = candidates) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Lines like `  96.0 /Users/me/My Folder`: a right-aligned score, one space, the path (which
    /// may itself hold spaces). Lines that don't fit are skipped.
    static func parse(_ output: String) -> [Folder] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.drop(while: { $0 == " " })
            guard let gap = trimmed.firstIndex(of: " "), let score = Double(trimmed[..<gap]) else { return nil }
            let path = trimmed[trimmed.index(after: gap)...]
            guard path.hasPrefix("/") else { return nil }
            return Folder(path: String(path), score: score)
        }
    }

    /// Runs zoxide (most-used first, as it prints them); nil if it can't run or fails.
    /// `--all` because without it zoxide checks every folder and deletes from its database the
    /// ones it can't see that weren't visited for 3 months (zoxide 0.10's `stream.rs`), which a
    /// listing on panel show must not do. `existing` drops missing ones instead.
    static func folders(binary: String) -> [Folder]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["query", "--list", "--score", "--all"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Without the folders that are gone. Folders macOS guards with a privacy prompt (Desktop,
    /// Documents, Downloads, iCloud Drive, cloud storage, other volumes) aren't checked: the check
    /// could ask the owner, and the prompt would take the keyboard from the panel.
    static func existing(_ folders: [Folder], home: String = NSHomeDirectory(),
                         isFolder: (String) -> Bool = isFolder) -> [Folder] {
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 }
        return folders.filter { folder in
            let path = folder.path
            if path.hasPrefix("/Volumes/") || guarded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return true
            }
            return isFolder(path)
        }
    }

    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// As list rows: named after the folder, kept in zoxide's order. Folders inside app bundles are
    /// skipped: they'd share the app's id (its path).
    static func entries(_ folders: [Folder]) -> [LauncherAppEntry] {
        folders.filter { !$0.path.contains(".app/") && !$0.path.hasSuffix(".app") }
            .map { LauncherAppEntry(path: $0.path, name: ($0.path as NSString).lastPathComponent) }
    }

    /// Catalog of zoxide folders in descending score order (not A to Z).
    static func catalog(_ folders: [Folder]) -> LauncherCatalog {
        LauncherCatalog(entries(folders.sorted { $0.score > $1.score }), sorted: false)
    }

    /// The query after a leading `z ` keyword, or nil for normal search.
    static func keywordQuery(_ query: String) -> String? {
        query.hasPrefix("z ") ? String(query.dropFirst(2)) : nil
    }

    private static let rootLocale = Locale(identifier: "")

    /// Whether `path` matches `query` the way `z` does: every word in order, after lowercasing,
    /// matched literally on UTF-8 bytes, with the last word inside the last path component. An
    /// empty query matches every path.
    static func matches(_ path: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { Array($0.lowercased(with: rootLocale).utf8) }
        guard let last = words.last else { return true }
        let bytes = Array(path.lowercased(with: rootLocale).utf8)
        guard let lastStart = lastIndex(of: last, in: bytes) else { return false }
        if bytes[(lastStart + last.count)...].contains(UInt8(ascii: "/")) { return false }
        var cursor = 0
        for word in words.dropLast() {
            guard let start = firstIndex(of: word, in: bytes, from: cursor, end: lastStart) else { return false }
            cursor = start + word.count
        }
        return true
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int, end: Int) -> Int? {
        guard needle.count <= end - start else { return nil }
        for i in start...(end - needle.count) where haystack[i..<(i + needle.count)].elementsEqual(needle) {
            return i
        }
        return nil
    }

    private static func lastIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in stride(from: haystack.count - needle.count, through: 0, by: -1)
            where haystack[i..<(i + needle.count)].elementsEqual(needle)
        {
            return i
        }
        return nil
    }

    /// Folders matching `query` the way `z` does, ranked by zoxide's score (highest first).
    static func match(_ query: String, in folders: [Folder]) -> [Folder] {
        folders.filter { matches($0.path, query: query) }.sorted { $0.score > $1.score }
    }
}
