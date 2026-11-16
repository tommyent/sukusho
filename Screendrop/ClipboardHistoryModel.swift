import AppKit
import ApplicationServices
import Observation
import OSLog

/// Clipboard history as the popup and the Library's Clipboard page show it,
/// and what they do with an entry.
@MainActor
@Observable
final class ClipboardHistoryModel {
    static let shared = ClipboardHistoryModel()

    private(set) var entries: [ClipboardEntry] = []
    private(set) var hasLoaded = false
    /// The Library shows its Clipboard page; `showsSnippets` picks Snippets over History.
    var isShown = false
    var showsSnippets = false
    /// The Library page's selected entry.
    var librarySelection: ClipboardEntry.ID?
    /// Bumped each time the popup opens, so it starts from a clean search.
    private(set) var popupOpenings = 0
    let feedback = ActionFeedback(duration: ActionFeedback.textDuration)

    @ObservationIgnored private var appNames: [String: String] = [:]
    @ObservationIgnored private var appIcons: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "Clipboard")

    private init() {}

    private var store: ClipboardHistoryStore? { ClipboardMonitor.shared.store }

    func refresh() {
        guard let store else {
            entries = []
            hasLoaded = true
            return
        }
        loading?.cancel()
        loading = Task {
            do {
                let loaded = try await store.entries(limit: 3000)
                guard !Task.isCancelled else { return }
                entries = loaded
            } catch {
                logger.error("Clipboard history can't be read: \(String(describing: error), privacy: .public)")
            }
            hasLoaded = true
        }
    }

    func popupWillOpen() {
        popupOpenings += 1
        refresh()
    }

    func sections(filter: ClipboardFilter, query: String) -> [ClipboardList.Section] {
        ClipboardList.sections(entries, filter: filter, query: CaptureLibraryQuery(query), appName: appName)
    }

    var historyCount: Int { entries.count { $0.kind != .snippet } }
    var snippetCount: Int { entries.count { $0.kind == .snippet } }

    func entry(_ id: ClipboardEntry.ID?) -> ClipboardEntry? {
        id.flatMap { id in entries.first { $0.id == id } }
    }

    // MARK: - Apps

    /// Nil when the app isn't on this Mac; the Information block then leaves Source out.
    func appName(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let name = appNames[bundleID] { return name.isEmpty ? nil : name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
        appNames[bundleID] = name
        return name.isEmpty ? nil : name
    }

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        if let icon = appIcons[bundleID] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    // MARK: - Actions

    enum Delivery {
        /// Into the app that was in front, or onto the clipboard when Sukusho may not type ⌘V.
        case paste
        case copy
        /// Text only, no formatting.
        case pastePlain
        /// Text only, onto the clipboard.
        case copyPlain

        var isPlain: Bool { self == .pastePlain || self == .copyPlain }
        var isCopy: Bool { self == .copy || self == .copyPlain }
    }

    /// Puts `entry` on the clipboard and, for a paste, types ⌘V into `target`.
    /// `beforePaste` hides the popup first, so the target gets the keystroke.
    func deliver(_ entry: ClipboardEntry, as delivery: Delivery, to target: NSRunningApplication?,
                 beforePaste: @escaping () -> Void = {}) {
        Task {
            let richText = delivery.isPlain ? [:] : ((try? await store?.richText(for: entry.id)) ?? [:])
            guard ClipboardWriter.write(entry, richText: richText, plain: delivery.isPlain) else {
                feedback.show("This entry's file is gone")
                return
            }
            if let store { try? await store.touch(entry.id) }
            refresh()
            guard !delivery.isCopy else {
                feedback.show("Copied")
                return
            }
            guard AXIsProcessTrusted() else {
                // Without Accessibility a paste can't be typed; the entry waits on the clipboard.
                feedback.show("Copied. To paste directly, allow Sukusho in Accessibility.")
                return
            }
            beforePaste()
            if let target, target != NSRunningApplication.current { target.activate() }
            // shortcut: a fixed 0.15 s lets the target take focus before ⌘V; wait for its activation if pastes go astray.
            try? await Task.sleep(for: .milliseconds(150))
            ClipboardWriter.typeCommandV()
        }
    }

    func togglePin(_ entry: ClipboardEntry) {
        Task {
            try? await store?.setPinned(entry.id, entry.pinnedAt == nil)
            refresh()
        }
    }

    func delete(_ entry: ClipboardEntry) {
        Task {
            try? await store?.delete(entry.id)
            if librarySelection == entry.id { librarySelection = nil }
            refresh()
        }
    }

    func deleteHistory() {
        Task {
            try? await store?.deleteHistory()
            librarySelection = nil
            refresh()
        }
    }

    @discardableResult
    func addSnippet(title: String = "", text: String = "") async -> String? {
        guard let store else { return nil }
        let id = try? await store.addSnippet(title: title, text: text)
        refresh()
        return id
    }

    func saveAsSnippet(_ entry: ClipboardEntry) {
        guard let text = entry.text else { return }
        Task {
            let id = await addSnippet(title: ClipboardList.title(of: entry), text: text)
            feedback.show(id == nil ? "Couldn't save the snippet" : "Saved as a snippet")
        }
    }

    func updateSnippet(_ id: String, title: String, text: String) {
        Task {
            try? await store?.updateSnippet(id, title: title, text: text)
            refresh()
        }
    }

    /// A copied image becomes an ordinary capture, with its source app.
    func addToLibrary(_ entry: ClipboardEntry) {
        guard entry.kind == .image, entry.libraryPath == nil, let url = entry.imageURL else { return }
        // An app this Mac doesn't have stays unnamed rather than showing its bundle ID.
        let source = appName(entry.sourceBundleID).map { CaptureSource(bundleIdentifier: entry.sourceBundleID, appName: $0) }
        let added = ScreenshotHistoryStore.shared.importScreenshot(from: url, source: source)
        Task {
            try? await store?.linkToLibrary(entry.id, path: added.path)
            refresh()
        }
        feedback.show("Added to the Library")
    }
}
