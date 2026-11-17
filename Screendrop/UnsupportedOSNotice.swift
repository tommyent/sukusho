//
//  UnsupportedOSNotice.swift
//  Screendrop
//

import AppKit

/// Below the macOS Sukusho is built and tested on, launch says so once, as Transmit and other
/// Mac apps do: the app still runs, and features newer than that macOS may be missing. Never
/// shown on the tested macOS or later, and never refuses to launch (the owner, 2026-11-16).
enum UnsupportedOSNotice {
    static let dismissedKey = "unsupportedOSNotice.dismissedForVersion"
    #if DEBUG
    /// A Debug build pretends to run on this version, so the notice can be seen on macOS 27:
    /// `defaults write <bundle id> unsupportedOSNotice.previewVersion 26.5.1`.
    static let previewKey = "unsupportedOSNotice.previewVersion"
    #endif

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        let version = runningVersion(defaults: defaults)
        guard AppVersion.showsUnsupportedNotice(on: version, dismissedFor: defaults.string(forKey: dismissedKey)) else {
            return
        }
        let name = AppVersion.macOSString(version)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sukusho is built and tested on macOS \(AppVersion.testedMacOSMajor)"
        alert.informativeText = "You’re running macOS \(name), so some features may be missing or not work."
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t show again for macOS \(name)"
        NSApp.activate()
        alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(name, forKey: dismissedKey)
        }
    }

    private static func runningVersion(defaults: UserDefaults) -> OperatingSystemVersion {
        #if DEBUG
        if let preview = defaults.string(forKey: previewKey) {
            let parts = preview.split(separator: ".").compactMap { Int($0) }
            if let major = parts.first {
                return OperatingSystemVersion(majorVersion: major, minorVersion: parts.count > 1 ? parts[1] : 0,
                                              patchVersion: parts.count > 2 ? parts[2] : 0)
            }
        }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersion
    }
}
