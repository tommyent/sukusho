//
//  SettingsLibraryPane.swift
//  Screendrop
//

import SwiftUI

/// Settings › Library: what the Library reads from captures and names them with.
struct LibrarySettingsPane: View {
    @AppStorage(ScreendropPreferences.libraryReadsTextKey) private var libraryReadsText = true
    @AppStorage(ScreendropPreferences.libraryUsesIntelligenceKey) private var libraryUsesIntelligence = true
    @AppStorage(ScreendropPreferences.libraryInsightsIncludeExistingKey) private var insightsIncludeExisting = false

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
}

/// Settings › Shortcuts: every system-wide shortcut in one place, captures first, images
/// before the recording (design pass choice 12), then Show Library.
struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            CaptureHotkeySettingsSection(
                actions: [.fullscreen, .window, .area, .scrollingCapture, .textCapture, .screenRecording, .library]
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
