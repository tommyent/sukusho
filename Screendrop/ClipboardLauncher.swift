import Darwin
import Foundation
import os

/// Thread-safe session generation so background scans, zoxide reads, disk cache writes, and icon loads
/// started in an earlier open/enabled session never publish or write after close or disable.
nonisolated final class LauncherSession: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var isActive = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts a new active session, or returns the active session's token if already active.
    func begin() -> UInt64 {
        state.withLock { s in
            if !s.isActive {
                s.generation &+= 1
                s.isActive = true
            }
            return s.generation
        }
    }

    /// Returns the active session token if a session is currently active, or nil while closed/disabled.
    var currentToken: UInt64? {
        state.withLock { $0.isActive ? $0.generation : nil }
    }

    /// Ends the active session so any in-flight work from it sees `isCurrent(token) == false`.
    func invalidate() {
        state.withLock { s in
            s.generation &+= 1
            s.isActive = false
        }
    }

    func isCurrent(_ token: UInt64) -> Bool {
        state.withLock { $0.isActive && $0.generation == token }
    }
}

/// Which view the clipboard popup is showing when "Apps and folders in the clipboard panel" is enabled.
nonisolated enum ClipboardPopupMode: String, CaseIterable, Identifiable, Sendable {
    case clipboard, apps

    var id: Self { self }

    /// Toggles between Clipboard and Apps when enabled; stays in Clipboard when disabled.
    func toggled(launcherEnabled: Bool) -> Self {
        guard launcherEnabled else { return .clipboard }
        return self == .clipboard ? .apps : .clipboard
    }

    /// Initial mode when opening the popup: opens straight into Apps when clipboard history is off
    /// and the launcher option is on; otherwise opens in Clipboard.
    static func initial(clipboardHistoryEnabled: Bool, launcherEnabled: Bool) -> Self {
        (!clipboardHistoryEnabled && launcherEnabled) ? .apps : .clipboard
    }

    /// Plain Tab toggles Clipboard ↔ Apps when enabled; Shift-Tab leaves the mode unchanged.
    func afterTab(shifted: Bool = false, launcherEnabled: Bool) -> Self {
        guard launcherEnabled else { return .clipboard }
        return shifted ? self : toggled(launcherEnabled: true)
    }
}

/// Which responder currently holds keyboard focus inside the clipboard popup.
nonisolated enum ClipboardPopupFocus: Equatable, Sendable {
    case search
    case control
    case other
}

/// Pure routing decision for key events when the launcher option is enabled.
nonisolated enum ClipboardPopupKeyPolicy {
    enum Decision: Equatable, Sendable {
        case toggleMode
        case handlePopupKey
        case passThroughWithoutRefocus
    }

    static let tabKeyCode = 48
    static let spaceKeyCode = 49
    static let returnKeyCode = 36
    static let keypadEnterKeyCode = 76
    static let escapeKeyCode = 53
    static let arrowKeyCodes: Set<Int> = [123, 124, 125, 126]

    /// Decides how to handle a key press when `launcherEnabled` is true:
    /// - Marked text (IME composition) in the search field passes straight through.
    /// - Plain Tab toggles Clipboard ↔ Apps only while the search field has focus.
    /// - Shift-Tab always passes through without refocusing search (so keyboard navigation works).
    /// - When a non-search control has focus, Tab, Space, Return, and arrows pass through to that control
    ///   without stealing focus back to search; Escape and modified shortcuts still reach the popup.
    static func decide(
        keyCode: Int,
        hasShift: Bool,
        hasCommandOrControlOrOption: Bool,
        focus: ClipboardPopupFocus,
        hasMarkedText: Bool
    ) -> Decision {
        if focus == .search, hasMarkedText {
            return .passThroughWithoutRefocus
        }
        if keyCode == tabKeyCode, !hasCommandOrControlOrOption {
            if !hasShift, focus == .search {
                return .toggleMode
            }
            return .passThroughWithoutRefocus
        }
        if focus == .control, !hasCommandOrControlOrOption {
            if keyCode == escapeKeyCode, !hasShift {
                return .handlePopupKey
            }
            if keyCode == spaceKeyCode || keyCode == returnKeyCode || keyCode == keypadEnterKeyCode
                || arrowKeyCodes.contains(keyCode) {
                return .passThroughWithoutRefocus
            }
        }
        return .handlePopupKey
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

    /// Moves `selection` by `offset` within `rows` in a single pass, falling back to index 0.
    static func movedSelection(from selection: LauncherRowID?, by offset: Int, in rows: [LauncherRow]) -> LauncherRowID? {
        guard !rows.isEmpty else { return nil }
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        return rows[min(max(current + offset, 0), rows.count - 1)].id
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
    /// Stays strictly inside the configured roots: directory symlinks are never descended into, and
    /// `.app` symlinks are resolved lexically hop-by-hop and skipped if any hop leaves the allowed roots.
    static func scan(
        _ roots: [Root] = defaultRoots(),
        extras: [String] = [finder],
        isCancelled: () -> Bool = { false }
    ) -> [LauncherAppEntry] {
        var seen = Set<String>()
        var out: [LauncherAppEntry] = []

        var allowedRoots: [String] = []
        for root in roots {
            let std = URL(fileURLWithPath: root.path).standardizedFileURL.path
            allowedRoots.append(std)
            let resolved = realPath(root.path)
            if resolved != std { allowedRoots.append(resolved) }
            if std == "/Applications" || std == "/System/Applications" {
                allowedRoots.append("/System")
            }
        }

        func add(_ path: String) {
            guard !isCancelled(), seen.insert(realPath(path)).inserted, let entry = entry(at: path) else { return }
            out.append(entry)
        }

        func walk(_ dir: String, _ depth: Int) {
            guard !isCancelled(),
                  fileType(at: dir) == S_IFDIR,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                if isCancelled() { return }
                let path = dir + "/" + name
                guard let kind = fileType(at: path) else { continue }
                if name.hasSuffix(".app") {
                    if kind == S_IFDIR {
                        add(path)
                    } else if kind == S_IFLNK, symlinkStaysInside(path, allowedRoots: allowedRoots) {
                        add(path)
                    }
                } else if depth > 0, kind == S_IFDIR {
                    walk(path, depth - 1)
                }
            }
        }

        for root in roots {
            if isCancelled() { return out }
            walk(root.path, root.depth)
        }
        for path in extras {
            if isCancelled() { return out }
            add(path)
        }
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

    static func fileType(at path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// Follows symlink targets lexically via `readlink` without touching paths outside `allowedRoots`.
    static func symlinkStaysInside(_ path: String, allowedRoots: [String], maxHops: Int = 8) -> Bool {
        var current = path
        for _ in 0..<maxHops {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else {
                return false
            }
            let parent = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent, isDirectory: true)
            let resolved = URL(fileURLWithPath: target, relativeTo: parent).standardizedFileURL.path
            guard isPath(resolved, inside: allowedRoots) else { return false }
            guard let kind = fileType(at: resolved) else { return false }
            if kind == S_IFDIR { return true }
            if kind != S_IFLNK { return false }
            current = resolved
        }
        return false
    }

    private static func isPath(_ path: String, inside roots: [String]) -> Bool {
        roots.contains { root in
            let clean = root.hasSuffix("/") ? String(root.dropLast()) : root
            return path == clean || path.hasPrefix(clean + "/")
        }
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

    /// Loads Sukusho's favorites. If Sukusho has no favorites file yet, copies absolute-path pins in order
    /// from the first readable fallback (Unleash's current or legacy store), leaving the original in place.
    static func loadOrImport(from url: URL, fallbacks: [URL] = []) -> LauncherFavorites {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return load(url)
        }
        for source in fallbacks where fm.fileExists(atPath: source.path) {
            var seen = Set<String>()
            let imported = load(source).paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            guard !imported.isEmpty else { continue }
            let favorites = LauncherFavorites(imported)
            try? favorites.save(url)
            return favorites
        }
        return LauncherFavorites()
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

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try writeData(try encode(value), to: url)
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

    enum FetchResult: Equatable, Sendable {
        case success([Folder])
        case failed
        case cancelled
    }

    /// Runs zoxide (most-used first, as it prints them) with a wall-clock timeout, output byte cap,
    /// and cancellation hook so a hanging binary never wedges folder refreshes.
    /// `--all` so zoxide never prunes its database or probes protected folders on listing; Finder
    /// resolves the chosen folder when the user explicitly opens it.
    static func fetch(
        binary: String,
        timeout: TimeInterval = 3.0,
        maxBytes: Int = 4 * 1024 * 1024,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> FetchResult {
        if isCancelled() { return .cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["query", "--list", "--score", "--all"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failed }

        try? out.fileHandleForWriting.close()
        let pid = process.processIdentifier
        let stopReason = OSAllocatedUnfairLock<FetchResult?>(initialState: nil)
        let deadline = Date().addingTimeInterval(timeout)
        let sentTerm = OSAllocatedUnfairLock(initialState: false)

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        watchdog.setEventHandler {
            guard process.isRunning else {
                watchdog.cancel()
                return
            }
            let reason: FetchResult? = isCancelled() ? .cancelled : (Date() >= deadline ? .failed : nil)
            guard let reason else { return }
            stopReason.withLock { if $0 == nil { $0 = reason } }
            let alreadySentTerm = sentTerm.withLock { flag -> Bool in
                if flag { return true }
                flag = true
                return false
            }
            if !alreadySentTerm {
                process.terminate()
            } else {
                kill(pid, SIGKILL)
                watchdog.cancel()
            }
        }
        watchdog.resume()

        let reader = out.fileHandleForReading
        var data = Data()
        var overflow = false
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxBytes {
                overflow = true
                stopReason.withLock { if $0 == nil { $0 = .failed } }
                kill(pid, SIGKILL)
                break
            }
        }
        try? reader.close()
        process.waitUntilExit()
        watchdog.cancel()

        if let reason = stopReason.withLock({ $0 }) { return reason }
        if isCancelled() { return .cancelled }
        guard !overflow, process.terminationStatus == 0 else { return .failed }
        return .success(parse(String(decoding: data, as: UTF8.self)))
    }

    static func folders(binary: String, timeout: TimeInterval = 3.0) -> [Folder]? {
        if case .success(let folders) = fetch(binary: binary, timeout: timeout) { return folders }
        return nil
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
