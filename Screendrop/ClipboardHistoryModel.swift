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
    /// A snippet just made with New Snippet, whose editor takes the keyboard so typing goes into it (Astra R3).
    var snippetAwaitingFocus: ClipboardEntry.ID?
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

    func sections(filter: ClipboardFilter, query: String, includesSnippets: Bool = false) -> [ClipboardList.Section] {
        ClipboardList.sections(entries, filter: filter, query: CaptureLibraryQuery(query), includesSnippets: includesSnippets,
                               appName: appName)
    }

    /// What the Library's Clipboard page shows; the status bar counts the same.
    func librarySections(query: String) -> [ClipboardList.Section] {
        sections(filter: showsSnippets ? .snippets : libraryFilter, query: query)
    }

    var historyCount: Int { entries.count { $0.kind != .snippet } }
    var snippetCount: Int { entries.count { $0.kind == .snippet } }
    var savedCount: Int { entries.count { $0.kind != .snippet && $0.pinnedAt != nil } }

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

    /// The card as it was at an earlier version: that version's image and Library link, for Copy and Quick Look.
    func entry(_ entry: ClipboardEntry, at version: ClipboardEntryVersion) -> ClipboardEntry {
        var earlier = entry
        earlier.imageURL = version.imageURL
        earlier.libraryPath = version.libraryPath
        earlier.byteSize = version.byteSize
        earlier.hash = version.hash
        earlier.earlierVersions = []
        return earlier
    }

    /// Save (★) keeps a copy in Library › Saved, never aged out or swept, and out of Delete History. It's the
    /// store's pinned flag, so clips pinned before option A are saved (sd-ogtp.1.1).
    func toggleSaved(_ entry: ClipboardEntry) {
        Task {
            try? await store?.setPinned(entry.id, entry.pinnedAt == nil)
            refresh()
        }
    }

    func delete(_ entry: ClipboardEntry) {
        Self.clearQuickLookFiles()
        Task {
            try? await store?.delete(entry.id)
            if librarySelection == entry.id { librarySelection = nil }
            refresh()
        }
    }

    func deleteHistory() {
        Self.clearQuickLookFiles()
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

    /// New Snippet, from the bar or the empty page: makes one, selects it and puts the keyboard in its text.
    func newSnippet() async {
        guard let id = await addSnippet() else { return }
        snippetAwaitingFocus = id
        librarySelection = id
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
        // Per version too: a link made for the original must not show again for the newer version stacked on it.
        let folder = Self.quickLookFolder.appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(String(entry.hash.prefix(16)), isDirectory: true)
        let name = String(ClipboardList.title(of: entry).prefix(60))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        switch entry.kind {
        case .image:
            guard let url = entry.imageFileURL else { return [] }
            // A Library capture's own name is shown as it is. History keeps images under their hash, which
            // Quick Look would put in its title bar: a link named after the entry shows its title instead.
            guard entry.libraryPath == nil else { return [url] }
            let named = folder.appendingPathComponent((name.isEmpty ? "Image" : name) + "." + url.pathExtension)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: named.path) { try? FileManager.default.linkItem(at: url, to: named) }
            return [FileManager.default.fileExists(atPath: named.path) ? named : url]
        case .files:
            return entry.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        case .text, .snippet:
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if case .color(let hex) = ClipboardList.textForm(of: entry), let png = Self.swatch(hex) {
                let url = folder.appendingPathComponent("\(hex.dropFirst()).png")
                return (try? png.write(to: url, options: .atomic)).map { [url] } ?? []
            }
            let url = folder.appendingPathComponent((name.isEmpty ? "Text" : name) + ".txt")
            return (try? Data((entry.text ?? "").utf8).write(to: url, options: .atomic)).map { [url] } ?? []
        }
    }

    /// Opens Quick Look on an entry, or closes it when it already shows that entry, as Space does in Finder.
    func quickLook(_ entry: ClipboardEntry) {
        // Only the entry being looked at keeps files here, so a deleted copy doesn't linger in them.
        if !QuickLookPreviewPresenter.isShown { Self.clearQuickLookFiles() }
        let urls = quickLookURLs(for: entry)
        guard let first = urls.first else { return }
        if QuickLookPreviewPresenter.isShown,
           QuickLookPreviewPresenter.currentURL?.standardizedFileURL == first.standardizedFileURL {
            QuickLookPreviewPresenter.dismiss()
            return
        }
        QuickLookPreviewPresenter.show(urls: urls)
    }

    private static let quickLookFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Clipboard Quick Look", isDirectory: true)

    /// The files written for Quick Look hold copies' contents; they go with the copies, deleted by the user or
    /// dropped by the retention sweep.
    static func clearQuickLookFiles() {
        try? FileManager.default.removeItem(at: quickLookFolder)
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

    /// Opens an image entry in the editor. A copy that's a capture opens as that capture. Any other opens as a copy
    /// outside the Library, which becomes a capture only on its first saved edit, dated when it was copied and
    /// credited to its app, and the clip is linked to it then (Fable #5: opening alone added it to the Library, dated
    /// the moment Edit was clicked).
    func openInEditor(_ entry: ClipboardEntry) {
        guard entry.kind == .image else { return }
        if let capture = entry.libraryPath.map({ URL(fileURLWithPath: $0) }),
           FileManager.default.fileExists(atPath: capture.path) {
            return open(capture)
        }
        // Only a copy that was nothing but a link to a capture since deleted has nothing left to open.
        guard let image = entry.imageURL, let copy = editableCopy(of: entry, from: image) else {
            return feedback.show("This image's capture is no longer in the Library.")
        }
        let source = appName(entry.sourceBundleID).map { CaptureSource(bundleIdentifier: entry.sourceBundleID, appName: $0) }
        let entryID = entry.id
        ScreenshotHistoryStore.shared.registerPendingImport(.init(createdAt: entry.firstCopiedAt, source: source, title: nil) { [weak self] capture in
            Task {
                try? await self?.store?.linkToLibrary(entryID, path: capture.path)
                self?.refresh()
            }
        }, for: copy)
        open(copy)
    }

    private func open(_ image: URL) {
        QuickLookPreviewPresenter.dismiss()
        PreviewPanelPresenter.shared.onAnnotate?(image)
    }

    private static let editFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Clipboard Edits", isDirectory: true)

    /// A copy of a clip's image to edit, named as the clip is so the editor's title says what it is. History's own
    /// blob is never edited in place.
    private func editableCopy(of entry: ClipboardEntry, from image: URL) -> URL? {
        let folder = Self.editFolder.appendingPathComponent(entry.id, isDirectory: true)
        let name = String(ClipboardList.title(of: entry).prefix(60))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let copy = folder.appendingPathComponent((name.isEmpty ? "Clipboard image" : name) + "." + image.pathExtension)
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: image, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}
