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
    /// (Fable #9), except a private window (`registerPrivate`): ScreenCaptureKit captures leave them out by filter (`RecordingDesktopFilter`),
    /// and only `screencapture` runs hide them, for as long as the run lasts.
    static var includesAppWindowsInCaptures: Bool {
        ScreendropPreferences.includeAppWindowsInCaptures
    }

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    /// Windows hidden from every capture and from screen sharing, whatever the setting: the
    /// clipboard history popup, which shows private copies (owner, 2026-11-17).
    private let privateWindows = NSHashTable<NSWindow>.weakObjects()
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

    /// Hides `window` from every capture, other apps' and screen sharing included, and from
    /// Sukusho's own recordings through `privateWindowIDs`, whether or not Sukusho windows are
    /// included.
    func registerPrivate(window: NSWindow?) {
        guard let window else { return }
        privateWindows.add(window)
        window.sharingType = .none
    }

    /// The private windows on screen, for a recording's filter to leave out: ScreenCaptureKit
    /// filters by app and window, not by `sharingType`.
    var privateWindowIDs: Set<CGWindowID> {
        Set(privateWindows.allObjects.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
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
        privateWindows.contains(window) || (!Self.includesAppWindowsInCaptures && registeredWindows.contains(window))
    }

    private func applyCaptureVisibility(to window: NSWindow) {
        window.sharingType = ownCaptureCount > 0 && !Self.includesAppWindowsInCaptures ? .none : .readOnly
    }
}
