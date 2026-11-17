//
//  ShortcutClashNotice.swift
//  Screendrop
//

import AppKit

/// Once, at launch, when a Sukusho shortcut is one of macOS's screenshot shortcuts that is still on (the owner,
/// 2026-11-17: beta 1). One press of such keys starts both, and for ⇧⌘5 only macOS's toolbar is left. Settings ›
/// Shortcuts keeps a warning under each one for as long as it lasts; this notice never comes back.
enum ShortcutClashNotice {
    static let shownKey = "shortcutClashNotice.shown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        let clashes = SystemScreenshotShortcuts.currentClashes()
        guard !clashes.isEmpty else { return }
        defaults.set(true, forKey: shownKey)

        // In key order, ⇧⌘3 before ⇧⌘4 (the VM showed them in Sukusho's action order: 3, 5, 4).
        let keys = clashes.compactMap { CaptureHotkeyPreferences.shortcut(for: $0) }
            .sorted { ($0.keyCode, $0.modifiers.rawValue) < ($1.keyCode, $1.modifiers.rawValue) }
            .map { $0.displayTokens.joined() }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "macOS also uses some of Sukusho’s shortcuts"
        alert.informativeText = """
            \(ListFormatter.localizedString(byJoining: keys)) also take macOS’s own screenshots, so one press starts both. \
            To use Sukusho’s, turn macOS’s off in System Settings › \(SystemScreenshotShortcuts.settingsPath). \
            You can also pick other keys in Sukusho’s Settings › Shortcuts.
            """
        alert.addButton(withTitle: "Open Keyboard Shortcuts…")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            SystemScreenshotShortcuts.openKeyboardSettings()
        }
    }
}
