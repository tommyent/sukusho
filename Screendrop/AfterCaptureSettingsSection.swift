//
//  AfterCaptureSettingsSection.swift
//  Screendrop
//

import SwiftUI

/// A Form section listing the configurable after-capture actions for a given
/// capture type (screenshot or recording).
struct AfterCaptureActionsSection: View {
    let type: AfterCaptureType
    let title: String

    var body: some View {
        Section(title) {
            ForEach(AfterCaptureAction.actions(for: type)) { action in
                AfterCaptureToggleRow(action: action, type: type)
            }
        }
    }
}

private struct AfterCaptureToggleRow: View {
    @AppStorage private var isOn: Bool
    private let title: String
    private let subtitle: String
    private let action: AfterCaptureAction

    init(action: AfterCaptureAction, type: AfterCaptureType) {
        _isOn = AppStorage(wrappedValue: action.defaultValue, action.storageKey(for: type))
        self.action = action
        title = action.title
        subtitle = action.subtitle
    }

    var body: some View {
        let available = action != .upload || CloudCredentialStore.shared.isConfigured
        SettingsControlLabel(title, detail: subtitle).control { label in
            Toggle(isOn: Binding(get: { available && isOn }, set: { isOn = $0 })) { label }
        }
        .toggleStyle(.switch)
        .disabled(!available)

        if !available {
            HStack {
                Text(isOn ? "Automatic uploads are paused until Cloud is set up."
                          : "Set up Cloud to enable automatic uploads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set Up Cloud…") { SettingsWindowController.show(tab: .cloud) }
                    .controlSize(.small)
            }
        }
    }
}
