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
    @FocusedValue(\.recordingStudio) private var modelReference

    var body: some Commands {
        let modelReference = modelReference
        let model = modelReference?.value
        let canControlPlayback = model.map {
            $0.isLoaded && !$0.isRestoringDocument && !$0.isEditingSourceRegion
        } == true

        CommandMenu("Clip") {
            Group {
                Button("Insert Video Clip…") {
                    modelReference?.value?.presentInsertVideoClipPanel()
                }
                .disabled(model?.canImportVideoClip != true)
                Button("Split at Playhead") {
                    guard let model = modelReference?.value else { return }
                    model.splitClip(at: model.currentTime)
                }
                .disabled(model?.clipTimeline.split(at: model?.currentTime ?? 0) == nil)
                Divider()
                Button("Mark In (I)") { modelReference?.value?.markRange(.start) }
                Button("Mark Out (O)") { modelReference?.value?.markRange(.end) }
                Button("Delete Marked Range") { modelReference?.value?.deleteRange() }
                    .disabled(model?.rangeSelection == nil)
                Button("Clear Marked Range") { modelReference?.value?.clearRange() }
                    .keyboardShortcut("x", modifiers: .option)
                    .disabled(model?.rangeSelection == nil)
                Divider()
                Button("Move Clip Earlier") { modelReference?.value?.moveSelectedClip(by: -1) }
                    .disabled(model?.canMoveSelectedClipEarlier != true)
                Button("Move Clip Later") { modelReference?.value?.moveSelectedClip(by: 1) }
                    .disabled(model?.canMoveSelectedClipLater != true)
                Divider()
                Button("Add or Remove Marker (M)") { modelReference?.value?.toggleMarker() }
                Button(model?.snapsEdits == true ? "Turn Snapping Off (N)" : "Turn Snapping On (N)") {
                    modelReference?.value?.toggleSnapping()
                }
            }
            .disabled(!canControlPlayback)
        }

        CommandMenu("Playback") {
            Group {
                Button(model?.isPlaying == true ? "Pause (Space)" : "Play (Space)") {
                    modelReference?.value?.togglePlayback()
                }
                Divider()
                Button("Play Backward (J)") { modelReference?.value?.shuttle(forward: false) }
                Button("Pause (K)") { modelReference?.value?.pause() }
                Button("Play Forward (L)") { modelReference?.value?.shuttle(forward: true) }
                Divider()
                Button("Previous Edit Point (↑)") { modelReference?.value?.seekToEditPoint(forward: false) }
                Button("Next Edit Point (↓)") { modelReference?.value?.seekToEditPoint(forward: true) }
                Button("Previous Frame (←)") { modelReference?.value?.stepFrames(-1) }
                Button("Next Frame (→)") { modelReference?.value?.stepFrames(1) }
                Divider()
                Button("Go to Start (Home)") {
                    modelReference?.value?.pause()
                    modelReference?.value?.seek(to: 0)
                }
                Button("Go to End (End)") {
                    guard let model = modelReference?.value else { return }
                    model.pause()
                    model.seek(to: model.duration)
                }
            }
            .disabled(!canControlPlayback)
        }
    }
}
