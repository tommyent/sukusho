//
//  SettingsClipboardPane.swift
//  Screendrop
//

import SwiftUI
import UniformTypeIdentifiers

/// Settings › Clipboard: clipboard history, off until turned on, and the apps it ignores. A pane of its own:
/// as a section at the foot of Settings › Library, the owner looked for it and didn't find it (2026-11-16).
struct ClipboardSettingsPane: View {
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var clipboardEnabled = false
    // Option A: copies age out only when the user picks a period; 0 (Forever) keeps everything.
    @AppStorage(ScreendropPreferences.clipboardRetentionDaysKey) private var clipboardRetentionDays = 0
    @State private var confirmingDeleteHistory = false
    @State private var ignoredApps = ScreendropPreferences.clipboardIgnoredApps
    @State private var settingUpClipboard = false

    var body: some View {
        Form {
            Section("Clipboard History") {
                SettingsControlLabel(
                    "Keep clipboard history",
                    detail: "Find and paste what you copied, from \(clipboardShortcut) or Clipboard in the Library. Kept on this Mac; concealed items and the apps below are skipped. Nothing is recorded while this is off."
                ).control { label in
                    // Turning it on goes through the same steps as the Library's setup page.
                    Toggle(isOn: Binding(get: { clipboardEnabled },
                                         set: { if $0 { settingUpClipboard = true } else { clipboardEnabled = false } })) { label }
                }
                .toggleStyle(.switch)
                Picker("Keep copies for", selection: $clipboardRetentionDays) {
                    Text("1 Day").tag(1)
                    Text("1 Week").tag(7)
                    Text("1 Month").tag(30)
                    Text("1 Year").tag(365)
                    Text("Forever").tag(0)
                }
                .disabled(!clipboardEnabled)
                HStack {
                    SettingsControlLabel("Shortcut", detail: "\(clipboardShortcut) opens the clipboard popup. Change it in Shortcuts.")
                    Spacer()
                    Button("Change…") { SettingsWindowController.show(tab: .shortcuts) }.controlSize(.small)
                }
                HStack {
                    SettingsControlLabel("Delete history", detail: "Removes every copy from this Mac but the saved ones. Saved copies and snippets stay.")
                    Spacer()
                    Button("Delete History…") { confirmingDeleteHistory = true }.controlSize(.small)
                }
                .disabled(!clipboardEnabled)
            }
            Section("Ignored Apps") {
                ignoredAppsRows
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .sheet(isPresented: $settingUpClipboard) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Set Up Clipboard History").font(.system(size: 17, weight: .bold))
                Text(ClipboardSetupSteps.intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ClipboardSetupSteps()
                HStack {
                    Spacer()
                    Button("Cancel") { settingUpClipboard = false }.keyboardShortcut(.cancelAction)
                    Button("Turn On") {
                        clipboardEnabled = true
                        settingUpClipboard = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Space.xl)
            .frame(width: 540)
        }
        .confirmationDialog("Delete clipboard history?", isPresented: $confirmingDeleteHistory) {
            Button("Delete History", role: .destructive) { ClipboardHistoryModel.shared.deleteHistory() }
        } message: {
            Text("Every copy is removed from this Mac but the saved ones. Saved copies and snippets stay.")
        }
    }

    /// Copies made in these apps are never kept. Password apps are on the list until removed.
    @ViewBuilder
    private var ignoredAppsRows: some View {
        HStack {
            SettingsControlLabel("Ignore copies from", detail: "Nothing copied in these apps is kept.")
            Spacer()
            Button("Add App…", action: addIgnoredApps).controlSize(.small)
        }
        ForEach(ignoredApps, id: \.self) { bundleID in
            HStack(spacing: 8) {
                Image(nsImage: ClipboardHistoryModel.shared.appIcon(bundleID)
                      ?? NSWorkspace.shared.icon(for: .applicationBundle))
                    .resizable().frame(width: 18, height: 18)
                Text(Self.ignoredAppName(bundleID))
                Spacer()
                Button("Remove", systemImage: "minus.circle") { setIgnoredApps(ignoredApps.filter { $0 != bundleID }) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Keep copies from \(Self.ignoredAppName(bundleID)) again")
            }
            .padding(.leading, 12)
        }
    }

    private static func ignoredAppName(_ bundleID: String) -> String {
        // 1Password is on the default list whether or not this Mac has it.
        ClipboardHistoryModel.shared.appName(bundleID) ?? (bundleID == "com.1password.1password" ? "1Password" : bundleID)
    }

    private func addIgnoredApps() {
        let panel = NSOpenPanel()
        panel.title = "Ignore Copies From"
        panel.prompt = "Ignore"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        setIgnoredApps(ignoredApps + added.filter { !ignoredApps.contains($0) })
    }

    private func setIgnoredApps(_ apps: [String]) {
        ignoredApps = apps
        ScreendropPreferences.clipboardIgnoredApps = apps
    }

    private var clipboardShortcut: String {
        CaptureHotkeyPreferences.shortcut(for: .clipboardHistory)?.displayTokens.joined() ?? "its shortcut"
    }
}
