//
//  ShortcutClashNotice.swift
//  Screendrop
//

import AppKit

/// Once, at launch, when a Sukusho shortcut is one of macOS's screenshot shortcuts that is still on (the owner,
/// 2026-11-17: beta 1). It says per key what one press does now (`SystemScreenshotShortcuts.noticeText`); Keep Both
/// leaves exactly that. Settings › Shortcuts keeps a warning under each one for as long as it lasts; this notice never
/// comes back.
enum ShortcutClashNotice {
    static let shownKey = "shortcutClashNotice.shown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        let entries = SystemScreenshotShortcuts.currentEntries()
        let clashes = SystemScreenshotShortcuts.clashes(CaptureHotkeyPreferences.shortcuts(), with: Set(entries.values))
            .compactMap { action -> (action: CaptureHotkeyAction, shortcut: HotkeyShortcut, entry: Int)? in
                guard let shortcut = CaptureHotkeyPreferences.shortcut(for: action),
                      let entry = SystemScreenshotShortcuts.entry(for: shortcut, in: entries) else { return nil }
                return (action, shortcut, entry)
            }
        guard !clashes.isEmpty else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "macOS also uses some of Sukusho’s shortcuts"
        alert.informativeText = SystemScreenshotShortcuts.noticeText(clashes)
        alert.addButton(withTitle: "Open Keyboard Shortcuts…")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            SystemScreenshotShortcuts.openKeyboardSettings()
        }
    }
}
