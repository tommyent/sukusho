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
}
