import AppKit
import CoreServices
import Observation
import OSLog
import UniformTypeIdentifiers

/// Runtime state for Apps (and `z ` folders) inside the clipboard popup. Nothing runs at launch or
/// while the popup is closed, except a lightweight FSEvents watch started on first use of Apps mode
/// (and stopped when the setting is turned off).
@MainActor
@Observable
final class ClipboardLauncherModel {
    static let shared = ClipboardLauncherModel()

    private(set) var catalog = LauncherCatalog.empty
    private(set) var folderCatalog = LauncherCatalog.empty
    private(set) var hasLoadedApps = false
    private(set) var hasLoadedZoxide = false
    private(set) var zoxideInstalled = true
    private(set) var favorites = LauncherFavorites()
    let feedback = ActionFeedback(duration: ActionFeedback.textDuration)

    @ObservationIgnored private var appsDirty = true
    @ObservationIgnored private var scanningApps = false
    @ObservationIgnored private var loadingZoxide = false
    @ObservationIgnored private var favoritesLoaded = false
    @ObservationIgnored private var popupVisible = false
    @ObservationIgnored private var activeMode: ClipboardPopupMode = .clipboard
    @ObservationIgnored private var watcher: AppDirectoryWatcher?
    @ObservationIgnored private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    @ObservationIgnored private var pendingIcons: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var cachedFolderIcon: NSImage?
    @ObservationIgnored private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "Launcher")

    private init() {}

    static var favoritesURL: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Launcher/favorites.json")
    }

    static var appCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(ScreendropStorage.directoryName)/launcher-apps.json")
    }

    var folderIcon: NSImage {
        if let cachedFolderIcon { return cachedFolderIcon }
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 28, height: 28)
        cachedFolderIcon = icon
        return icon
    }

    // MARK: - Lifecycle

    func modeDidActivate(_ mode: ClipboardPopupMode) {
        popupVisible = true
        activeMode = mode
        if mode == .apps {
            activateApps()
            refreshZoxide()
        }
    }

    func popupClosed() {
        popupVisible = false
        activeMode = .clipboard
    }

    /// Stops watching app folders and releases cached data when the setting is turned off.
    func stopAndClear() {
        watcher?.stop()
        watcher = nil
        popupVisible = false
        activeMode = .clipboard
        catalog = .empty
        folderCatalog = .empty
        hasLoadedApps = false
        hasLoadedZoxide = false
        zoxideInstalled = true
        appsDirty = true
        iconCache.removeAllObjects()
        for task in pendingIcons.values { task.cancel() }
        pendingIcons.removeAll()
    }

    // MARK: - Querying

    func sections(query: String) -> [LauncherSection] {
        LauncherList.sections(query: query, apps: catalog, folders: folderCatalog, favorites: favorites)
    }

    // MARK: - Scanning & FSEvents

    private func activateApps() {
        if !favoritesLoaded {
            favorites = LauncherFavorites.load(Self.favoritesURL)
            favoritesLoaded = true
        }
        if !hasLoadedApps, let cacheURL = Self.appCacheURL, let cached = LauncherStore.loadApps(cacheURL), !cached.isEmpty {
            catalog = LauncherCatalog(cached)
        }
        startWatcherIfNeeded()
        if !hasLoadedApps || appsDirty {
            scanApps()
        }
    }

    private func startWatcherIfNeeded() {
        guard watcher == nil else { return }
        let paths = LauncherAppScanner.defaultRoots().map(\.path)
        watcher = AppDirectoryWatcher(paths: paths) { [weak self] in
            guard let self else { return }
            self.appsDirty = true
            // Only rescan immediately if the user is looking at Apps right now; while closed, do zero work.
            if self.popupVisible, self.activeMode == .apps {
                self.scanApps()
            }
        }
    }

    private func scanApps() {
        guard !scanningApps else { return }
        scanningApps = true
        appsDirty = false
        let current = catalog.apps
        let cacheURL = Self.appCacheURL
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = LauncherCatalog(LauncherAppScanner.scan())
            let changed = fresh.apps != current
            if changed, let cacheURL {
                do { try LauncherStore.write(fresh.apps, to: cacheURL) } catch {
                    self.logger.error("Couldn't save launcher app cache: \(String(describing: error), privacy: .public)")
                }
            }
            Task { @MainActor in
                let model = ClipboardLauncherModel.shared
                model.scanningApps = false
                if changed {
                    model.catalog = fresh
                }
                model.hasLoadedApps = true
                if model.appsDirty, model.popupVisible, model.activeMode == .apps {
                    model.scanApps()
                }
            }
        }
    }

    private func refreshZoxide() {
        guard !loadingZoxide else { return }
        guard let binary = Zoxide.binary(in: Zoxide.defaultCandidates()) else {
            zoxideInstalled = false
            if folderCatalog.count > 0 { folderCatalog = .empty }
            hasLoadedZoxide = true
            return
        }
        zoxideInstalled = true
        loadingZoxide = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = Zoxide.folders(binary: binary).map { Zoxide.catalog(Zoxide.existing($0)) }
            Task { @MainActor in
                let model = ClipboardLauncherModel.shared
                model.loadingZoxide = false
                model.hasLoadedZoxide = true
                if let fresh, fresh.apps != model.folderCatalog.apps {
                    model.folderCatalog = fresh
                }
            }
        }
    }

    // MARK: - Lazy Icons

    func cachedIcon(for path: String) -> NSImage? {
        iconCache.object(forKey: path as NSString)
    }

    func loadIcon(for path: String) async -> NSImage? {
        if let cached = iconCache.object(forKey: path as NSString) { return cached }
        if let existing = pendingIcons[path] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            let resolved = (path as NSString).resolvingSymlinksInPath
            let icon = NSWorkspace.shared.icon(forFile: resolved)
            var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
            return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        let mainTask = Task<NSImage?, Never> {
            guard let bitmap = await task.value else { return nil }
            let image = NSImage(cgImage: bitmap, size: NSSize(width: 28, height: 28))
            iconCache.setObject(image, forKey: path as NSString)
            return image
        }
        pendingIcons[path] = mainTask
        let result = await mainTask.value
        pendingIcons[path] = nil
        return result
    }

    // MARK: - Actions

    @discardableResult
    func toggleFavorite(_ path: String) -> Bool {
        if !favoritesLoaded {
            favorites = LauncherFavorites.load(Self.favoritesURL)
            favoritesLoaded = true
        }
        let pinned = favorites.toggle(path)
        do {
            try favorites.save(Self.favoritesURL)
        } catch {
            logger.error("Couldn't save launcher favorites: \(String(describing: error), privacy: .public)")
        }
        return pinned
    }

    func openApp(at path: String, revealInFinder: Bool) {
        let url = URL(fileURLWithPath: path)
        if revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if let error {
                Task { @MainActor in
                    ClipboardLauncherModel.shared.logger.error("Couldn't open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let app, !app.isActive else { return }
            app.activate(from: .current, options: [])
        }
    }

    func openFolder(at path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let finderID = "com.apple.finder"
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: finderID)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: finderURL, configuration: config) { _, error in
            if let error {
                Task { @MainActor in
                    ClipboardLauncherModel.shared.logger.error("Couldn't open folder in Finder: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        feedback.show("Copied path")
    }
}

/// Coalesced directory-level FSEvents watcher for `/Applications`, `/System/Applications`, and `~/Applications`.
@MainActor
private final class AppDirectoryWatcher {
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(paths: [String], onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AppDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if FSEventStreamStart(stream) {
            self.stream = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
