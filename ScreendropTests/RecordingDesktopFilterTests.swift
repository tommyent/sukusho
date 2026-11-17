import AppKit
import CoreGraphics
import Testing

struct RecordingDesktopFilterTests {
    @Test(arguments: ["com.apple.dock", "com.apple.notificationcenterui"])
    func cleanDesktopExcludesSystemHostsEvenWhenAppWindowsAreIncluded(_ bundleIdentifier: String) {
        #expect(RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: bundleIdentifier, ownBundleIdentifier: "test.app",
            includesAppWindows: true, cleanDesktop: true
        ))
        #expect(!RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: bundleIdentifier, ownBundleIdentifier: "test.app",
            includesAppWindows: false, cleanDesktop: false
        ))
    }

    @Test(arguments: [false, true])
    func appWindowPreferenceStaysIndependent(_ cleanDesktop: Bool) {
        #expect(RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
            includesAppWindows: false, cleanDesktop: cleanDesktop
        ))
        #expect(!RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
            includesAppWindows: true, cleanDesktop: cleanDesktop
        ))
    }

    @Test(arguments: ["com.apple.finder", "com.apple.wallpaper.agent", "test.new-app"])
    func keepsFinderWallpaperAndNewApps(_ bundleIdentifier: String) {
        #expect(!RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: bundleIdentifier, ownBundleIdentifier: "test.app",
            includesAppWindows: false, cleanDesktop: true
        ))
    }

    @Test func excludesOnlyFinderDesktopIconWindows() {
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "com.apple.finder", layer: iconLayer, cleanDesktop: true
        ))
        for layer in [0, Int(CGWindowLevelForKey(.desktopWindow)), iconLayer + 1] {
            #expect(!RecordingDesktopFilter.excludesWindow(
                bundleIdentifier: "com.apple.finder", layer: layer, cleanDesktop: true
            ))
        }
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "com.apple.finder", layer: iconLayer, cleanDesktop: false
        ))
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "test.app", layer: iconLayer, cleanDesktop: true
        ))
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: nil, layer: iconLayer, cleanDesktop: true
        ))
    }

    @Test(arguments: [false, true], [false, true])
    func cameraBubbleAndPenStayExcludedWithoutChangingOtherAppWindows(_ cleanDesktop: Bool, _ includesAppWindows: Bool) {
        let appExcluded = RecordingDesktopFilter.excludesApplication(
            bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
            includesAppWindows: includesAppWindows, cleanDesktop: cleanDesktop
        )
        let overlays: Set<CGWindowID> = [42, 45] // Camera bubble and recording pen.
        for windowID in overlays {
            let overlayException = RecordingDesktopFilter.excludesWindow(
                bundleIdentifier: "test.app", layer: Int(CGWindowLevelForKey(.floatingWindow)),
                cleanDesktop: cleanDesktop, windowID: windowID, overlayWindowIDs: overlays,
                includesAppWindows: includesAppWindows
            )
            // ScreenCaptureKit exceptions invert the application's inclusion rule.
            #expect(appExcluded != overlayException)
        }
        for windowID in [CGWindowID(43), CGWindowID(44)] { // Recording bar and ordinary app window.
            #expect(!RecordingDesktopFilter.excludesWindow(
                bundleIdentifier: "test.app", layer: Int(CGWindowLevelForKey(.floatingWindow)),
                cleanDesktop: cleanDesktop, windowID: windowID, overlayWindowIDs: overlays,
                includesAppWindows: includesAppWindows
            ))
        }
        #expect(appExcluded == !includesAppWindows)
        #expect(!RecordingDesktopFilter.excludesWindow(
            bundleIdentifier: "test.app", layer: 0, cleanDesktop: cleanDesktop,
            windowID: 42, overlayWindowIDs: [], includesAppWindows: includesAppWindows
        ))
    }

    /// A recording that captures Sukusho's windows must be told about the popup before it opens, the
    /// first time included (Sol, CVR-2): display and area recordings with Include on (as Bug report sets
    /// it), not one that leaves the app out, not a window recording, and not once it is already named.
    @Test func aPopupFirstOpenedDuringARecordingNeedsTheFilterUpdated() {
        let popup: CGWindowID = 4242
        #expect(PrivateWindowCoverage(recordsDisplay: true, includesAppWindows: true, excludedIDs: []).needsFilterUpdate(for: popup))
        #expect(!PrivateWindowCoverage(recordsDisplay: true, includesAppWindows: true, excludedIDs: [popup]).needsFilterUpdate(for: popup))
        #expect(!PrivateWindowCoverage(recordsDisplay: true, includesAppWindows: false, excludedIDs: []).needsFilterUpdate(for: popup))
        #expect(!PrivateWindowCoverage(recordsDisplay: false, includesAppWindows: true, excludedIDs: []).needsFilterUpdate(for: popup))
        // Once a filter has been rebuilt with the popup, the same plan leaves it out.
        #expect(!RecordingDesktopFilter.excludesApplication(bundleIdentifier: "test.app", ownBundleIdentifier: "test.app",
                                                            includesAppWindows: true, cleanDesktop: false))
        #expect(RecordingDesktopFilter.excludesWindow(bundleIdentifier: "test.app", layer: 0, cleanDesktop: false, windowID: popup,
                                                      overlayWindowIDs: [popup], includesAppWindows: true))
    }

    /// The clipboard popup is private: hidden from every capture and from screen sharing, before,
    /// during and after Sukusho's own screenshots, and named for recordings to leave out (owner).
    @MainActor
    @Test func thePrivatePopupStaysHiddenFromEveryCapture() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let exclusion = PreviewWindowCaptureExclusion.shared
        exclusion.registerPrivate(window: window)
        #expect(window.sharingType == .none)
        #expect(exclusion.hidesFromOwnCaptures(window))
        exclusion.beginOwnCapture()
        exclusion.endOwnCapture()
        exclusion.refreshRegisteredWindows()
        #expect(window.sharingType == .none, "a refresh after a capture doesn't make it visible")
    }

    /// With the preference off (its default), a Sukusho window is visible to every other capture
    /// tool and to screen sharing, and hidden only while Sukusho's own screencapture runs (Fable #9).
    @MainActor
    @Test func ownWindowsHideOnlyDuringSukushosOwnScreenshots() {
        guard !ScreendropPreferences.includeAppWindowsInCaptures else { return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let exclusion = PreviewWindowCaptureExclusion.shared
        exclusion.register(window: window)
        #expect(window.sharingType == .readOnly)
        #expect(exclusion.hidesFromOwnCaptures(window))

        exclusion.beginOwnCapture()
        exclusion.beginOwnCapture()
        #expect(window.sharingType == .none)
        exclusion.endOwnCapture()
        #expect(window.sharingType == .none, "still hidden while another run is going")
        exclusion.endOwnCapture()
        #expect(window.sharingType == .readOnly)
    }
}
