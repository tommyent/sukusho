//
//  RecordingBarState.swift
//  Screendrop
//
//  The recording bar's rules apart from its views (direction B, "Lit when on", owner's pick
//  2026-11-17): what state a toggle is in, and the two lines its hover shows. Available controls
//  are dark grey, light grey is only for a control that can't be used, colour says on, red means
//  recording and nothing else.
//

import Foundation

/// A toggle on the bar. Off is a dark-grey icon (slashed for the three inputs), on is a filled
/// capsule with something inside it, and a control that can't be used is light grey and says why.
nonisolated enum BarToggleState: Equatable {
    case off
    case on
    case unavailable(BarUnavailableReason)

    var isOn: Bool { self == .on }
}

nonisolated enum BarUnavailableReason: Equatable {
    /// Nothing of the kind is connected.
    case noDevice
    /// The chosen device was unplugged since it was picked.
    case disconnected
    /// macOS privacy settings don't allow it; a click opens them.
    case blocked
    /// Another setting rules it out, as Bug report does Clean desktop.
    case ruledOut
}

/// The hover name: what the control is and its state, then what a click does, or the value.
nonisolated struct BarHover: Equatable {
    var title: String
    var detail: String?

    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

nonisolated enum BarInputRules {
    /// A camera or microphone toggle's state. Blocked outranks everything: no choice works until
    /// it's allowed.
    static func state(isSelected: Bool, selectedIsConnected: Bool, hasDevices: Bool, isBlocked: Bool) -> BarToggleState {
        if isBlocked { return .unavailable(.blocked) }
        if !hasDevices { return .unavailable(.noDevice) }
        if isSelected, !selectedIsConnected { return .unavailable(.disconnected) }
        return isSelected ? .on : .off
    }
}

nonisolated enum BarHoverText {
    static func camera(_ state: BarToggleState, device: String?) -> BarHover {
        switch state {
        case .off: BarHover("Camera is off", "Click to turn on · right-click to choose")
        case .on: BarHover("Camera is on", "\(device ?? "Camera") · click to turn off")
        case .unavailable(.noDevice): BarHover("No camera", "Connect a camera to record yourself")
        case .unavailable(.disconnected): BarHover("Camera isn't connected", "Click to turn off · right-click to choose another")
        case .unavailable(.blocked): BarHover("Camera is blocked", "Click to allow it in System Settings")
        case .unavailable(.ruledOut): BarHover("Camera can't be used")
        }
    }

    static func microphone(_ state: BarToggleState, device: String?) -> BarHover {
        switch state {
        case .off: BarHover("Microphone is off", "Click to choose a microphone")
        case .on: BarHover("Microphone is on", "\(device ?? "Microphone") · click to change or turn off")
        case .unavailable(.noDevice): BarHover("No microphone", "Connect a microphone to record your voice")
        case .unavailable(.disconnected): BarHover("Microphone isn't connected", "Click to choose another")
        case .unavailable(.blocked): BarHover("Microphone is blocked", "Click to allow it in System Settings")
        case .unavailable(.ruledOut): BarHover("Microphone can't be used")
        }
    }

    static func systemAudio(isOn: Bool) -> BarHover {
        isOn ? BarHover("System audio is on", "Recording what you hear · click to turn off")
            : BarHover("System audio is off", "Click to record what you hear")
    }

    static func teleprompter(isOn: Bool) -> BarHover {
        isOn ? BarHover("Teleprompter is on", "Click to edit the script")
            : BarHover("Teleprompter is off", "Click to write a script")
    }

    static func timer(seconds: Int) -> BarHover {
        seconds == 0 ? BarHover("Timer is off", "Click to count down before recording")
            : BarHover("Timer: \(seconds) second\(seconds == 1 ? "" : "s")", "Counts down before recording · click to change")
    }

    static func cleanDesktop(_ state: BarToggleState) -> BarHover {
        switch state {
        case .on: BarHover("Clean desktop is on", "Icons, menu bar, Dock and banners stay out · click to turn off")
        case .off: BarHover("Clean desktop is off", "Click to leave icons, the menu bar and the Dock out")
        case .unavailable: BarHover("Clean desktop is off for bug reports", "A bug report shows the whole desktop")
        }
    }

    static func bugReport(isOn: Bool) -> BarHover {
        isOn ? BarHover("Bug report is on", "Stop writes a bug report instead of opening Studio")
            : BarHover("Bug report is off", "Click to write a bug report when you stop")
    }

    static func appLogs(isOn: Bool) -> BarHover {
        isOn ? BarHover("App logs are on", "This take's bug report adds the app's log")
            : BarHover("App logs are off", "Click to add the recorded app's log to the bug report")
    }
}
