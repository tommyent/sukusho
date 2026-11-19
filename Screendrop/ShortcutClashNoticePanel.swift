//
//  ShortcutClashNoticePanel.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Once, at launch, when a Sukusho shortcut is one of macOS's screenshot shortcuts that is still on (the owner,
/// 2026-11-17: beta 1), with the owner's two ways out: Use Other Keys… moves them and opens Settings › Shortcuts to
/// change them further, Open Keyboard Shortcuts… opens macOS's settings to turn macOS's off; Not Now leaves them.
/// Settings keeps the same line and buttons for as long as the clash lasts; this notice never comes back once answered.
/// It's a modeless `LaunchNoticePanel`: as a modal alert it held clipboard history for 20 s and more (m1, beta 2).
/// `showIfNeeded` (ShortcutClashNotice.swift) opens it and carries out the answer.
enum ShortcutClashNotice {
    static let shownKey = "shortcutClashNotice.shown"
    static var panel: LaunchNoticePanel?

    enum Answer { case useOtherKeys, openKeyboardShortcuts, notNow }

    /// The notice, not yet on screen. `perform` carries out the answer once `answer` has recorded it.
    static func makePanel(clashes: [SystemScreenshotShortcuts.Clash], canUseOtherKeys: Bool, defaults: UserDefaults,
                          perform: @escaping (Answer) -> Void) -> LaunchNoticePanel {
        weak var made: LaunchNoticePanel?
        let window = LaunchNoticePanel(title: "Shortcuts", content: Content(
            warning: SystemScreenshotShortcuts.warning(clashes, canUseOtherKeys: canUseOtherKeys),
            canUseOtherKeys: canUseOtherKeys
        ) { answer($0, closing: made, defaults: defaults, perform: perform) })
        made = window
        window.onClose = { panel = nil }
        return window
    }

    /// Records the answer, Not Now included, closes the notice, then carries the answer out. Closed without an answer,
    /// by its close button or by quitting, it comes back at the next launch.
    static func answer(_ answer: Answer, closing window: NSWindow?, defaults: UserDefaults, perform: (Answer) -> Void) {
        defaults.set(true, forKey: shownKey)
        window?.close()
        perform(answer)
    }

    /// Laid out as Settings' clash line (the owner's layout B): the warning, the two ways out on the right, and the
    /// Keyboard Shortcuts hint under them, which the alert had to put above its buttons.
    private struct Content: View {
        let warning: String
        let canUseOtherKeys: Bool
        let answer: (Answer) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("macOS also uses some of Sukusho’s shortcuts")
                    .font(.headline)
                Text(warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Not Now") { answer(.notNow) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if canUseOtherKeys {
                        Button("Use Other Keys…") { answer(.useOtherKeys) }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("Open Keyboard Shortcuts…") { answer(.openKeyboardShortcuts) }
                        .keyboardShortcut(canUseOtherKeys ? nil : .defaultAction)
                        .help(SystemScreenshotShortcuts.keyboardShortcutsHint)
                }
                Text(SystemScreenshotShortcuts.keyboardShortcutsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 420, alignment: .leading)
            .padding(20)
            .fixedSize()
        }
    }
}
