import AppKit
import SwiftUI

struct VideoSettingsPane: View {
    @AppStorage(ScreendropPreferences.revealExportInFinderKey) private var revealExportInFinder = true

    var body: some View {
        Form {
            AfterCaptureActionsSection(type: .recording, title: "After Recording")

            Section("After Export") {
                SettingsControlLabel(
                    "Reveal in Finder",
                    detail: "Select the exported file in Finder once the render finishes."
                ).control { label in
                    Toggle(isOn: $revealExportInFinder) { label }
                }
                .toggleStyle(.switch)
            }

            Section("Projects") {
                LabeledContent {
                    Button("Open Recordings Library…") {
                        CaptureLibraryModel.shared.show(filter: .recordings)
                    }
                } label: {
                    SettingsControlLabel(
                        "Recording projects",
                        detail: "Reopen a past recording with every edit intact."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct OverlaySettingsPane: View {
    @AppStorage(ScreendropPreferences.previewPositionKey) private var previewPositionRaw = PreviewOverlayPosition.right.rawValue
    @AppStorage(ScreendropPreferences.previewAutoCloseSecondsKey) private var autoCloseSeconds = 0
    @AppStorage(ScreendropPreferences.previewCloseAfterDraggingKey) private var closeAfterDragging = true
    // The same two settings as "Show preview overlay" under After Capture and After Recording.
    @AppStorage(AfterCaptureAction.showOverlay.storageKey(for: .screenshot))
    private var showsAfterScreenshots = AfterCaptureAction.showOverlay.defaultValue
    @AppStorage(AfterCaptureAction.showOverlay.storageKey(for: .recording))
    private var showsAfterRecordings = AfterCaptureAction.showOverlay.defaultValue

    private let autoCloseOptions: [Int] = [0, 5, 10, 30, 60]

    var body: some View {
        Form {
            Section("Show Preview Overlay") {
                SettingsControlLabel(
                    "After screenshots",
                    detail: "Show the floating preview card after a screenshot. Also under Screenshots › After Capture."
                ).control { label in
                    Toggle(isOn: $showsAfterScreenshots) { label }
                }
                .toggleStyle(.switch)
                SettingsControlLabel(
                    "After recordings",
                    detail: "Show the floating preview card after a recording. Also under Screen Recordings › After Recording."
                ).control { label in
                    Toggle(isOn: $showsAfterRecordings) { label }
                }
                .toggleStyle(.switch)
            }

            Section("Preview Overlay") {
                SettingsControlLabel(
                    "Position on screen",
                    detail: "Where the floating preview cards appear after a capture."
                ).control { label in
                    Picker(selection: $previewPositionRaw) {
                        ForEach(PreviewOverlayPosition.allCases) { position in
                            Text(position.title).tag(position.rawValue)
                        }
                    } label: {
                        label
                    }
                }

                SettingsControlLabel(
                    "Auto-close",
                    detail: "Automatically dismiss a preview after this delay, unless you're using it."
                ).control { label in
                    Picker(selection: $autoCloseSeconds) {
                        ForEach(autoCloseOptions, id: \.self) { seconds in
                            Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                        }
                    } label: {
                        label
                    }
                }

                SettingsControlLabel(
                    "Close after dragging",
                    detail: "Dismiss the preview once you drag it out to another app."
                ).control { label in
                    Toggle(isOn: $closeAfterDragging) { label }
                }
                .toggleStyle(.switch)
            }

            Section("Card Actions") {
                OverlayCardEditor()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
