//
//  SettingsAboutPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct SettingsAboutPane: View {
    // Shown as Sparkle reads it: on in a beta build until the person chooses; the default is never stored.
    @AppStorage(UpdateChannels.betaKey) private var getsBetaUpdates = UpdateChannels.getsBetas()

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

                    Toggle(isOn: $getsBetaUpdates) {
                        Text("Get beta updates")
                        Text("Offers versions that are still being tested, as well as every regular release.")
                    }

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

            Section("Acknowledgments") {
                // The second sentence is the one the Independent JPEG Group's license asks for where MozJPEG
                // ships without its own documentation.
                Text("Images are optimized with oxipng, libwebp and MozJPEG. This software is based in part on the work of the Independent JPEG Group.")
                    .foregroundStyle(.secondary)

                Button("Show Licenses") {
                    if let licenses = Bundle.main.url(forResource: "OptimizerLicenses", withExtension: nil) {
                        NSWorkspace.shared.open(licenses)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
