//
//  CaptureHotkeySettingsSection.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Every capture shortcut in one place (design pass choice 12): click the
/// keys to record a new shortcut, Reset brings back one default, Clear
/// removes a shortcut, and Restore Defaults resets them all.
struct CaptureHotkeySettingsSection: View {
    let actions: [CaptureHotkeyAction]

    @State private var shortcuts = CaptureHotkeyPreferences.shortcuts()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var recordingAction: CaptureHotkeyAction?
    @State private var errorMessage: String?
    /// macOS's screenshot shortcuts that are on, by entry, read again whenever they could have changed.
    @State private var systemEntries: [Int: HotkeyShortcut] = [:]
    /// Every shortcut macOS has on, for Use Other Keys to stay clear of.
    @State private var systemAll: Set<HotkeyShortcut> = []

    /// This section's shortcuts that macOS's screenshot shortcuts also use.
    private var clashes: [SystemScreenshotShortcuts.Clash] {
        actions.compactMap { action in
            shortcuts[action].flatMap { SystemScreenshotShortcuts.entry(for: $0, in: systemEntries) == nil ? nil : (action, $0) }
        }
    }

    var body: some View {
        Section {
            if !clashes.isEmpty { clashSummary }
            ForEach(actions) { action in
                LabeledContent(action.title) {
                    HStack(spacing: DS.Space.m) {
                        shortcutField(for: action)

                        // Hidden rather than removed while it has nothing to
                        // undo, so the rows' buttons stay lined up.
                        Button("Reset") { apply(action.defaultShortcut, to: action) }
                            .controlSize(.small)
                            .opacity(isDefault(action) ? 0 : 1)
                            .disabled(isDefault(action))
                            .accessibilityHidden(isDefault(action))
                            .help("Use the default shortcut, \(action.defaultShortcut.displayString)")

                        Button("Clear") { apply(nil, to: action) }
                            .controlSize(.small)
                            .disabled(shortcuts[action] == nil)
                            .help("Remove this shortcut")
                    }
                }
                if clashes.contains(where: { $0.action == action }) {
                    warningLabel("Also macOS’s")
                        .accessibilityLabel("\(action.title)’s shortcut is also one of macOS’s")
                }
                if let warning = shortcuts[action]?.typingWarning {
                    warningLabel(warning)
                }
            }
            if HotkeyManager.shared.needsInputMonitoring { inputMonitoringNotice }

            messages
        } header: {
            HStack {
                Text("Keyboard Shortcuts")
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
                    .controlSize(.small)
                    .disabled(actions.allSatisfy(isDefault))
            }
        }
        .onAppear {
            reloadShortcuts()
            configureRecorder()
        }
        .onDisappear {
            recorder.stop()
            recordingAction = nil
        }
        // Back from System Settings with macOS's shortcut turned off: the warning goes without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadClashes()
        }
    }

    /// Above the list while shortcuts clash (the owner's layout B and wording): the keys, and the two ways out. Use Other
    /// Keys moves them here, where the rows show the new keys to change if wanted; Open Keyboard Shortcuts… goes to
    /// macOS's settings, to turn macOS's off and keep Sukusho's keys.
    private var clashSummary: some View {
        let canMove = !SystemScreenshotShortcuts.otherKeys(for: clashes.map(\.action), shortcuts: shortcuts, system: systemAll).isEmpty
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            warningLabel(SystemScreenshotShortcuts.warning(clashes, canUseOtherKeys: canMove))
            HStack(spacing: DS.Space.m) {
                Spacer(minLength: 0)
                if canMove {
                    Button("Use Other Keys") { useOtherKeys() }
                        .controlSize(.small)
                        .help("Move these to keys macOS doesn’t use; you can change them below")
                }
                Button("Open Keyboard Shortcuts…") { SystemScreenshotShortcuts.openKeyboardSettings() }
                    .controlSize(.small)
                    .help("Turn macOS’s off in Keyboard Shortcuts › Screenshots")
            }
        }
    }

    /// A warning in the system's own colors: the multicolor triangle, the text as secondary labels are.
    private func warningLabel(_ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        .font(.caption)
    }

    /// A shortcut that is a modifier key on its own works only with Input Monitoring: why, and the way to it.
    private var inputMonitoringNotice: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            warningLabel("A modifier key on its own needs Input Monitoring, so Sukusho can notice it in other apps. Sukusho never records what you type.")
            HStack {
                Spacer(minLength: 0)
                Button("Open Input Monitoring…") { ModifierTapMonitor.openInputMonitoringSettings() }
                    .controlSize(.small)
                    .help("Turn on Sukusho in Privacy & Security › Input Monitoring")
            }
        }
    }

    private func useOtherKeys() {
        errorMessage = nil
        SystemScreenshotShortcuts.useOtherKeys()
        reloadShortcuts()
    }

    /// The keys themselves are the control: a click records new ones.
    private func shortcutField(for action: CaptureHotkeyAction) -> some View {
        Button {
            toggleRecording(for: action)
        } label: {
            Group {
                if isRecording(action) {
                    Text("Type Shortcut…")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: 21)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else if let shortcut = shortcuts[action] {
                    HotkeyShortcutDisplay(shortcut: shortcut)
                } else {
                    Text("None")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: 21)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording(action) ? "Type the new shortcut, or press Esc to cancel" : "Click to record a new shortcut")
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(isRecording(action) ? "Recording" : shortcuts[action]?.displayString ?? "None")
        .accessibilityHint("Records a new shortcut")
    }

    @ViewBuilder
    private var messages: some View {
        if let rejection = recorder.rejection {
            Text(rejection)
                .font(.caption)
                .foregroundStyle(.red)
        } else if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        } else if let kept = SystemScreenshotShortcuts.keptKeysMessage(HotkeyManager.shared.keptKeys) {
            Text(kept)
                .font(.caption)
                .foregroundStyle(.red)
        }

        ForEach(actions) { action in
            if let failure = HotkeyManager.shared.registrationErrors[action] {
                Text("\(action.title): \(failure)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        if recordingAction != nil, recorder.rejection == nil {
            Text("Type the new shortcut, or tap a modifier key such as right ⌥ once or twice. Press Esc to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isDefault(_ action: CaptureHotkeyAction) -> Bool {
        _ = shortcuts  // re-read after every change
        return CaptureHotkeyPreferences.isDefault(action)
    }

    private func isRecording(_ action: CaptureHotkeyAction) -> Bool {
        recorder.isRecording && recordingAction == action
    }

    private func toggleRecording(for action: CaptureHotkeyAction) {
        errorMessage = nil
        HotkeyManager.shared.keptKeys = []

        if isRecording(action) {
            recorder.stop()
            recordingAction = nil
            return
        }

        recordingAction = action
        recorder.start()
    }

    private func configureRecorder() {
        recorder.onShortcutRecorded = { shortcut in
            guard let recordingAction else { return }
            apply(shortcut, to: recordingAction)
        }

        recorder.onCancel = {
            recordingAction = nil
        }
    }

    /// Nil clears the action.
    private func apply(_ shortcut: HotkeyShortcut?, to action: CaptureHotkeyAction) {
        HotkeyManager.shared.keptKeys = []
        if let shortcut, let conflict = CaptureHotkeyPreferences.conflictingAction(for: shortcut, excluding: action) {
            if let theirs = CaptureHotkeyPreferences.shortcut(for: conflict), theirs != shortcut {
                errorMessage = "\(shortcut.displayString) can’t be a shortcut while \(conflict.title) is \(theirs.displayString): a double tap starts with a tap."
            } else {
                errorMessage = "\(shortcut.displayString) is already assigned to \(conflict.title)."
            }
            NSSound.beep()
            recorder.stop()
            recordingAction = nil
            return
        }

        do {
            try HotkeyManager.shared.setShortcut(shortcut, for: action)
            shortcuts[action] = shortcut
            reloadClashes()
            errorMessage = nil
        } catch {
            errorMessage = "\(error.localizedDescription) Your previous shortcut has been kept."
            NSSound.beep()
        }
        recordingAction = nil
    }

    private func restoreDefaults() {
        recorder.stop()
        recordingAction = nil
        errorMessage = nil
        HotkeyManager.shared.keptKeys = []
        HotkeyManager.shared.restoreDefaults(for: actions)
        reloadShortcuts()
    }

    private func reloadShortcuts() {
        shortcuts = CaptureHotkeyPreferences.shortcuts(for: actions)
        reloadClashes()
    }

    private func reloadClashes() {
        systemEntries = SystemScreenshotShortcuts.currentEntries()
        systemAll = SystemScreenshotShortcuts.currentAllEnabled()
    }
}

private struct HotkeyShortcutDisplay: View {
    let shortcut: HotkeyShortcut

    /// ⌥ ⌥ is two keycaps of one token; tokens can repeat, so they're told apart by place.
    private var caps: [String] {
        shortcut.taps == 2 ? shortcut.displayTokens.flatMap { $0.split(separator: " ").map(String.init) } : shortcut.displayTokens
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, token in
                HotkeyKeyCap(token: token)
            }
        }
        // One element that reads the whole shortcut. A label on the bare
        // stack made SwiftUI resolve it through its own keycaps and recurse
        // until the stack overflowed whenever an accessibility client
        // (VoiceOver, an automation tool) read Settings › Screenshots.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayString)
    }
}

private struct HotkeyKeyCap: View {
    let token: String

    var body: some View {
        Text(token)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .frame(minWidth: 22, minHeight: 21)
            .padding(.horizontal, token.count > 1 ? 6 : 0)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35))
            }
    }
}
