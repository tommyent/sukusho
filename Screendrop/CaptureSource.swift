import AppKit
import CoreGraphics

/// The app, and when known the window, a capture was taken from. Stored with
/// the capture, because it can't be recovered from the pixels afterwards.
/// Window titles can be private: this stays on this Mac, never in uploads.
nonisolated struct CaptureSource: Codable, Sendable, Hashable {
    var bundleIdentifier: String?
    var appName: String
    var windowTitle: String?

    /// For `app:`: the app's name, or the last part of its bundle ID, contains
    /// `folded` (already case- and accent-folded).
    func matchesApp(_ folded: String) -> Bool {
        let lastPart = bundleIdentifier?.split(separator: ".").last.map(String.init) ?? ""
        return [appName, lastPart].contains { CaptureLibraryQuery.fold($0).contains(folded) }
    }
}

/// Works out where a screenshot came from. `screencapture` hands back pixels
/// only, so the probe snapshots the on-screen windows before the capture
/// starts and watches the pointer while the user picks a window or draws an
/// area. Global mouse monitors need no Accessibility permission, and window
/// titles are readable because the app already holds Screen Recording.
/// Adapted from upstream Screendrop (CC0).
@MainActor
final class CaptureSourceProbe {
    enum Target {
        /// The whole display: the frontmost app, else the topmost window on it.
        case display(CGDirectDisplayID?)
        /// The window under the click that picked it.
        case window
        /// The window under the middle of the drawn area.
        case area
    }

    private struct Window {
        let pid: pid_t
        let ownerName: String
        let title: String?
        /// Global display coordinates, top-left origin (Quartz space).
        let bounds: CGRect
    }

    /// Front to back, as the window server reports them.
    private let windows: [Window]
    private let frontmostPID: pid_t?
    private var pressedAt: CGPoint?
    private var releasedAt: CGPoint?
    private var monitor: Any?

    /// Snapshots the windows now. `tracksPointer` also watches the pointer
    /// for interactive window and area picks.
    init(tracksPointer: Bool) {
        windows = Self.onScreenWindows()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        frontmostPID = frontmost == getpid() ? nil : frontmost
        guard tracksPointer else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let location = Self.quartzPoint(NSEvent.mouseLocation)
            let isPress = event.type == .leftMouseDown
            MainActor.assumeIsolated {
                guard let self else { return }
                if isPress { self.pressedAt = location } else { self.releasedAt = location }
            }
        }
    }

    /// Stops watching the pointer and names the source, if any window fits.
    /// Call it on every path, a cancelled capture included, so the monitor
    /// never outlives the capture.
    func finish(_ target: Target) -> CaptureSource? {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let window: Window?
        switch target {
        case .display(let displayID):
            let screen = displayID.map(CGDisplayBounds) ?? .infinite
            let onDisplay = windows.filter { $0.bounds.intersects(screen) }
            window = onDisplay.first { $0.pid == frontmostPID } ?? onDisplay.first
        case .window:
            window = topmostWindow(at: releasedAt ?? Self.quartzPoint(NSEvent.mouseLocation))
        case .area:
            if let pressedAt, let releasedAt {
                let area = CGRect(origin: pressedAt, size: .zero).union(CGRect(origin: releasedAt, size: .zero))
                window = topmostWindow(at: CGPoint(x: area.midX, y: area.midY))
                    ?? windows.max { $0.bounds.intersection(area).area < $1.bounds.intersection(area).area }
                        .flatMap { $0.bounds.intersects(area) ? $0 : nil }
            } else {
                window = topmostWindow(at: releasedAt ?? Self.quartzPoint(NSEvent.mouseLocation))
            }
        }
        guard let window else { return nil }
        let app = NSRunningApplication(processIdentifier: window.pid)
        return CaptureSource(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName ?? window.ownerName,
            windowTitle: window.title
        )
    }

    private func topmostWindow(at point: CGPoint) -> Window? {
        windows.first { $0.bounds.contains(point) }
    }

    /// Ordinary app windows only: layer 0, visible, not this app's own
    /// panels and not the system's capture overlays.
    private static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        let ignoredOwners: Set<String> = ["Window Server", "Dock", "screencapture", "Screenshot", "Control Center"]
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard !ignoredOwners.contains(owner) else { return nil }
            let title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Window(pid: pid, ownerName: owner, title: title?.isEmpty == false ? title : nil, bounds: bounds)
        }
    }

    /// AppKit's global space is bottom-left at the primary display; Quartz
    /// window bounds are top-left.
    private nonisolated static func quartzPoint(_ point: NSPoint) -> CGPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

private extension CGRect {
    nonisolated var area: CGFloat { isNull ? 0 : width * height }
}
