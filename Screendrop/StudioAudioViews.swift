//
//  StudioAudioViews.swift
//  Screendrop
//
//  Audio-lane timeline views and audio-clip inspector controls for Recording
//  Studio: waveforms, fade shading and drag handles, multi-select, lane
//  mute/solo glyphs, audio-clip inspector page, and soundtrack sync control.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Slider formats

extension InspectorValueFormat {
    static let audioSeconds = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 1,
        suffix: "s",
        showsPositiveSign: false,
        step: 0.1,
        acceptedSuffixes: ["s", "sec", "seconds"]
    )

    static let signedMilliseconds = InspectorValueFormat(
        multiplier: 1000,
        fractionDigits: 0,
        suffix: " ms",
        showsPositiveSign: true,
        step: 0.01,
        acceptedSuffixes: ["ms", "msec", "milliseconds"]
    )
}

// MARK: - Audio lane

enum StudioAudioLaneMetrics {
    static let laneHeight: CGFloat = 36
    static let gutterWidth: CGFloat = 28
}

/// One audio lane built on `StudioBlockLane`: waveforms, fade shading and
/// handles, ⇧/⌘ multi-select, dragging in time (with snapping) and across
/// lanes, right-click context menu, and VoiceOver block actions.
struct StudioAudioLane: View {
    @Bindable var model: RecordingStudioModel
    let lane: Int
    let snaps: Bool
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let laneSpacing: CGFloat
    let onScrubbing: (Bool) -> Void
    /// While an edge is caught on a snap point, that point.
    let onSnapGuide: (TimeInterval?) -> Void

    @State private var fadeDragBase: (id: UUID, fadeIn: TimeInterval, fadeOut: TimeInterval)?

    /// How near, in points, an edge has to come to a snap point to catch.
    private static let snapDistance: CGFloat = 7
    private var laneStride: CGFloat { StudioAudioLaneMetrics.laneHeight + laneSpacing }

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedAudioClipID,
            scale: scale,
            height: StudioAudioLaneMetrics.laneHeight,
            empty: .scrub,
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: select,
                begin: { _ in model.beginAudioClipEdit() },
                edit: apply,
                end: { kind in
                    onSnapGuide(nil)
                    model.endAudioClipEdit(actionName: kind == .move ? "Move Audio" : "Trim Audio")
                }
            ),
            content: { block, state in content(for: block.item, state: state) },
            menu: { block in menu(for: block.item) },
            help: { block in
                if model.isAudioClipMissing(block.item) {
                    return "\(block.item.displayName) is missing from this project."
                }
                return block.item.end > model.duration + 0.01
                    ? "\(block.item.displayName). Continues past the end of the video."
                    : "\(block.item.displayName). Drag to move, drag an end to trim, ⇧-click to select more, right-click for more."
            },
            accessibility: { block in accessibility(for: block) }
        )
    }

    private func select(_ clip: RecordingAudioClip) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) || modifiers.contains(.command) {
            model.toggleAudioClipInSelection(id: clip.id)
        } else if model.selectedAudioClipIDs.contains(clip.id), model.selectedAudioClipIDs.count > 1 {
            // Pressing a clip that is part of a selection keeps the rest, so
            // the whole selection can be dragged together.
            model.selectedAudioClipID = clip.id
        } else {
            model.selectAudioClip(id: clip.id)
        }
    }

    private func accessibility(for block: StudioLaneBlock<RecordingAudioClip>) -> StudioBlockAccessibility {
        let clip = block.item
        var traits: [String] = []
        if clip.isMuted { traits.append("muted") }
        if model.isAudioClipMissing(clip) { traits.append("missing") }
        if clip.isLinked { traits.append("linked") }
        traits.append("lane \(clip.lane + 1)")
        let range = "\(studioPreciseTimecode(block.editorStart)) to \(studioPreciseTimecode(block.editorEnd))"
        return StudioBlockAccessibility(
            label: "Audio clip, \(clip.displayName)",
            value: "\(range), \(traits.joined(separator: ", "))"
        )
    }

    @ViewBuilder
    private func menu(for clip: RecordingAudioClip) -> some View {
        StudioAudioSplitMenuItem(model: model, clip: clip)
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.duplicateAudioClip(id: clip.id)
        }
        Divider()
        Button(clip.isMuted ? "Unmute" : "Mute", systemImage: clip.isMuted ? "speaker.wave.2" : "speaker.slash") {
            model.toggleAudioClipMuted(id: clip.id)
        }
        Button(
            clip.isLinked ? "Unlink from Video" : "Link to Video",
            systemImage: "link"
        ) {
            model.setAudioClipLinked(!clip.isLinked, id: clip.id)
        }
        if !clip.isLinked {
            Menu("Speed", systemImage: "hare") {
                ForEach(RecordingAudioClip.speedPresets, id: \.self) { speed in
                    Toggle(
                        speed == 1 ? "Normal (1×)" : RecordingClipSegment.speedTitle(speed),
                        isOn: Binding(
                            get: { abs(clip.speed - speed) < 0.001 },
                            set: { _ in model.setAudioClipSpeed(speed, id: clip.id) }
                        )
                    )
                }
            }
        }
        Divider()
        Button("Move Up a Lane", systemImage: "arrow.up") {
            model.moveAudioClip(id: clip.id, byLanes: -1)
        }
        .disabled(clip.lane == 0)
        Button("Move Down a Lane", systemImage: "arrow.down") {
            model.moveAudioClip(id: clip.id, byLanes: 1)
        }
        .disabled(clip.lane >= StudioAudioConform.maximumLanes - 1)
        Divider()
        Button("Delete Audio", systemImage: "trash", role: .destructive) {
            model.removeAudioClip(id: clip.id)
        }
    }

    /// Its name over a waveform of the stretch that plays, with its fades
    /// drawn in. A muted clip dims; what runs past the end of the video is
    /// hatched at the trailing edge, since it never plays.
    private func content(for clip: RecordingAudioClip, state: StudioBlockState) -> some View {
        let style = StudioBlockStyle.audio
        let pointsPerSecond = max(scale.pointsPerSecond, 1)
        let isAlsoSelected = !state.isSelected && model.selectedAudioClipIDs.contains(clip.id)
        let runsPastEnd = clip.end > model.duration + 0.01
        return ZStack(alignment: .topLeading) {
            StudioWaveform(
                peaks: model.waveformPeaks(for: clip),
                color: style.onTint.opacity(0.55),
                from: clip.trimStart,
                to: clip.trimStart + Double(state.width / pointsPerSecond) * clip.speed,
                gain: CGFloat(clip.volume)
            )
            .padding(.top, 13)
            .padding(.bottom, 3)
            .padding(.horizontal, 2)

            StudioFadeShade(
                fadeIn: CGFloat(min(clip.fadeIn, clip.duration / 2)) * pointsPerSecond,
                fadeOut: CGFloat(min(clip.fadeOut, clip.duration / 2)) * pointsPerSecond
            )

            let isMissing = model.isAudioClipMissing(clip)
            StudioBlockLabel(
                systemImage: isMissing ? "exclamationmark.triangle.fill" : clip.isMuted ? "speaker.slash.fill" : clip.isLinked ? "link" : glyph(for: clip),
                title: clip.displayName,
                detail: isMissing ? "Missing" : studioTimecode(clip.duration),
                state: state,
                color: isMissing ? Color(nsColor: .systemOrange) : style.onTint,
                verticalAlignment: .top
            )
            .padding(.top, 2)

            if runsPastEnd {
                StudioBlockHatch(color: style.onTint.opacity(0.35), spacing: 5, lineWidth: 1)
                    .frame(width: min(10, state.width))
                    .frame(width: state.width, height: state.height, alignment: .trailing)
                    .allowsHitTesting(false)
            }

            if state.isSelected, state.width >= 60 {
                fadeHandles(for: clip, state: state, pointsPerSecond: pointsPerSecond)
            }
        }
        .frame(width: state.width, height: state.height, alignment: .topLeading)
        .background { StudioBlockSurface(fill: style.fill(isHovering: state.isHovered)) }
        .overlay {
            // Part of a multiple selection, but not the one in the inspector:
            // a plain yellow rim, no handles.
            if isAlsoSelected {
                StudioBlockMetrics.shape
                    .strokeBorder(Color(nsColor: .systemYellow), lineWidth: 2)
                    .allowsHitTesting(false)
            } else if model.isAudioClipMissing(clip) {
                StudioBlockMetrics.shape
                    .strokeBorder(Color(nsColor: .systemOrange), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .opacity(clip.isMuted ? 0.45 : 1)
        .studioBlockClip()
    }

    /// Two dots along the top of the selected clip, one where each fade
    /// ends. Dragging one sets that fade without compounding against live updates.
    private func fadeHandles(for clip: RecordingAudioClip, state: StudioBlockState, pointsPerSecond: CGFloat) -> some View {
        let fadeLimit = min(RecordingAudioClip.fadeRange.upperBound, clip.duration / 2)
        let inX = CGFloat(min(clip.fadeIn, fadeLimit)) * pointsPerSecond
        let outX = state.width - CGFloat(min(clip.fadeOut, fadeLimit)) * pointsPerSecond
        return ZStack(alignment: .topLeading) {
            StudioFadeHandle()
                .offset(x: min(max(inX, 0), state.width) - StudioFadeHandle.size / 2, y: 1)
                .gesture(fadeDrag(clip: clip, fadesIn: true, pointsPerSecond: pointsPerSecond, limit: fadeLimit))
                .help("Fade In")
            StudioFadeHandle()
                .offset(x: min(max(outX, 0), state.width) - StudioFadeHandle.size / 2, y: 1)
                .gesture(fadeDrag(clip: clip, fadesIn: false, pointsPerSecond: pointsPerSecond, limit: fadeLimit))
                .help("Fade Out")
        }
        .frame(width: state.width, height: state.height, alignment: .topLeading)
    }

    private func fadeDrag(
        clip: RecordingAudioClip,
        fadesIn: Bool,
        pointsPerSecond: CGFloat,
        limit: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let base: (id: UUID, fadeIn: TimeInterval, fadeOut: TimeInterval)
                if let existing = fadeDragBase, existing.id == clip.id {
                    base = existing
                } else {
                    base = (clip.id, clip.fadeIn, clip.fadeOut)
                    fadeDragBase = base
                    model.beginAudioClipEdit()
                }
                let seconds = Double(value.translation.width / pointsPerSecond)
                var edited = clip
                if fadesIn {
                    edited.fadeIn = min(max(base.fadeIn + seconds, 0), limit)
                } else {
                    edited.fadeOut = min(max(base.fadeOut - seconds, 0), limit)
                }
                model.setAudioClip(edited)
            }
            .onEnded { _ in
                fadeDragBase = nil
                model.endAudioClipEdit(actionName: "Change Audio Fade")
            }
    }

    private func glyph(for clip: RecordingAudioClip) -> String {
        clip.source == .file ? "music.note" : "waveform"
    }

    private func apply(_ edit: StudioBlockEdit<RecordingAudioClip>) {
        let base = edit.base.item
        let minimum = RecordingAudioClip.minimumDuration
        let speed = max(base.speed, 0.01)
        let invertsSnapping = NSEvent.modifierFlags.contains(.command)
        switch edit.kind {
        case .move:
            var start = max(0, base.start + edit.delta)
            // Whichever end is nearer a snap point catches on it.
            let byStart = snapped(start, excluding: base.id, inverted: invertsSnapping)
            let byEnd = snapped(start + base.duration, excluding: base.id, inverted: invertsSnapping) - base.duration
            if byStart != start, abs(byStart - start) <= abs(byEnd - start) || byEnd == start {
                start = byStart
                onSnapGuide(byStart)
            } else if byEnd != start {
                start = byEnd
                onSnapGuide(byEnd + base.duration)
            } else {
                onSnapGuide(nil)
            }
            let lanes = Int((edit.verticalTranslation / laneStride).rounded())
            model.moveSelectedAudioClips(by: max(0, start) - base.start, lanes: lanes, anchor: base.id)
        case .trimLeading:
            let target = snapped(base.start + edit.delta, excluding: base.id, inverted: invertsSnapping)
            onSnapGuide(target != base.start + edit.delta ? target : nil)
            let shift = min(max(target - base.start, -base.trimStart / speed, -base.start), base.duration - minimum)
            var edited = base
            edited.start = base.start + shift
            edited.trimStart = base.trimStart + shift * speed
            model.setAudioClip(edited)
        case .trimTrailing:
            let target = snapped(base.end + edit.delta, excluding: base.id, inverted: invertsSnapping)
            onSnapGuide(target != base.end + edit.delta ? target : nil)
            var edited = base
            edited.trimEnd = min(max(base.trimEnd + (target - base.end) * speed, base.trimStart + minimum * speed), base.fileDuration)
            model.setAudioClip(edited)
        }
    }

    private func snapped(_ time: TimeInterval, excluding id: UUID, inverted: Bool) -> TimeInterval {
        guard snaps != inverted, scale.pointsPerSecond > 0 else { return time }
        return StudioAudioConform.snapped(
            time,
            to: StudioAudioConform.snapPoints(
                timeline: model.clipTimeline,
                clips: model.audioClips.filter { !model.selectedAudioClipIDs.contains($0.id) },
                excluding: id,
                playhead: model.currentTime
            ),
            tolerance: Double(Self.snapDistance / scale.pointsPerSecond)
        )
    }

    private var visibleBlocks: [StudioLaneBlock<RecordingAudioClip>] {
        let end = model.duration
        return model.audioClips
            .filter {
                $0.lane == lane && $0.start < end - 0.01
                    && $0.end >= visibleRange.lowerBound && $0.start <= visibleRange.upperBound
            }
            // What runs past the last frame is drawn up to it.
            .map { StudioLaneBlock(item: $0, editorStart: $0.start, editorEnd: min($0.end, end)) }
    }
}

/// "Split at Playhead" in an audio clip's context menu. Isolated so asking
/// for `model.currentTime` does not tie the whole lane to playback ticks.
private struct StudioAudioSplitMenuItem: View {
    let model: RecordingStudioModel
    let clip: RecordingAudioClip

    var body: some View {
        Button("Split at Playhead", systemImage: "scissors") {
            model.splitAudioClip(id: clip.id, at: model.currentTime)
        }
        .disabled(StudioAudioConform.split(clip, at: model.currentTime) == nil)
    }
}

/// Gutter button for one audio lane: click mutes/unmutes the lane, ⌥-click
/// solos/unsolos it.
struct StudioAudioLaneGlyph: View {
    @Bindable var model: RecordingStudioModel
    let lane: Int
    let height: CGFloat
    @Binding var soloState: (lane: Int, mutes: [UUID: Bool])?

    var body: some View {
        let isMuted = model.isAudioLaneMuted(lane)
        let isSoloed = soloState?.lane == lane
        let hasClips = model.audioClips.contains { $0.lane == lane }
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                if let solo = soloState {
                    model.restoreAudioMutes(solo.mutes)
                    soloState = nil
                    if solo.lane == lane { return }
                }
                soloState = (lane, model.soloAudioLane(lane))
            } else {
                soloState = nil
                model.setAudioLaneMuted(!isMuted, lane: lane)
            }
        } label: {
            Image(systemName: isSoloed ? "headphones" : isMuted ? "speaker.slash" : "waveform")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(isSoloed ? Palette.highlight : Palette.secondaryLabel)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasClips)
        .help("Audio \(lane + 1). Click to mute the lane, ⌥-click to hear it alone.")
        .accessibilityLabel("Audio \(lane + 1)")
        .accessibilityValue(isSoloed ? "Soloed" : isMuted ? "Muted" : "Active")
    }
}

/// Frame around an audio lane, pinned to the viewport while audio clips scroll
/// inside it.
struct StudioAudioLaneBackground: View {
    var showsHint = false
    var isDropTarget = false

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: StudioBlockMetrics.cornerRadius + StudioBlockMetrics.inset,
            style: .continuous
        )
        shape
            .fill(isDropTarget ? Palette.highlight.opacity(0.12) : Color.primary.opacity(0.055))
            .overlay {
                if isDropTarget {
                    shape.strokeBorder(Palette.highlight.opacity(0.65), lineWidth: 1.5)
                }
            }
            .overlay {
                if showsHint {
                    Label("Drop audio here or click + Audio", systemImage: "waveform.badge.plus")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

/// The dot that sets a fade.
private struct StudioFadeHandle: View {
    static let size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemYellow))
            .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5) }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle().inset(by: -4))
    }
}

/// A clip's fades: the block darkens toward the end it fades from, under a
/// line tracing the level.
private struct StudioFadeShade: View {
    let fadeIn: CGFloat
    let fadeOut: CGFloat

    var body: some View {
        Canvas { context, size in
            func ramp(from edge: CGFloat, to inner: CGFloat) {
                guard abs(inner - edge) >= 3 else { return }
                var wedge = Path()
                wedge.move(to: CGPoint(x: edge, y: 0))
                wedge.addLine(to: CGPoint(x: inner, y: 0))
                wedge.addLine(to: CGPoint(x: edge, y: size.height))
                wedge.closeSubpath()
                context.fill(wedge, with: .color(.black.opacity(0.28)))
                var line = Path()
                line.move(to: CGPoint(x: edge, y: size.height))
                line.addLine(to: CGPoint(x: inner, y: 0))
                context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            ramp(from: 0, to: min(fadeIn, size.width / 2))
            ramp(from: size.width, to: size.width - min(fadeOut, size.width / 2))
        }
        .allowsHitTesting(false)
    }
}

/// Rounded bars of an audio file's loudness between two file times.
struct StudioWaveform: View {
    let peaks: [Float]
    let color: Color
    let from: TimeInterval
    let to: TimeInterval
    /// Scales the bars with the clip's level.
    var gain: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, to > from, size.width > 4 else { return }
            let perSecond = Double(RecordingAudioPeaks.peaksPerSecond)
            let bar: CGFloat = 2
            let gap: CGFloat = 2
            var path = Path()
            var clipped = Path()
            var x: CGFloat = gap
            while x < size.width - bar {
                let t0 = from + Double(x / size.width) * (to - from)
                let t1 = from + Double((x + bar) / size.width) * (to - from)
                let i0 = max(0, Int(t0 * perSecond))
                let i1 = min(peaks.count, max(i0 + 1, Int(t1 * perSecond)))
                var value: Float = 0
                if i0 < i1 {
                    for index in i0..<i1 { value = max(value, peaks[index]) }
                }
                let level = CGFloat(value) * gain
                let height = max(bar, min(1, level) * size.height)
                if level > 1 {
                    clipped.addRoundedRect(
                        in: CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height),
                        cornerSize: CGSize(width: bar / 2, height: bar / 2)
                    )
                    x += bar + gap
                    continue
                }
                path.addRoundedRect(
                    in: CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height),
                    cornerSize: CGSize(width: bar / 2, height: bar / 2)
                )
                x += bar + gap
            }
            context.fill(path, with: .color(color))
            context.fill(clipped, with: .color(Color(nsColor: .systemOrange)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Audio clip inspector

/// Per-clip inspector controls for a selected `RecordingAudioClip`:
/// volume, mute, fades, linked/unlinked toggle, unlinked speed presets,
/// split at playhead, and duplicate.
struct StudioAudioClipInspectorControls: View {
    @Bindable var model: RecordingStudioModel
    let clip: RecordingAudioClip

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            if model.isAudioClipMissing(clip) {
                InspectorHint(
                    "Audio file “\(clip.displayName)” is missing from this project. Export will fail until it is muted or removed.",
                    tint: .orange
                )
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorFieldPair {
                    InspectorSlider(
                        "Volume",
                        value: value(\.volume, action: "Change Audio Volume"),
                        range: CGFloat(RecordingAudioClip.volumeRange.lowerBound)...CGFloat(RecordingAudioClip.volumeRange.upperBound),
                        format: .percent()
                    )
                    .disabled(clip.isMuted)
                } trailing: {
                    InspectorActionButton(
                        clip.isMuted ? "Unmute" : "Mute",
                        systemImage: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2"
                    ) {
                        model.toggleAudioClipMuted(id: clip.id)
                    }
                    .help("Silence this clip")
                }

                InspectorSlider(
                    "Fade In",
                    value: value(\.fadeIn, action: "Change Audio Fade"),
                    range: CGFloat(RecordingAudioClip.fadeRange.lowerBound)...CGFloat(RecordingAudioClip.fadeRange.upperBound),
                    format: .audioSeconds
                )

                InspectorSlider(
                    "Fade Out",
                    value: value(\.fadeOut, action: "Change Audio Fade"),
                    range: CGFloat(RecordingAudioClip.fadeRange.lowerBound)...CGFloat(RecordingAudioClip.fadeRange.upperBound),
                    format: .audioSeconds
                )
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorToggleRow(
                    "Cut with the video",
                    isOn: Binding(
                        get: { clip.isLinked },
                        set: { model.setAudioClipLinked($0, id: clip.id) }
                    )
                )

                if clip.isLinked {
                    InspectorHint("Linked: cutting, trimming or speeding up the video above does the same to this sound. Plays \(Self.clock(clip.fileSpan)) of its \(Self.clock(clip.fileDuration)) file.")
                } else {
                    InspectorSegmented(
                        options: RecordingAudioClip.speedPresets,
                        isSelected: { abs($0 - clip.speed) < 0.001 },
                        onTap: { model.setAudioClipSpeed($0, id: clip.id) },
                        label: { Text(RecordingClipSegment.speedTitle($0)).font(.inspectorSegment) }
                    )
                    .help("How fast this clip plays. It keeps its start.")
                    InspectorHint("Not linked: stays whole when the video is cut, and keeps its starting moment. Plays \(Self.clock(clip.fileSpan)) of its \(Self.clock(clip.fileDuration)) file.")
                }

                HStack(spacing: InspectorMetrics.rowSpacing) {
                    StudioAudioSplitButton(model: model, clip: clip)

                    InspectorActionButton("Duplicate", systemImage: "plus.square.on.square") {
                        model.duplicateAudioClip(id: clip.id)
                    }
                    .help("Place a copy straight after it")
                }
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        return total < 60
            ? String(format: "%.1fs", total)
            : String(format: "%d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }

    private func value(_ keyPath: WritableKeyPath<RecordingAudioClip, Double>, action: String) -> Binding<CGFloat> {
        Binding(
            get: { CGFloat(clip[keyPath: keyPath]) },
            set: { value in
                var edited = clip
                edited[keyPath: keyPath] = Double(value)
                model.editAudioClip(edited, actionName: action)
            }
        )
    }
}

/// Isolated Split button so reading `model.currentTime` does not redraw the
/// whole inspector page on every playback tick.
private struct StudioAudioSplitButton: View {
    let model: RecordingStudioModel
    let clip: RecordingAudioClip

    var body: some View {
        InspectorActionButton("Split", systemImage: "scissors") {
            model.splitAudioClip(id: clip.id, at: model.currentTime)
        }
        .disabled(StudioAudioConform.split(clip, at: model.currentTime) == nil)
        .help("Split at the playhead (⌘B)")
    }
}

/// ±1s offset slider for lining up an imported replacement soundtrack.
struct StudioSoundtrackSyncSlider: View {
    @Bindable var model: RecordingStudioModel

    var body: some View {
        InspectorSlider(
            "Sync",
            value: Binding(
                get: { CGFloat(model.replacementAudioSync?.offset ?? 0) },
                set: { model.setReplacementAudioOffset(Double($0)) }
            ),
            range: -CGFloat(RecordingAudioSync.offsetLimit)...CGFloat(RecordingAudioSync.offsetLimit),
            format: .signedMilliseconds
        )
        .help("Slide the soundtrack earlier or later against the picture")
    }
}
