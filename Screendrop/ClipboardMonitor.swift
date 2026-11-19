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
    /// How many times in a row the pasteboard was read empty; see `finish`.
    private var emptyRereads = 0
    private static let maxEmptyRereads = 4
    private var readToken = 0
    private var isReading = false
    /// The latest pasteboard change history is done with: read, then recorded or left out.
    private var settledChangeCount = 0
    private var defaultsObserver: NSObjectProtocol?
    private var lastHistoryEnabled: Bool?
    private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "Clipboard")

    private init() {}

    static var directory: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Clipboard", isDirectory: true)
    }

    /// Waits until history is done with the pasteboard's change `count`, so a write that follows it at once
    /// can't hide it: a poll that came after both would read only the second. At most `limit`, and not at
    /// all while history is off.
    func settled(through count: Int, limit: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let end = clock.now + limit
        while isRunning, settledChangeCount < count, clock.now < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle(_ count: Int) {
        settledChangeCount = max(settledChangeCount, count)
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
        let enabled = ScreendropPreferences.clipboardHistoryEnabled
        guard enabled != lastHistoryEnabled else { return }
        lastHistoryEnabled = enabled
        enabled ? start() : stop()
    }

    private func start() {
        guard !isRunning else { return }
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
        ClipboardHistoryModel.shared.refresh()
        HotkeyManager.shared.reloadHotkeys()
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
        ClipboardHistoryModel.shared.refresh()
        HotkeyManager.shared.reloadHotkeys()
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
            settle(count)
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
            Task { @MainActor in ClipboardMonitor.shared.finish(result.outcome, types: result.types, token: token, count: count) }
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

    private func finish(_ outcome: ClipboardPasteboardReader.Outcome, types: [String], token: Int, count: Int) {
        guard token == readToken, isReading else { return }
        isReading = false
        if !types.isEmpty { emptyRereads = 0 }
        if UserDefaults.standard.bool(forKey: ScreendropPreferences.clipboardTraceKey) {
            logger.notice("Clipboard copy: \(String(describing: outcome.trace), privacy: .public) types \(types.joined(separator: ","), privacy: .public)")
        }
        switch outcome {
        case .captured(let capture):
            guard let store else { return settle(count) }
            Task {
                do { try await store.record(capture); ClipboardHistoryModel.shared.refresh() } catch {
                    logger.error("Clipboard history can't save a copy: \(String(describing: error), privacy: .public)")
                }
                settle(count)
            }
        case .skipped(.ownWrite):
            settle(count)
        case .skipped(.nothingKept) where types.isEmpty && emptyRereads < Self.maxEmptyRereads:
            // Read between an app's clearContents and its write: the write doesn't change the count again,
            // so look once more on the next polls, or that copy is lost (seen in the VM, 2026-11-16).
            emptyRereads += 1
            lastChangeCount = -1
            return
        case .skipped:
            emptyRereads = 0
            skippedCount += 1
            settle(count)
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
            do {
                // Quick Look's copies of what the sweep dropped go too (Astra, 2026-11-16).
                if try await store.sweep(retention: retention, maxBytes: maxBytes) > 0 { ClipboardHistoryModel.clearQuickLookFiles() }
                ClipboardHistoryModel.clearEditCopies()
            } catch {
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
