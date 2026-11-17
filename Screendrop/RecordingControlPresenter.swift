//
//  RecordingControlPresenter.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//
//  The in-session mode of the floating bar: elapsed time and the transport
//  controls for the recording that's running. It shares its panel and chrome
//  with the pre-record picker (RecordingPickerBar), so starting a recording
//  morphs one into the other instead of swapping windows.
//

import AppKit
import SwiftUI

// MARK: - Controls

struct RecordingSessionControls: View {
    @State private var manager = ScreenRecordingManager.shared
    @State private var ink = RecordingInkPresenter.shared
    @State private var showsDiscardConfirmation = false

    private var isPaused: Bool {
        manager.state == .paused
    }

    /// Starting and finishing are both moments where the transport can't
    /// safely be driven - the capture graph is being wired up or torn down.
    private var isSettling: Bool {
        manager.state == .starting || manager.state == .finishing
    }

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            elapsed

            RecordingInputChips()

            BarDivider()

            BarActionButton(
                id: .pen,
                hover: ink.isPenOn ? BarHover("Stop drawing", "Esc · ⌘Z undoes the last stroke")
                    : BarHover("Draw on screen", "Drags draw instead of clicking"),
                systemImage: "pencil.tip",
                // A helper, so soft blue when on: red is for recording alone.
                tint: ink.isPenOn ? BarMetrics.helperOn : BarMetrics.activeTint,
                accessibility: ink.isPenOn
                    ? "Stop drawing. Escape also stops, and Command-Z undoes the last stroke."
                    : "Draw on screen. Drags draw instead of clicking until you stop drawing."
            ) {
                ink.togglePen()
            }
            .disabled(manager.state != .recording)

            BarActionButton(
                id: .pauseResume,
                hover: isPaused ? BarHover("Resume", "Recording is paused") : BarHover("Pause", "The take keeps its place"),
                systemImage: isPaused ? "play.fill" : "pause.fill",
                // Resume is the way back in, a filled green circle while paused.
                filled: isPaused ? BarMetrics.cameraOn : nil
            ) {
                if isPaused {
                    manager.resumeRecording()
                } else {
                    manager.pauseRecording()
                }
            }
            .disabled(isSettling)

            BarActionButton(
                id: .restart,
                hover: BarHover("Start over", "Moves this take to the Trash and starts again"),
                systemImage: "arrow.counterclockwise",
                accessibility: "Restart - move this take to the Trash and start again"
            ) {
                manager.restartRecording()
            }
            .disabled(isSettling)

            BarActionButton(
                id: .stop,
                hover: BarHover("Stop recording", ScreendropPreferences.recordingBugReport
                    ? "Writes the bug report" : "Opens the recording in Studio"),
                systemImage: "stop.fill",
                tint: BarMetrics.recordTint,
                accessibility: "Stop and save the recording"
            ) {
                manager.stopRecording()
            }
            .disabled(isSettling)

            BarActionButton(
                id: .discard,
                hover: BarHover("Discard", "Moves this recording to the Trash"),
                systemImage: "trash.fill",
                accessibility: "Discard - move this recording to the Trash"
            ) {
                showsDiscardConfirmation = true
            }
            .disabled(!manager.state.canDiscard)
            .confirmationDialog("Move this recording to the Trash?", isPresented: $showsDiscardConfirmation,
                                titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { manager.deleteRecording() }
                Button("Cancel", role: .cancel) { }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text("You can recover the recording from the Trash.")
            }
        }
        .onChange(of: manager.state) { _, _ in showsDiscardConfirmation = false }
    }

    /// Red while recording - the only red besides Stop - and amber while paused.
    private var elapsed: some View {
        HStack(spacing: 7) {
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .bold))
            } else {
                Circle()
                    .frame(width: 8, height: 8)
            }
            Text(isPaused ? "Paused · \(manager.formattedElapsedTime)" : manager.formattedElapsedTime)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                // Fixed width so the clock ticking over from 9:59 to 10:00
                // doesn't nudge the whole bar sideways.
                .frame(minWidth: 52, alignment: .leading)
        }
        .foregroundStyle(isPaused ? Color.black.opacity(0.85) : .white)
        .padding(.horizontal, 12)
        .frame(height: BarMetrics.chipHeight + 2)
        .background(Capsule().fill(isPaused ? BarMetrics.caution : BarMetrics.recordTint))
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(height: BarMetrics.controlSize)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isPaused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isPaused
                ? "Recording paused at \(manager.formattedElapsedTime)"
                : "Recording, \(manager.formattedElapsedTime) elapsed"
        )
    }
}

/// The inputs going into the take, as the same filled chips the picker shows, so you can see the
/// microphone is live while you talk. The microphone's chip carries its live level, red for a
/// moment after it clips; paused, the chips dim. Its own view so the ~20 level updates a second
/// redraw only the chips, not the transport.
struct RecordingInputChips: View {
    @State private var manager = ScreenRecordingManager.shared

    var body: some View {
        let inputs = manager.takeInputs
        HStack(spacing: 0) {
            if inputs.camera {
                chip(.camera, BarHover("Camera is recording"), "video.fill", BarMetrics.cameraOn) {
                    BarCameraThumbnail()
                }
            }
            if inputs.microphone {
                chip(.microphone, BarHover("Microphone is recording", manager.isMicrophoneClipping ? "Too loud" : nil),
                     "mic.fill", BarMetrics.microphoneOn) {
                    BarLevelMeter(level: manager.state == .paused ? 0 : manager.microphoneLevel ?? 0,
                                  isClipping: manager.isMicrophoneClipping)
                }
            }
            if inputs.systemAudio {
                chip(.systemAudio, BarHover("System audio is recording"), "speaker.wave.2.fill", BarMetrics.systemAudioOn) {
                    BarAudioGlyph()
                }
            }
        }
        .opacity(manager.state == .paused ? 0.5 : 1)
    }

    private func chip<Proof: View>(_ id: BarTooltipID, _ hover: BarHover, _ symbol: String, _ color: Color,
                                   @ViewBuilder proof: @escaping () -> Proof) -> some View {
        BarToggleLabel(id: id, state: .on, hover: hover, offSymbol: symbol, onSymbol: symbol,
                       look: .input(color), proof: proof)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(hover.title)
    }
}
