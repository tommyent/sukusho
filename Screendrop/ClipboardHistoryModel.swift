import AppKit
import ApplicationServices
import Observation
import OSLog
import SwiftUI

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
    /// The Library page's type filter.
    var libraryFilter: ClipboardFilter = .all
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
                entries = presented(loaded)
                ClipboardDescriber.shared.update(loaded, store: store)
            } catch {
                logger.error("Clipboard history can't be read: \(String(describing: error), privacy: .public)")
            }
            hasLoaded = true
        }
    }

    /// The names shown: the model's while its Settings switch is on (stored, and back when it's on again),
    /// and for an image that is a Library capture, the name the Library gives it.
    private func presented(_ loaded: [ClipboardEntry]) -> [ClipboardEntry] {
        let usesModel = ScreendropPreferences.libraryUsesIntelligence
        let captures = Dictionary(CaptureLibraryModel.shared.items.map { ($0.fileURL.standardizedFileURL.path, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return loaded.map { entry in
            var entry = entry
            if !usesModel {
                entry.modelTitle = nil
                entry.keywords = []
                entry.category = nil
            }
            if let path = entry.libraryPath, let capture = captures[URL(fileURLWithPath: path).standardizedFileURL.path] {
                entry.modelTitle = capture.customName ?? capture.modelTitle
            }
            return entry
        }
    }

    func popupWillOpen() {
        popupOpenings += 1
        refresh()
    }

    func sections(filter: ClipboardFilter, query: String) -> [ClipboardList.Section] {
        ClipboardList.sections(entries, filter: filter, query: CaptureLibraryQuery(query), appName: appName)
    }

    /// What the Library's Clipboard page shows; the status bar counts the same.
    func librarySections(query: String) -> [ClipboardList.Section] {
        sections(filter: showsSnippets ? .snippets : libraryFilter, query: query)
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

    // MARK: - Quick Look

    /// What Quick Look shows for an entry. It previews files only: an image or copied files are shown as
    /// they are; text and colors are written out for it, in a folder per entry so titles never collide.
    func quickLookURLs(for entry: ClipboardEntry) -> [URL] {
        switch entry.kind {
        case .image:
            return entry.imageFileURL.map { [$0] } ?? []
        case .files:
            return entry.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        case .text, .snippet:
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Clipboard Quick Look/\(entry.id)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if case .color(let hex) = ClipboardList.textForm(of: entry), let png = Self.swatch(hex) {
                let url = folder.appendingPathComponent("\(hex.dropFirst()).png")
                return (try? png.write(to: url, options: .atomic)).map { [url] } ?? []
            }
            let name = String(ClipboardList.title(of: entry).prefix(60))
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent((name.isEmpty ? "Text" : name) + ".txt")
            return (try? Data((entry.text ?? "").utf8).write(to: url, options: .atomic)).map { [url] } ?? []
        }
    }

    /// Opens Quick Look on an entry, or closes it when it already shows that entry, as Space does in Finder.
    func quickLook(_ entry: ClipboardEntry) {
        let urls = quickLookURLs(for: entry)
        guard let first = urls.first else { return }
        if QuickLookPreviewPresenter.isShown,
           QuickLookPreviewPresenter.currentURL?.standardizedFileURL == first.standardizedFileURL {
            QuickLookPreviewPresenter.dismiss()
            return
        }
        QuickLookPreviewPresenter.show(urls: urls)
    }

    /// A 512 px square of the color, as a PNG.
    private static func swatch(_ hex: String) -> Data? {
        guard let color = Color(clipboardHex: hex).map(NSColor.init)?.usingColorSpace(.sRGB),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A copied image becomes an ordinary capture, with its source app. Returns the capture's file.
    @discardableResult
    func addToLibrary(_ entry: ClipboardEntry, announcing: Bool = true) -> URL? {
        guard entry.kind == .image, entry.libraryPath == nil, let url = entry.imageURL else { return nil }
        // An app this Mac doesn't have stays unnamed rather than showing its bundle ID.
        let source = appName(entry.sourceBundleID).map { CaptureSource(bundleIdentifier: entry.sourceBundleID, appName: $0) }
        let added = ScreenshotHistoryStore.shared.importScreenshot(from: url, source: source)
        Task {
            try? await store?.linkToLibrary(entry.id, path: added.path)
            refresh()
        }
        if announcing { feedback.show("Added to the Library") }
        return added
    }

    /// Opens an image entry in the editor. The editor works on Library captures, saving its edits beside the
    /// capture, so a copy that isn't one yet is added to the Library first, as Add to Library does.
    func openInEditor(_ entry: ClipboardEntry) {
        guard entry.kind == .image else { return }
        let capture = entry.libraryPath.map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? addToLibrary(entry, announcing: false)
        guard let capture else { return }
        QuickLookPreviewPresenter.dismiss()
        PreviewPanelPresenter.shared.onAnnotate?(capture)
    }
}
