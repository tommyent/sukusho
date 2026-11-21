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
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit {
                        if let time = StudioPlayback.seconds(from: text) {
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
                Text(studioPreciseTimecode(model.displayTime))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.9))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard model.isLoaded, !model.isRestoringDocument, !model.isEditingSourceRegion else { return }
                        model.pause()
                        text = studioPreciseTimecode(model.currentTime)
                        isEditing = true
                    }
                    .help("Click to type a time to go to")
            }
        }
        .onChange(of: model.isEditingSourceRegion) { _, editing in
            if editing { isEditing = false }
        }
    }
}
