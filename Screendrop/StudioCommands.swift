//
//  StudioCommands.swift
//  Screendrop
//
//  The Playback menu for the Studio editor. It acts on the front Studio
//  window's model via `\.recordingStudio`. Bare-letter and navigation keys
//  (J, K, L, ←, →, Home, End) stay in `StudioKeyCommands`, because menu key
//  equivalents without modifiers would steal typing from text fields.
//

import SwiftUI

struct StudioCommands: Commands {
    @FocusedValue(\.recordingStudio) private var model

    private var canControlPlayback: Bool {
        guard let model else { return false }
        return model.isLoaded && !model.isRestoringDocument && !model.isEditingSourceRegion
    }

    var body: some Commands {
        CommandMenu("Playback") {
            Group {
                Button(model?.isPlaying == true ? "Pause (Space)" : "Play (Space)") {
                    model?.togglePlayback()
                }
                Divider()
                Button("Play Backward (J)") { model?.shuttle(forward: false) }
                Button("Pause (K)") { model?.pause() }
                Button("Play Forward (L)") { model?.shuttle(forward: true) }
                Divider()
                Button("Previous Frame (←)") { model?.stepFrames(-1) }
                Button("Next Frame (→)") { model?.stepFrames(1) }
                Divider()
                Button("Go to Start (Home)") {
                    model?.pause()
                    model?.seek(to: 0)
                }
                Button("Go to End (End)") {
                    guard let model else { return }
                    model.pause()
                    model.seek(to: model.duration)
                }
            }
            .disabled(!canControlPlayback)
        }
    }
}
