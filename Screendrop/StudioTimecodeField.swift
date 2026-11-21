//
//  StudioTimecodeField.swift
//  Screendrop
//
//  Click-to-type timecode for the Studio transport bar.
//

import SwiftUI

/// The transport's current time. A click turns it into a field: type a
/// time (`12`, `1:05`, `1:05.5`, `1:02:03.5`) and Return goes there;
/// Escape leaves it.
struct StudioTimecodeField: View {
    @Bindable var model: RecordingStudioModel
    @State private var isEditing = false
    @State private var text = ""
    @State private var prefill = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Go to Timecode", text: $text)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Go to Timecode")
                    .focused($isFocused)
                    .onSubmit {
                        if let time = StudioPlayback.submittedTimecode(text, prefill: prefill) {
                            model.pause()
                            model.seek(to: time)
                        }
                        isEditing = false
                    }
                    .onExitCommand { isEditing = false }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { isEditing = false }
                    }
                    .onAppear { isFocused = true }
            } else {
                let readout = studioPreciseTimecode(model.displayTime)
                Button {
                    guard model.isLoaded, !model.isRestoringDocument, !model.isEditingSourceRegion else { return }
                    model.pause()
                    let initial = studioPreciseTimecode(model.currentTime)
                    prefill = initial
                    text = initial
                    isEditing = true
                } label: {
                    Text(readout)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isLoaded || model.isRestoringDocument || model.isEditingSourceRegion)
                .accessibilityLabel("Go to Timecode")
                .accessibilityValue(readout)
                .help("Click to type a time to go to")
            }
        }
        .onChange(of: model.isEditingSourceRegion) { _, editing in
            if editing { isEditing = false }
        }
    }
}
