import CoreGraphics
import Foundation
import Testing

/// The recording bar's direction B rules: dark grey off, coloured on, light grey only for a
/// control that can't be used, and a hover that says why (owner's pick, 2026-11-17).
struct RecordingBarStateTests {
    @Test func anInputIsOnOffOrSaysWhyItCantBeUsed() {
        func state(selected: Bool = false, connected: Bool = true, devices: Bool = true, blocked: Bool = false) -> BarToggleState {
            BarInputRules.state(isSelected: selected, selectedIsConnected: connected, hasDevices: devices, isBlocked: blocked)
        }
        #expect(state() == .off)
        #expect(state(selected: true) == .on)
        #expect(state(devices: false) == .unavailable(.noDevice))
        #expect(state(selected: true, connected: false) == .unavailable(.disconnected))
        #expect(state(selected: true, blocked: true) == .unavailable(.blocked), "blocked outranks a choice")
        #expect(state(devices: false, blocked: true) == .unavailable(.blocked))
        #expect(state(selected: true).isOn && !state(blocked: true).isOn)
    }

    /// The countdown lists only what will record: a saved microphone or camera that is missing or
    /// blocked shows as unavailable in the picker and isn't promised in the countdown (Astra SB1).
    @Test func theCountdownListsOnlyWhatWillRecord() {
        let missing = BarInputRules.state(isSelected: true, selectedIsConnected: false, hasDevices: false, isBlocked: false)
        let unplugged = BarInputRules.state(isSelected: true, selectedIsConnected: false, hasDevices: true, isBlocked: false)
        let blocked = BarInputRules.state(isSelected: true, selectedIsConnected: true, hasDevices: true, isBlocked: true)
        let on = BarInputRules.state(isSelected: true, selectedIsConnected: true, hasDevices: true, isBlocked: false)

        let none = BarCountdownInputs(camera: missing, microphone: unplugged, systemAudio: false)
        #expect(!none.camera && !none.microphone && none.isEmpty)
        let blockedMic = BarCountdownInputs(camera: on, microphone: blocked, systemAudio: true)
        #expect(blockedMic.camera && !blockedMic.microphone && blockedMic.systemAudio && !blockedMic.isEmpty)
        #expect(BarCountdownInputs(camera: .off, microphone: on, systemAudio: false).microphone)
    }

    @Test func theHoverNamesTheStateThenTheClickOrTheValue() {
        #expect(BarHoverText.microphone(.on, device: "MacBook Pro Microphone")
            == BarHover("Microphone is on", "MacBook Pro Microphone · click to change or turn off"))
        #expect(BarHoverText.camera(.off, device: nil) == BarHover("Camera is off", "Click to turn on · right-click to choose"))
        #expect(BarHoverText.microphone(.unavailable(.blocked), device: nil).detail == "Click to allow it in System Settings")
        #expect(BarHoverText.camera(.unavailable(.noDevice), device: nil).title == "No camera")
        #expect(BarHoverText.timer(seconds: 3).title == "Timer: 3 seconds")
        #expect(BarHoverText.timer(seconds: 1).title == "Timer: 1 second")
        #expect(BarHoverText.cleanDesktop(.unavailable(.ruledOut)).detail == "A bug report shows the whole desktop")
        #expect(BarHoverText.includeAppWindows(isOn: true)
            == BarHover("Sukusho windows will be captured", "Click to hide Sukusho windows from captures"))
        #expect(BarHoverText.includeAppWindows(isOn: false)
            == BarHover("Sukusho windows are hidden", "Click to include Sukusho windows in captures"))
    }

    @Test func clampingKeepsVisibleBarAndPillInsideScreenVisibleFrame() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 835)
        let barInPanel = CGRect(x: 130, y: 64, width: 500, height: 52)
        let bannerInPanel = CGRect(x: 250, y: 124, width: 260, height: 30)

        // Dragged past the left edge so Stop and transport buttons would sit off screen.
        let panelLeft = CGRect(x: -350, y: 200, width: 760, height: 182)
        let clampedLeft = BarPanelGeometry.clampedPanelFrame(panelLeft, visibleContentInPanel: barInPanel, to: screen)
        let barAfterLeft = BarPanelGeometry.screenRect(forPanelRect: barInPanel, in: clampedLeft)
        #expect(barAfterLeft.minX == screen.minX)
        #expect(barAfterLeft.maxX <= screen.maxX)

        // Dragged down so the amber pill goes under the Dock (y < 40).
        let contentWithPill = BarPanelGeometry.visibleContentInPanel(
            barFrame: barInPanel, bannerFrame: bannerInPanel, showsBanner: true
        )
        let panelLow = CGRect(x: 340, y: 0, width: 760, height: 182)
        let clampedLow = BarPanelGeometry.clampedPanelFrame(panelLow, visibleContentInPanel: contentWithPill, to: screen)
        let pillAfterLow = BarPanelGeometry.screenRect(forPanelRect: bannerInPanel, in: clampedLow)
        #expect(pillAfterLow.minY == screen.minY)

        // Dragged up so the visible bar goes behind the menu bar (maxY > 875).
        let panelHigh = CGRect(x: 340, y: 800, width: 760, height: 182)
        let clampedHigh = BarPanelGeometry.clampedPanelFrame(panelHigh, visibleContentInPanel: barInPanel, to: screen)
        let barAfterHigh = BarPanelGeometry.screenRect(forPanelRect: barInPanel, in: clampedHigh)
        #expect(barAfterHigh.maxY == screen.maxY)
    }

    @Test func manualVisibilityChoiceClearsBugReportOwnership() {
        let suiteName = "RecordingBarStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Bug report enables app windows and takes ownership, then turning Bug report off reverts it.
        AppWindowCaptureVisibility.applyBugReportChange(true, defaults: defaults)
        #expect(defaults.bool(forKey: "includeAppWindowsInCaptures"))
        #expect(defaults.bool(forKey: "recordingBugReportAddedAppWindows"))
        AppWindowCaptureVisibility.applyBugReportChange(false, defaults: defaults)
        #expect(!defaults.bool(forKey: "includeAppWindowsInCaptures"))
        #expect(!defaults.bool(forKey: "recordingBugReportAddedAppWindows"))

        // Bug report enables app windows, then user explicitly turns Capture Visibility off and back on
        // (e.g. from Settings before opening the bar): turning Bug report off must keep it on.
        AppWindowCaptureVisibility.applyBugReportChange(true, defaults: defaults)
        AppWindowCaptureVisibility.setManually(false, defaults: defaults)
        #expect(!defaults.bool(forKey: "includeAppWindowsInCaptures"))
        #expect(!defaults.bool(forKey: "recordingBugReportAddedAppWindows"))
        AppWindowCaptureVisibility.setManually(true, defaults: defaults)
        #expect(defaults.bool(forKey: "includeAppWindowsInCaptures"))
        #expect(!defaults.bool(forKey: "recordingBugReportAddedAppWindows"))

        AppWindowCaptureVisibility.applyBugReportChange(false, defaults: defaults)
        #expect(defaults.bool(forKey: "includeAppWindowsInCaptures"))
    }
}
