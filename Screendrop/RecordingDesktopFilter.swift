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
