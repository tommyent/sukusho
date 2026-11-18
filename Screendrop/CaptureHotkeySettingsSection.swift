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
    /// The enclosing Form's, so a row's messages can be scrolled into view.
    var scroller: ScrollViewProxy? = nil

    @State private var shortcuts = CaptureHotkeyPreferences.shortcuts()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var recordingAction: CaptureHotkeyAction?
    @State private var errorMessage: String?
    /// The row `errorMessage` is about; it shows under that row.
    @State private var errorAction: CaptureHotkeyAction?
    /// The row last recorded or changed, where the Input Monitoring notice goes when its shortcut needs it.
    @State private var lastAction: CaptureHotkeyAction?
    /// macOS's screenshot shortcuts that are on, by entry, read again whenever they could have changed.
    @State private var systemEntries: [Int: HotkeyShortcut] = [:]
    /// Every shortcut macOS has on, for Use Other Keys to stay clear of.
    @State private var systemAll: Set<HotkeyShortcut> = []
    /// macOS Dictation's shortcut, when it's a modifier key pressed twice.
    @State private var dictation: HotkeyShortcut?

    /// This section's shortcuts that macOS's screenshot shortcuts also use.
    private var clashes: [SystemScreenshotShortcuts.Clash] {
        actions.compactMap { action in
            shortcuts[action].flatMap { SystemScreenshotShortcuts.entry(for: $0, in: systemEntries) == nil ? nil : (action, $0) }
        }
    }

    var body: some View {
        Section {
            if !clashes.isEmpty { clashSummary }
            if let kept = SystemScreenshotShortcuts.keptKeysMessage(HotkeyManager.shared.keptKeys) {
                errorText(kept)
            }
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
                if hasNotes(action) {
                    rowNotes(for: action).id(notesID(action))
                }
                if clashes.contains(where: { $0.action == action }) {
                    warningLabel("Also macOS’s")
                        .accessibilityLabel("\(action.title)’s shortcut is also one of macOS’s")
                }
                if let warning = shortcuts[action]?.typingWarning {
                    warningLabel(warning)
                }
                if let dictation, shortcuts[action] == dictation {
                    warningLabel(SystemScreenshotShortcuts.dictationWarning(dictation))
                }
            }
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
        .onChange(of: recorder.rejection) {
            if let recordingAction { reveal(recordingAction) }
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
                    .help(SystemScreenshotShortcuts.keyboardShortcutsHint)
            }
            Text(SystemScreenshotShortcuts.keyboardShortcutsHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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

    /// A shortcut that is a modifier key on its own works only with Input Monitoring, which macOS applies when Sukusho
    /// next opens: why, the way to it, and the relaunch. In the VM (27.2.1) macOS didn't always ask, so Sukusho wasn't in
    /// the list until added with +, and until a relaunch this run couldn't tell it had been turned on: the line is right
    /// either way.
    private var inputMonitoringNotice: some View {
        let need = HotkeyManager.shared.inputMonitoring
        let granted = need == .relaunch
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            switch need {
            case .relaunch: warningLabel("Input Monitoring is on. macOS lets Sukusho use it once Sukusho opens again.")
            case .turnedOff: warningLabel("macOS turned off Sukusho’s watching for modifier keys. It stays off until Sukusho relaunches; if you turned off Input Monitoring for Sukusho, turn it on again first.")
            default: warningLabel("A modifier key on its own needs Input Monitoring, so Sukusho can notice it in other apps; it never records what you type. Turn on Sukusho there, or add it with + if it isn’t listed. If you’ve turned it on, relaunch Sukusho to start using modifier-key shortcuts.")
            }
            HStack(spacing: DS.Space.m) {
                Spacer(minLength: 0)
                Button("Relaunch Sukusho") { AppRelaunch.request() }
                    .controlSize(.small)
                    .help("Quit and open Sukusho again, so macOS applies Input Monitoring")
                if !granted {
                    Button("Open Input Monitoring…") {
                        ModifierTapMonitor.openInputMonitoringSettings()
                    }
                    .controlSize(.small)
                    .help("Turn on Sukusho in Privacy & Security › Input Monitoring")
                }
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

    private static let recordingHint = "Type the new shortcut, or tap a modifier key such as right ⌥ once or twice. Press Esc to cancel."
    /// Until the recorder has seen the keyboard quiet, a tap isn't recorded; this says so instead of ignoring it.
    private static let waitingHint = "Type the new shortcut. To tap a modifier key such as right ⌥, wait a moment with no other key held. Press Esc to cancel."

    private func errorText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    /// What's said right under a row: while it records, how to or why the keys were turned down; after a change to it
    /// failed, why.
    private func rowMessage(for action: CaptureHotkeyAction) -> (text: String, isError: Bool)? {
        if isRecording(action) {
            return (recorder.rejection ?? (recorder.canRecordTaps ? Self.recordingHint : Self.waitingHint), recorder.rejection != nil)
        }
        guard errorAction == action, let errorMessage else { return nil }
        return (errorMessage, true)
    }

    /// The row the Input Monitoring notice sits under: the one last changed if its modifier-key shortcut waits for it,
    /// else the first that does.
    private var inputMonitoringAction: CaptureHotkeyAction? {
        guard HotkeyManager.shared.needsInputMonitoring else { return nil }
        let waiting = actions.filter { shortcuts[$0]?.taps != nil && HotkeyManager.shared.registrationErrors[$0] != nil }
        return waiting.first { $0 == lastAction } ?? waiting.first
    }

    private func hasNotes(_ action: CaptureHotkeyAction) -> Bool {
        rowMessage(for: action) != nil || HotkeyManager.shared.registrationErrors[action] != nil || inputMonitoringAction == action
    }

    private func notesID(_ action: CaptureHotkeyAction) -> String { "shortcut-notes-\(action.rawValue)" }

    /// A row's messages, under the row, where the user is looking: at the end of the list they were below the fold at
    /// the default Settings size (m1, 26.5.1).
    private func rowNotes(for action: CaptureHotkeyAction) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let message = rowMessage(for: action) {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = HotkeyManager.shared.registrationErrors[action] { errorText(failure) }
            if inputMonitoringAction == action { inputMonitoringNotice }
        }
    }

    /// Scrolls a row's messages into view by the least needed: the last rows sit at the window's bottom edge.
    private func reveal(_ action: CaptureHotkeyAction) {
        lastAction = action
        Task { @MainActor in
            // shortcut: a short wait for the messages row to be inserted; a Form row has no did-insert hook.
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation { scroller?.scrollTo(notesID(action)) }
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
        reveal(action)
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
            errorAction = action
            NSSound.beep()
            recorder.stop()
            recordingAction = nil
            reveal(action)
            return
        }

        do {
            try HotkeyManager.shared.setShortcut(shortcut, for: action)
            shortcuts[action] = shortcut
            reloadClashes()
            errorMessage = nil
        } catch {
            errorMessage = "\(error.localizedDescription) Your previous shortcut has been kept."
            errorAction = action
            NSSound.beep()
        }
        recordingAction = nil
        reveal(action)
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
        dictation = SystemScreenshotShortcuts.currentDictationDoubleTap()
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
