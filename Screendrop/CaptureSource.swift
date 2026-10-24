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
        /// A known area, such as an area recording's, in global Quartz coordinates.
        case region(CGRect)
    }

    /// One on-screen window, as the snapshot saw it.
    nonisolated struct Window: Equatable {
        let pid: pid_t
        let ownerName: String
        let title: String?
        /// Global display coordinates, top-left origin (Quartz space).
        let bounds: CGRect
    }

    /// What a capture covered, in global Quartz coordinates.
    nonisolated enum Covered {
        case display(CGRect)
        case point(CGPoint)
        case area(CGRect)
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
        stopMonitoring()
        let covered: Covered
        switch target {
        case .display(let displayID):
            covered = .display(displayID.map(CGDisplayBounds) ?? .infinite)
        case .window:
            // screencapture picks the window under the press.
            covered = .point(pressedAt ?? releasedAt ?? Self.quartzPoint(NSEvent.mouseLocation))
        case .area:
            if let pressedAt, let releasedAt {
                covered = .area(CGRect(origin: pressedAt, size: .zero).union(CGRect(origin: releasedAt, size: .zero)))
            } else {
                covered = .point(releasedAt ?? Self.quartzPoint(NSEvent.mouseLocation))
            }
        case .region(let rect):
            covered = .area(rect)
        }
        guard let window = Self.window(covering: covered, in: windows, frontmostPID: frontmostPID) else { return nil }
        let app = NSRunningApplication(processIdentifier: window.pid)
        return CaptureSource(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName ?? window.ownerName,
            windowTitle: window.title
        )
    }

    /// A probe dropped without `finish` still stops watching the pointer.
    isolated deinit {
        stopMonitoring()
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The window a capture shows, from a front-to-back snapshot: on a
    /// display, the frontmost app's top window there, else the top one; at a
    /// point, the top window under it; for an area, the top window under its
    /// middle, else the one it overlaps most.
    nonisolated static func window(covering covered: Covered, in windows: [Window], frontmostPID: pid_t?) -> Window? {
        switch covered {
        case .display(let screen):
            let onDisplay = windows.filter { $0.bounds.intersects(screen) }
            return onDisplay.first { $0.pid == frontmostPID } ?? onDisplay.first
        case .point(let point):
            return windows.first { $0.bounds.contains(point) }
        case .area(let area):
            return windows.first { $0.bounds.contains(CGPoint(x: area.midX, y: area.midY)) }
                ?? windows.max { $0.bounds.intersection(area).area < $1.bounds.intersection(area).area }
                    .flatMap { $0.bounds.intersects(area) ? $0 : nil }
        }
    }

    /// The area screencapture wrote on its file, in global Quartz points:
    /// Spotlight's kMDItemScreenCaptureGlobalRect, kept as an extended
    /// attribute. Exact where the pointer track ends on the drag's corner,
    /// which a drag just past a window's edge puts on the window behind.
    nonisolated static func capturedRect(of url: URL) -> CGRect? {
        let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, size, 0, 0) }) == size,
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [NSNumber],
              values.count == 4 else { return nil }
        let rect = CGRect(x: values[0].doubleValue, y: values[1].doubleValue,
                          width: values[2].doubleValue, height: values[3].doubleValue)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Ordinary app windows only: layer 0, visible, not the system's capture
    /// overlays. This app's own windows count when captures can see them,
    /// named for what they show; its panels and overlays sit at other levels.
    private static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        let ignoredOwners: Set<String> = ["Window Server", "Dock", "screencapture", "Screenshot", "Control Center"]
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard !ignoredOwners.contains(owner) else { return nil }
            var title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if pid == ownPID, let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
               let window = NSApp.window(withWindowNumber: number) {
                // Hidden from captures (Include app windows off, the default): the capture shows what's behind it.
                guard window.sharingType != .none else { return nil }
                title = ownWindowName(identifier: window.identifier?.rawValue, autosaveName: window.frameAutosaveName) ?? title
            }
            return Window(pid: pid, ownerName: owner, title: title?.isEmpty == false ? title : nil, bounds: bounds)
        }
    }

    /// A plain name for one of this app's own windows, whose titles change
    /// with the tab or the capture shown: the SwiftUI scenes by the scene id
    /// their identifier starts with (the ids in ScreendropApp), Settings by
    /// its frame autosave name. Nil for any other window, which keeps its title.
    nonisolated static func ownWindowName(identifier: String?, autosaveName: String) -> String? {
        if autosaveName == "SettingsWindow" { return "Settings" }
        guard let identifier else { return nil }
        let scenes = ["CAPTURE_LIBRARY": "Library", "ANNOTATION_EDITOR": "Editor", "VIDEO_EDITOR": "Studio"]
        return scenes.first { identifier == $0.key || identifier.hasPrefix($0.key + "-") }?.value
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
