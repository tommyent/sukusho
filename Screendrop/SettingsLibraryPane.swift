//
//  SettingsLibraryPane.swift
//  Screendrop
//

import SwiftUI
import UniformTypeIdentifiers

/// Settings › Library: what the Library reads from captures and names them with, and clipboard history.
struct LibrarySettingsPane: View {
    @AppStorage(ScreendropPreferences.libraryReadsTextKey) private var libraryReadsText = true
    @AppStorage(ScreendropPreferences.libraryUsesIntelligenceKey) private var libraryUsesIntelligence = true
    @AppStorage(ScreendropPreferences.libraryInsightsIncludeExistingKey) private var insightsIncludeExisting = false
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var clipboardEnabled = false
    // shortcut: 30 days is a provisional default the owner hasn't confirmed yet (0 keeps everything).
    @AppStorage(ScreendropPreferences.clipboardRetentionDaysKey) private var clipboardRetentionDays = 30
    @State private var confirmingDeleteHistory = false
    @State private var ignoredApps = ScreendropPreferences.clipboardIgnoredApps
    @State private var settingUpClipboard = false

    var body: some View {
        Form {
            Section("Text and Titles") {
                SettingsControlLabel(
                    "Read text in captures",
                    detail: "Search finds captures by the words in them. Text is read on this Mac and never uploaded."
                ).control { label in
                    Toggle(isOn: $libraryReadsText) { label }
                }
                .toggleStyle(.switch)
                // Only where the model can run; elsewhere nothing mentions it.
                if CaptureLibraryIndex.shared.modelAvailable {
                    SettingsControlLabel(
                        "Use Apple Intelligence for titles and tag suggestions",
                        detail: "Names captures you haven't named and suggests tags, from the text read in them. Runs on this Mac and is never uploaded."
                    ).control { label in
                        Toggle(isOn: $libraryUsesIntelligence) { label }
                    }
                    .toggleStyle(.switch)
                    .disabled(!libraryReadsText)
                    existingCapturesRow
                }
            }
            clipboardSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            // Apple Intelligence may have been switched on or off since.
            CaptureLibraryIndex.shared.settingsDidChange()
        }
        .onChange(of: libraryReadsText) { _, _ in
            CaptureLibraryIndex.shared.settingsDidChange()
        }
        .onChange(of: libraryUsesIntelligence) { _, _ in
            CaptureLibraryIndex.shared.settingsDidChange()
        }
    }

    /// Older captures wait for the user, since there can be many: about
    /// `secondsPerCapture` each on this Mac.
    @ViewBuilder
    private var existingCapturesRow: some View {
        let index = CaptureLibraryIndex.shared
        let count = index.olderWithoutInsight
        if libraryReadsText, libraryUsesIntelligence, !insightsIncludeExisting, count > 0 {
            let minutes = max(1, Int((Double(count) * Self.secondsPerCapture / 60).rounded(.up)))
            HStack {
                SettingsControlLabel(
                    "Title and tag existing captures",
                    detail: "\(count.formatted()) older \(count == 1 ? "capture" : "captures"), about \(minutes) min. New captures are done as you take them."
                )
                Spacer()
                Button("Start") { index.includeExistingCaptures() }
                    .controlSize(.small)
                    .accessibilityLabel("Title and tag existing captures")
            }
        } else if insightsIncludeExisting, index.insightsPending > 0 {
            SettingsControlLabel("Title and tag existing captures",
                                 detail: "\(index.insightsPending.formatted()) left. Pauses while recording, in Low Power Mode or when the Mac is hot.")
        }
    }

    private static let secondsPerCapture = 2.5

    /// Clipboard history, off until turned on; its page sits in the Library sidebar.
    private var clipboardSection: some View {
        Section("Clipboard") {
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
            ignoredAppsRows
            HStack {
                SettingsControlLabel("Shortcut", detail: "\(clipboardShortcut) opens the clipboard popup. Change it in Shortcuts.")
                Spacer()
                Button("Change…") { SettingsWindowController.show(tab: .shortcuts) }.controlSize(.small)
            }
            HStack {
                SettingsControlLabel("Delete history", detail: "Removes every copy from this Mac, pinned ones too. Snippets stay.")
                Spacer()
                Button("Delete History…") { confirmingDeleteHistory = true }.controlSize(.small)
            }
            .disabled(!clipboardEnabled)
        }
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
            Text("Every copy is removed from this Mac, pinned ones too. Snippets stay.")
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

/// Settings › Shortcuts: every system-wide shortcut in one place, captures first, images
/// before the recording (design pass choice 12), then Show Library and Clipboard History.
struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            CaptureHotkeySettingsSection(
                actions: [.fullscreen, .window, .area, .scrollingCapture, .textCapture, .screenRecording, .library, .clipboardHistory]
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
