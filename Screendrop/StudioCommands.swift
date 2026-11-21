//
//  StudioCommands.swift
//  Screendrop
//
//  The Clip and Playback menus for the Studio editor. They act on the front
//  Studio window's model via `\.recordingStudio`. Bare-letter and navigation
//  keys (J, K, L, I, O, M, N, ←, →, ↑, ↓, Home, End) stay in
//  `StudioKeyCommands`, because menu key equivalents without modifiers would
//  steal typing from text fields.
//

import SwiftUI

struct StudioCommands: Commands {
    @FocusedValue(\.recordingStudio) private var model

    private var canControlPlayback: Bool {
        guard let model else { return false }
        return model.isLoaded && !model.isRestoringDocument && !model.isEditingSourceRegion
    }

    var body: some Commands {
        CommandMenu("Clip") {
            Group {
                Button("Split at Playhead") {
                    guard let model else { return }
                    model.splitClip(at: model.currentTime)
                }
                .disabled(model?.clipTimeline.split(at: model?.currentTime ?? 0) == nil)
                Divider()
                Button("Mark In (I)") { model?.markRange(.start) }
                Button("Mark Out (O)") { model?.markRange(.end) }
                Button("Delete Marked Range") { model?.deleteRange() }
                    .disabled(model?.rangeSelection == nil)
                Button("Clear Marked Range") { model?.clearRange() }
                    .keyboardShortcut("x", modifiers: .option)
                    .disabled(model?.rangeSelection == nil)
                Divider()
                Button("Move Clip Earlier") { model?.moveSelectedClip(by: -1) }
                    .disabled(model?.canMoveSelectedClipEarlier != true)
                Button("Move Clip Later") { model?.moveSelectedClip(by: 1) }
                    .disabled(model?.canMoveSelectedClipLater != true)
                Divider()
                Button("Add or Remove Marker (M)") { model?.toggleMarker() }
                Button(model?.snapsEdits == true ? "Turn Snapping Off (N)" : "Turn Snapping On (N)") {
                    model?.toggleSnapping()
                }
            }
            .disabled(!canControlPlayback)
        }

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
                Button("Previous Edit Point (↑)") { model?.seekToEditPoint(forward: false) }
                Button("Next Edit Point (↓)") { model?.seekToEditPoint(forward: true) }
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
