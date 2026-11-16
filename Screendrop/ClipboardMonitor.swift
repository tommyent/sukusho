import AppKit
import OSLog

/// Watches the general pasteboard while clipboard history is on, and files
/// each copy in `ClipboardHistoryStore`. NSPasteboard has no change
/// notification, so it compares `changeCount` every half second.
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private(set) var isRunning = false
    /// Copies left out by the privacy rules since launch, for the "1 skipped" note.
    private(set) var skippedCount = 0
    /// macOS doesn't let Sukusho read other apps' copies yet; history waits.
    private(set) var needsAccess = false
    private(set) var store: ClipboardHistoryStore?

    private var pollTimer: Timer?
    private var sweepTimer: Timer?
    private var lastChangeCount = 0
    private var readToken = 0
    private var isReading = false
    private var defaultsObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "Clipboard")

    private init() {}

    static var directory: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Clipboard", isDirectory: true)
    }

    /// Starts or stops with the setting. Called at launch; follows later changes itself.
    func update() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ClipboardMonitor.shared.update() }
            }
        }
        ScreendropPreferences.clipboardHistoryEnabled ? start() : stop()
    }

    private func start() {
        guard !isRunning else { return }
        // Set first: making the device ID writes a default, which calls update() again.
        isRunning = true
        do {
            store = try ClipboardHistoryStore(directory: Self.directory, deviceID: ScreendropPreferences.clipboardDeviceID)
        } catch {
            logger.error("Clipboard history can't open its store: \(String(describing: error), privacy: .public)")
            isRunning = false
            return
        }
        // What was copied before history was turned on isn't kept.
        lastChangeCount = NSPasteboard.general.changeCount
        let poll = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.poll() }
        }
        poll.tolerance = 0.1
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        let sweep = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.sweep() }
        }
        sweep.tolerance = 300
        RunLoop.main.add(sweep, forMode: .common)
        sweepTimer = sweep
        self.sweep()
    }

    private func stop() {
        guard isRunning else { return }
        pollTimer?.invalidate()
        sweepTimer?.invalidate()
        pollTimer = nil
        sweepTimer = nil
        store = nil
        isRunning = false
        isReading = false
        readToken += 1
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount, !isReading else { return }
        lastChangeCount = count
        // Apple: reading another app's copy asks the user unless Sukusho has
        // Always Allow. macOS 27.3 reports alwaysAllow for every app (probe,
        // 2026-11-16); anything else waits for onboarding rather than asking per copy.
        guard pasteboard.accessBehavior == .alwaysAllow else {
            needsAccess = true
            return
        }
        needsAccess = false
        readToken += 1
        isReading = true
        let token = readToken
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ignoredApps = Set(ScreendropPreferences.clipboardIgnoredApps)
        let historyDirectory = ScreenshotHistoryStore.historyDirectory
        DispatchQueue.global(qos: .utility).async {
            let result = ClipboardPasteboardReader.read(
                .general, changeCount: count, frontmostBundleID: frontmost,
                ignoredApps: ignoredApps, historyDirectory: historyDirectory)
            Task { @MainActor in ClipboardMonitor.shared.finish(result.outcome, types: result.types, token: token) }
        }
        // An app that promised data and hung holds only its own read; after 2 s
        // the next copy gets a read of its own and this one's result is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { ClipboardMonitor.shared.abandon(token) }
        }
    }

    private func abandon(_ token: Int) {
        guard token == readToken, isReading else { return }
        isReading = false
        readToken += 1
        logger.notice("Clipboard read took over 2 s; that copy is skipped")
    }

    private func finish(_ outcome: ClipboardPasteboardReader.Outcome, types: [String], token: Int) {
        guard token == readToken, isReading else { return }
        isReading = false
        if UserDefaults.standard.bool(forKey: ScreendropPreferences.clipboardTraceKey) {
            logger.notice("Clipboard copy: \(String(describing: outcome.trace), privacy: .public) types \(types.joined(separator: ","), privacy: .public)")
        }
        switch outcome {
        case .captured(let capture):
            guard let store else { return }
            Task {
                do { try await store.record(capture) } catch {
                    logger.error("Clipboard history can't save a copy: \(String(describing: error), privacy: .public)")
                }
            }
        case .skipped(.ownWrite):
            break
        case .skipped:
            skippedCount += 1
        case .changed:
            // Read again on the next poll: the copy that replaced it is the one to keep.
            lastChangeCount = -1
        }
    }

    private func sweep() {
        guard let store else { return }
        let retention = ScreendropPreferences.clipboardRetention
        let maxBytes = ScreendropPreferences.clipboardMaxStorageBytes
        Task {
            do { try await store.sweep(retention: retention, maxBytes: maxBytes) } catch {
                logger.error("Clipboard history cleanup failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

private extension ClipboardPasteboardReader.Outcome {
    /// Kind, source and sizes only: the trace never holds what was copied.
    var trace: String {
        switch self {
        case .captured(let capture):
            "\(capture.kind.rawValue) from \(capture.sourceBundleID ?? "?") \(capture.byteSize) bytes"
                + (capture.libraryPath == nil ? "" : " (Library capture)")
        case .skipped(let reason): "skipped: \(reason)"
        case .changed: "changed while read"
        }
    }
}
