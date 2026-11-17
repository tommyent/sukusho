//
//  PreviewWindowCaptureExclusion.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit

@MainActor
final class PreviewWindowCaptureExclusion {
    static let shared = PreviewWindowCaptureExclusion()

    /// Whether Sukusho's own screenshots and recordings show its windows. Opt in via Settings;
    /// the pre-record reminder can turn it off. Other apps and screen sharing always see them
    /// (Fable #9): ScreenCaptureKit captures leave them out by filter (`RecordingDesktopFilter`),
    /// and only `screencapture` runs hide them, for as long as the run lasts.
    static var includesAppWindowsInCaptures: Bool {
        ScreendropPreferences.includeAppWindowsInCaptures
    }

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    /// `screencapture` runs in progress; while any is, the windows are hidden unless included.
    private var ownCaptureCount = 0

    private init() {}

    /// Registers any Screendrop-owned window whose capture visibility should
    /// follow the production preference.
    func register(window: NSWindow?) {
        guard let window else { return }

        registeredWindows.add(window)
        applyCaptureVisibility(to: window)
    }

    /// Applies a changed preference immediately to windows that already
    /// exist, rather than waiting for them to be recreated.
    func refreshRegisteredWindows() {
        for window in registeredWindows.allObjects {
            applyCaptureVisibility(to: window)
        }
    }

    /// Hides the windows from the `screencapture` run about to start, which can't filter by app.
    func beginOwnCapture() {
        ownCaptureCount += 1
        if ownCaptureCount == 1 { refreshRegisteredWindows() }
    }

    func endOwnCapture() {
        ownCaptureCount = max(0, ownCaptureCount - 1)
        if ownCaptureCount == 0 { refreshRegisteredWindows() }
    }

    /// Whether Sukusho's own captures leave this window out.
    func hidesFromOwnCaptures(_ window: NSWindow) -> Bool {
        !Self.includesAppWindowsInCaptures && registeredWindows.contains(window)
    }

    private func applyCaptureVisibility(to window: NSWindow) {
        window.sharingType = ownCaptureCount > 0 && !Self.includesAppWindowsInCaptures ? .none : .readOnly
    }
}
