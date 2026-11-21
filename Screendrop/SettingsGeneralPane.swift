//
//  SettingsGeneralPane.swift
//  Screendrop
//

import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @AppStorage(ScreendropPreferences.videoExportDirectoryPathKey) private var videoDirectoryPath = ""
    @AppStorage(ScreendropPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""
    @AppStorage(ScreendropPreferences.saveButtonUsesFolderKey) private var saveButtonUsesFolder = false
    @AppStorage(ScreendropPreferences.playSoundsKey) private var playSounds = true
    @AppStorage(ScreendropPreferences.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(ScreendropPreferences.includeAppWindowsInCapturesKey)
    private var includeAppWindowsInCaptures = false
    @AppStorage(ShakeToUpload.enabledKey) private var shakeShelf = false
    @State private var launchAtLoginStatus = LaunchAtLoginController.status
    @State private var launchAtLoginError: String?
    @Environment(\.overGlassPicture) private var overGlassPicture

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

    private var includeAppWindowsBinding: Binding<Bool> {
        Binding(
            get: { includeAppWindowsInCaptures },
            set: { ScreendropPreferences.setIncludeAppWindowsInCapturesManually($0) }
        )
    }

    var body: some View {
        Form {
            Section("Save Location") {
                folderRow("Save folder", directory: ScreendropPreferences.exportDirectory, path: $exportDirectoryPath)
                folderRow("Videos", directory: ScreendropPreferences.videoExportDirectory, path: $videoDirectoryPath)

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
                    "Shake while dragging files",
                    detail: "Shake the pointer while you drag files from Finder or the Desktop, then drop them on the shelf that appears to optimize, convert or share them. Hold Option as you drop to skip Share Options."
                ).control { label in
                    Toggle(isOn: $shakeShelf) { label }
                }
                .toggleStyle(.switch)
                .onChange(of: shakeShelf) { ShakeToUpload.shared.update() }

                SettingsControlLabel(
                    "Play sounds",
                    detail: "Play the camera shutter when a screenshot is taken, and a chime when a bug report or guide is ready."
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

            Section("Capture Visibility") {
                SettingsControlLabel(
                    "Include Sukusho windows in captures",
                    detail: "Show preview cards, recording controls, Settings, and other Sukusho windows in Sukusho’s own screenshots and recordings. This includes the clipboard popup. Outside Sukusho’s own screenshots, the popup asks macOS to limit sharing."
                ).control { label in
                    Toggle(isOn: includeAppWindowsBinding) { label }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            refreshLaunchAtLoginStatus()
        }
        .onChange(of: includeAppWindowsInCaptures) { _, _ in
            PreviewWindowCaptureExclusion.shared.refreshRegisteredWindows()
        }
    }

    private func folderRow(_ title: String, directory: URL, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(overGlassPicture ? AnyShapeStyle(.secondary) : AnyShapeStyle(.blue))
                Text(directory.abbreviatedPath)
                    .lineLimit(1).truncationMode(.middle).help(directory.path)
                if !path.wrappedValue.isEmpty {
                    Button("Use Default") { path.wrappedValue = "" }
                }
                Button("Choose…") { chooseDirectory(title, current: directory, path: path) }
                    .accessibilityLabel("Choose \(title)")
            }
            .controlSize(.small)
        }
    }

    private func chooseDirectory(_ title: String, current: URL, path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(title)"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = current

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        path.wrappedValue = url.path
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
