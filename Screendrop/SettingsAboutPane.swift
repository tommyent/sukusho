//
//  SettingsAboutPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct SettingsAboutPane: View {
    var body: some View {
        Form {
            Section {
                AboutHeader()
            }

            if UpdaterManager.updatesThisBuild {
                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { UpdaterManager.shared.automaticallyChecksForUpdates },
                        set: { UpdaterManager.shared.automaticallyChecksForUpdates = $0 }
                    ))

                    Button("Check for Updates…") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                    .disabled(!UpdaterManager.shared.canCheckForUpdates)
                }
            }

            Section("Project") {
                Text("Sukusho is a lightweight open-source app for capturing screenshots and screen recordings on macOS.")
                    .foregroundStyle(.secondary)

                Link("Source Code", destination: URL(string: "https://github.com/tommyent/sukusho")!)
            }

            Section("Credits") {
                Text("Based on Screendrop by Fayaz Ahmed")
                    .foregroundStyle(.secondary)

                Link("GitHub", destination: URL(string: "https://github.com/fayazara")!)

                Link("Follow on X", destination: URL(string: "https://x.com/fayazara")!)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
