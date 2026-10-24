//
//  SettingsGeneralPane.swift
//  Screendrop
//

import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(ScreendropPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""
    @AppStorage(ScreendropPreferences.saveButtonUsesFolderKey) private var saveButtonUsesFolder = false
    @AppStorage(ScreendropPreferences.playSoundsKey) private var playSounds = true
    @AppStorage(ScreendropPreferences.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(ScreendropPreferences.includeAppWindowsInCapturesKey)
    private var includeAppWindowsInCaptures = false
    @AppStorage(ScreendropPreferences.libraryReadsTextKey) private var libraryReadsText = true
    @AppStorage(ScreendropPreferences.libraryUsesIntelligenceKey) private var libraryUsesIntelligence = true
    @AppStorage(ScreendropPreferences.libraryInsightsIncludeExistingKey) private var insightsIncludeExisting = false
    @State private var launchAtLoginStatus = LaunchAtLoginController.status
    @State private var launchAtLoginError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginStatus.isEnabled },
            set: updateLaunchAtLogin
        )
    }

    private var saveButtonUsesFolderBinding: Binding<Bool> {
        Binding(
            get: { _ = saveButtonUsesFolder; return ScreendropPreferences.saveButtonUsesConfiguredFolder },
            set: { saveButtonUsesFolder = $0 }
        )
    }

    var body: some View {
        Form {
            // Every capture shortcut in one place, images first and the
            // recording last (design pass choice 12).
            CaptureHotkeySettingsSection(
                actions: [.fullscreen, .window, .area, .scrollingCapture, .textCapture, .screenRecording]
            )

            Section("Save Location") {
                // One row and one name, "Save folder", as in the menu bar
                // menu; "Use Default" only once a custom folder is set
                // (design pass choice 15).
                LabeledContent("Save folder") {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 14))

                        Text(ScreendropPreferences.exportDirectory.abbreviatedPath)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                            .help(ScreendropPreferences.exportDirectory.path)

                        if !exportDirectoryPath.isEmpty {
                            Button("Use Default") {
                                exportDirectoryPath = ""
                            }
                            .controlSize(.small)
                        }

                        Button("Choose…") {
                            chooseExportDirectory()
                        }
                        .controlSize(.small)
                    }
                }

                SettingsControlLabel(
                    "Save without choosing a location",
                    detail: "When you click Save, write straight to the save folder instead of asking where to put it."
                ).control { label in
                    Toggle(isOn: saveButtonUsesFolderBinding) { label }
                }
                .toggleStyle(.switch)
            }

            Section("System") {
                SettingsControlLabel(
                    "Launch at login",
                    detail: "Start Sukusho automatically when you sign in."
                ).control { label in
                    Toggle(isOn: launchAtLoginBinding) { label }
                }
                .toggleStyle(.switch)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if launchAtLoginStatus.requiresApproval {
                    Text("Approve Sukusho in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsControlLabel(
                    "Play sounds",
                    detail: "Play the camera shutter when a screenshot is taken, and a chime when an Agent Prompt is ready."
                ).control { label in
                    Toggle(isOn: $playSounds) { label }
                }
                .toggleStyle(.switch)

                SettingsControlLabel(
                    "Show menu bar icon",
                    detail: "When hidden, reopen Sukusho to get back to Settings."
                ).control { label in
                    Toggle(isOn: $showMenuBarIcon) { label }
                }
                .toggleStyle(.switch)
            }

            Section("Library") {
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

            Section("Capture Visibility") {
                SettingsControlLabel(
                    "Include Sukusho windows in captures",
                    detail: "Show preview cards, recording controls, Settings, and other Sukusho windows in screenshots and screen recordings."
                ).control { label in
                    Toggle(isOn: $includeAppWindowsInCaptures) { label }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            refreshLaunchAtLoginStatus()
            // Apple Intelligence may have been switched on or off since.
            CaptureLibraryIndex.shared.settingsDidChange()
        }
        .onChange(of: includeAppWindowsInCaptures) { _, _ in
            PreviewWindowCaptureExclusion.shared.refreshRegisteredWindows()
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

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Save Location"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ScreendropPreferences.exportDirectory

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        exportDirectoryPath = url.path
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = LaunchAtLoginController.status
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            launchAtLoginError = nil
            try LaunchAtLoginController.setEnabled(isEnabled)
        } catch {
            launchAtLoginError = "Could not update Launch at Login: \(error.localizedDescription)"
        }

        refreshLaunchAtLoginStatus()
    }
}

private enum LaunchAtLoginStatus {
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        self == .enabled
    }

    var requiresApproval: Bool {
        self == .requiresApproval
    }
}

@MainActor
private enum LaunchAtLoginController {
    static var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notRegistered, .notFound:
            .disabled
        @unknown default:
            .disabled
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        let service = SMAppService.mainApp

        if isEnabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
