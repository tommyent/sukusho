import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Whether a running recording must change its filter before a private window (the clipboard
/// popup) may appear. A display or area recording that includes Sukusho's windows captures any new
/// window of the app unless the filter names it; a window recording captures only its window, and a
/// recording that leaves the whole app out needs nothing (Sol, CVR-2).
nonisolated struct PrivateWindowCoverage: Equatable {
    var recordsDisplay: Bool
    var includesAppWindows: Bool
    var excludedIDs: Set<CGWindowID>

    func needsFilterUpdate(for windowID: CGWindowID) -> Bool {
        recordsDisplay && includesAppWindows && !excludedIDs.contains(windowID)
    }
}

/// One request to leave a private window out of whatever recording is running, sequenced so it can
/// only ever change the filter of the take it was checked against (Sol, CVR2-1).
@MainActor
enum PrivateWindowExclusion {
    /// A running take as the request sees it: its id (new for every take) and the coverage its
    /// installed filter has, nil until that filter is running.
    struct Take: Equatable {
        let id: Int
        let coverage: PrivateWindowCoverage?
    }

    /// True when the window may be shown: no take is running, the running take can't see it, or its
    /// filter now names it. `current` reads the running take; `update` rebuilds and installs that
    /// take's filter naming the window and must refuse (false) if its take is no longer current;
    /// `covered` records the success on that take. A take that changed while `update` waited is
    /// tried afresh; a take whose coverage isn't known yet fails closed.
    static func request(windowID: CGWindowID, current: () -> Take?, update: (Take) async -> Bool,
                        covered: (Take) -> Void, attempts: Int = 3) async -> Bool {
        for _ in 0..<attempts {
            guard let take = current() else { return true }
            guard let coverage = take.coverage else { return false }
            guard coverage.needsFilterUpdate(for: windowID) else { return true }
            let updated = await update(take)
            // Whatever happened, it counts only for the take that is still running.
            guard current()?.id == take.id else { continue }
            guard updated else { return false }
            covered(take)
            return true
        }
        return false
    }
}

nonisolated struct RecordingDesktopFilter {
    let cleanDesktop: Bool
    let excludedApplications: [SCRunningApplication]
    let excludedWindows: [SCWindow]

    /// `overlayWindowIDs` are the app's own windows that Studio redraws
    /// from data, the camera bubble and the recording pen, so the capture
    /// always leaves them out.
    init(content: SCShareableContent, includesAppWindows: Bool, cleanDesktop: Bool,
         overlayWindowIDs: Set<CGWindowID> = []) {
        self.cleanDesktop = cleanDesktop
        excludedApplications = content.applications.filter {
            Self.excludesApplication(
                bundleIdentifier: $0.bundleIdentifier,
                ownBundleIdentifier: Bundle.main.bundleIdentifier,
                includesAppWindows: includesAppWindows,
                cleanDesktop: cleanDesktop
            )
        }
        excludedWindows = content.windows.filter {
            Self.excludesWindow(
                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                layer: $0.windowLayer,
                cleanDesktop: cleanDesktop,
                windowID: $0.windowID,
                overlayWindowIDs: overlayWindowIDs,
                includesAppWindows: includesAppWindows
            )
        }
    }

    func makeFilter(for display: SCDisplay) -> SCContentFilter {
        // shortcut: Dock, Notification Center or Finder restarts aren't re-excluded until the next recording; revisit if live updates are needed.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: excludedWindows
        )
        filter.includeMenuBar = !cleanDesktop
        return filter
    }

    static func excludesApplication(
        bundleIdentifier: String,
        ownBundleIdentifier: String?,
        includesAppWindows: Bool,
        cleanDesktop: Bool
    ) -> Bool {
        if !includesAppWindows && bundleIdentifier == ownBundleIdentifier { return true }
        // shortcut: macOS supplies no semantic notification/Dock filter; recheck these owners in live OS QA.
        return cleanDesktop && (bundleIdentifier == "com.apple.dock"
            || bundleIdentifier == "com.apple.notificationcenterui")
    }

    static func excludesWindow(bundleIdentifier: String?, layer: Int, cleanDesktop: Bool,
                               windowID: CGWindowID? = nil, overlayWindowIDs: Set<CGWindowID> = [],
                               includesAppWindows: Bool = true) -> Bool {
        if let windowID, overlayWindowIDs.contains(windowID) {
            // An exception would re-include the overlay when the whole app is already excluded.
            return includesAppWindows
        }
        return cleanDesktop && bundleIdentifier == "com.apple.finder"
            && layer == Int(CGWindowLevelForKey(.desktopIconWindow))
    }
}
