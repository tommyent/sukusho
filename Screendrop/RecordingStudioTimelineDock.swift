//
//  RecordingStudioTimelineDock.swift
//  Screendrop
//
//  The Recording Studio timeline dock: control row with the + add menu,
//  top-edge vertical resize, leading glyph gutter, ruler with ink marks and
//  chapters, Finder drag-and-drop onto tracks, and multi-track lanes (Text,
//  Images & Effects, Clips, Zooms — with room for Audio lanes).
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Timeline

struct StudioTimelineEditor: View {
    @Bindable var model: RecordingStudioModel

    /// Horizontal scale of the lanes, as a multiplier over "the whole
    /// recording fits the viewport". Zoom 1 is the timeline's original
    /// fixed-width layout; anything above it scrolls.
    @State private var zoom: Double = 1
    @State private var viewportWidth: CGFloat = 1
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var isScrubbing = false
    @State private var isResetClipsConfirmationPresented = false
    /// Isolated snap-guide state so showing/moving the yellow guide during a
    /// trim or audio drag only invalidates `StudioSnapGuideOverlay`, never the lane stack.
    @State private var snapGuide = StudioSnapGuideState()
    /// Anchor time while ⇧-dragging on the ruler to mark an I/O range.
    @State private var rangeAnchor: TimeInterval?
    @GestureState private var isRulerGestureActive = false
    /// The + has opened into Text, Pixelate, Audio, and Media.
    @State private var isAddOpen = false
    /// Files being dragged over the tracks from Finder.
    @State private var mediaDrop: StudioMediaDrop?
    /// The pointer's position over the lanes, isolated in an object so hover
    /// doesn't rebuild the whole dock.
    @State private var skim = StudioSkimState()
    /// Height given to the scrolling tracks by dragging the dock's top edge;
    /// 0 shows every track.
    @AppStorage("StudioTimelineTracksHeight") private var storedTracksHeight: Double = 0
    @State private var resizeBase: CGFloat?
    @State private var scrollY: CGFloat = 0
    @State private var verticalScrollPosition = ScrollPosition(edge: .top)
    @Namespace private var glass

    /// Below this track width the opened + shows bare glyphs so edit tools
    /// never run under the transport.
    private static let addLabelsMinimumWidth: CGFloat = 780
    /// Step per zoom button press / keyboard shortcut.
    private static let zoomStep: Double = 1.6
    /// How close to the viewport edge the playhead may drift before the
    /// lanes scroll to keep it in sight.
    private static let followMargin: CGFloat = 48

    private var scale: StudioTimelineScale {
        StudioTimelineScale(
            viewportWidth: viewportWidth,
            duration: model.duration,
            zoom: zoom
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            transport
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                trackGutter
                lanes
            }
            .overlay(alignment: .bottom) {
                if fullTracksHeight - visibleTracksHeight - scrollY > 1 {
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0),
                            Color(nsColor: .windowBackgroundColor)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
        .overlay(alignment: .top) { resizeHandle }
    }

    // MARK: Height & resize

    private var tracks: [StudioTrack] {
        // Order top to bottom: overlays above video, camera cues and audio lanes below.
        [.text, .overlay, .clips, .zooms] + (0..<model.audioLaneCount).map(StudioTrack.audio)
    }

    private var fullTracksHeight: CGFloat {
        StudioTimelineMetrics.scrollingLanesHeight(tracks: tracks)
    }

    private var visibleTracksHeight: CGFloat {
        let full = fullTracksHeight
        guard storedTracksHeight > 0 else { return full }
        return min(full, max(StudioTimelineMetrics.minimumTracksHeight, CGFloat(storedTracksHeight)))
    }

    /// Top edge trades height between the preview and the tracks. Double-click
    /// opens the dock back up to every track.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = resizeBase ?? visibleTracksHeight
                        if resizeBase == nil { resizeBase = base }
                        let full = fullTracksHeight
                        let height = min(full, max(StudioTimelineMetrics.minimumTracksHeight, base - value.translation.height))
                        storedTracksHeight = height >= full - 0.5 ? 0 : Double(height)
                        keepClipsInView(height: height)
                    }
                    .onEnded { _ in resizeBase = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.foldIfAllowed) { storedTracksHeight = 0 }
            }
            .help("Drag to resize the timeline. Double-click to show every track.")
            .offset(y: -3)
    }

    /// Shrinking the tracks scrolls them so the clips stay on screen.
    private func keepClipsInView(height: CGFloat) {
        var top: CGFloat = 0
        for track in tracks {
            if track == .clips { break }
            top += track.height + StudioTimelineMetrics.trackSpacing
        }
        let bottom = top + StudioTrack.clips.height
        if scrollY > top {
            scrollY = top
            verticalScrollPosition.scrollTo(y: top)
        } else if scrollY + height < bottom {
            scrollY = bottom - height
            verticalScrollPosition.scrollTo(y: bottom - height)
        }
    }

    // MARK: Gutter & tracks

    private var trackGutter: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: StudioTimelineMetrics.headerHeight + StudioTimelineMetrics.trackSpacing)
            VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                ForEach(tracks) { track in
                    if case .audio(let lane) = track {
                        StudioAudioLaneGlyph(
                            model: model,
                            lane: lane,
                            height: track.height
                        )
                    } else {
                        Image(systemName: track.systemImage)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Palette.secondaryLabel)
                            .frame(maxWidth: .infinity)
                            .frame(height: track.height)
                            .contentShape(Rectangle())
                            .help(track.title)
                            .accessibilityLabel(track.title)
                    }
                }
            }
            .offset(y: -scrollY)
            .frame(height: visibleTracksHeight, alignment: .top)
            .clipped()
        }
        .frame(width: StudioTimelineMetrics.gutterWidth)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
        }
    }

    private var lanes: some View {
        GeometryReader { proxy in
            // The proxy width leads the stored one by a frame, so lay the
            // lanes out from it and keep the state copy for the controls.
            let scale = StudioTimelineScale(
                viewportWidth: max(proxy.size.width, 1),
                duration: model.duration,
                zoom: zoom
            )

            VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                    StudioTimelineRuler(
                        duration: model.duration,
                        pointsPerSecond: scale.pointsPerSecond,
                        scrollX: scrollX,
                        range: model.rangeSelection
                    )
                    .frame(height: StudioTimelineMetrics.rulerHeight)
                }
                .contentShape(Rectangle())
                .gesture(rulerGesture(scale: scale, scrollX: scrollX))
                .onChange(of: isRulerGestureActive) { _, active in
                    if !active { finishRulerGesture() }
                }

                ScrollView(.vertical) {
                    scrollingLanes(scale: scale)
                }
                .scrollPosition($verticalScrollPosition)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    if abs(offset - scrollY) > 0.01 {
                        scrollY = offset
                    }
                }
                .frame(height: visibleTracksHeight)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    skim.x = location.x
                    let hovered = track(atY: location.y)?.id
                    if skim.trackID != hovered { skim.trackID = hovered }
                    if !model.isDraggingTimelineBlock {
                        model.hoverPreviewTime = scale.time(forX: location.x + scrollX)
                    }
                case .ended:
                    skim.x = nil
                    skim.trackID = nil
                    model.hoverPreviewTime = nil
                }
            }
            .overlay {
                StudioTimelineInkMarks(model: model, scale: scale, scrollX: scrollX)
            }
            .overlay {
                StudioTimelineMarkers(model: model, scale: scale, scrollX: scrollX)
            }
            .overlay {
                StudioTimelineChapters(
                    model: model,
                    scale: scale,
                    scrollX: scrollX,
                    isScrubbing: isScrubbing,
                    onPlayheadMove: followPlayhead(to:)
                )
            }
            .overlay(alignment: .topLeading) {
                StudioSnapGuideOverlay(
                    state: snapGuide,
                    scale: scale,
                    scrollX: scrollX,
                    size: proxy.size
                )
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
            .onDrop(of: [.fileURL], delegate: StudioMediaDropDelegate(
                canDrop: model.canImportMedia,
                time: { scale.time(forX: $0.x + scrollX) },
                onPreview: { preview in
                    if preview != mediaDrop { mediaDrop = preview }
                },
                onDrop: { urls, time in
                    model.importMedia(urls, atEditorTime: time)
                }
            ))
        }
        .frame(height: StudioTimelineMetrics.headerHeight + StudioTimelineMetrics.trackSpacing + visibleTracksHeight)
        .alert(
            "Some files weren't added",
            isPresented: Binding(
                get: { model.mediaImportError != nil },
                set: { if !$0 { model.mediaImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.mediaImportError = nil }
        } message: {
            Text(model.mediaImportError ?? "")
        }
        .onChange(of: model.duration) { _, _ in clampZoom() }
    }

    /// The tracks that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and track
    /// grounds stay viewport-sized and redraw against `scrollX` instead.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                ForEach(tracks) { track in
                    let isDropTarget = mediaDrop?.tracks.contains(track) == true
                    StudioTrackGround(
                        hint: isDropTarget ? dropHint(for: track) : hint(for: track),
                        dropX: isDropTarget ? mediaDrop.map { scale.x(for: $0.time) - scrollX } : nil,
                        trackID: track.id,
                        skim: skim
                    )
                    .frame(height: track.height)
                }
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.trackSpacing) {
                    ForEach(tracks) { track in
                        laneContent(for: track, scale: scale)
                            .frame(width: scale.contentWidth, height: track.height)
                    }

                    Color.clear
                        .frame(height: StudioTimelineMetrics.scrollerGutter)
                }
            }
            .scrollPosition($scrollPosition)
            // Blocks and clips land where an edit puts them, even when the
            // edit came from an animated inspector or tool-row action.
            .transaction { $0.animation = nil }
            .scrollIndicators(scale.isScrollable ? .visible : .never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                if abs(offset - scrollX) > 0.01 {
                    scrollX = offset
                }
            }
        }
        .frame(height: StudioTimelineMetrics.scrollingLanesHeight(tracks: tracks))
    }

    @ViewBuilder
    private func laneContent(for track: StudioTrack, scale: StudioTimelineScale) -> some View {
        let visibleRange = scale.visibleRange(scrollX: scrollX)
        switch track {
        case .text:
            StudioTextLane(
                model: model,
                scale: scale,
                visibleRange: visibleRange,
                onScrubbing: { isScrubbing = $0 }
            )
        case .overlay:
            StudioRedactionLane(
                model: model,
                scale: scale,
                visibleRange: visibleRange,
                onScrubbing: { isScrubbing = $0 }
            )
        case .clips:
            clipLane
        case .zooms:
            StudioZoomLane(
                model: model,
                scale: scale,
                visibleRange: visibleRange,
                onScrubbing: { isScrubbing = $0 }
            )
        case .audio(let lane):
            StudioAudioLane(
                model: model,
                lane: lane,
                snaps: model.snapsEdits,
                scale: scale,
                visibleRange: visibleRange,
                laneSpacing: StudioTimelineMetrics.trackSpacing,
                onScrubbing: { isScrubbing = $0 },
                onSnapGuide: { if snapGuide.time != $0 { snapGuide.time = $0 } }
            )
        }
    }

    private func track(atY y: CGFloat) -> StudioTrack? {
        var top = StudioTimelineMetrics.headerHeight + StudioTimelineMetrics.trackSpacing - scrollY
        guard y >= StudioTimelineMetrics.headerHeight else { return nil }
        for track in tracks {
            if y >= top, y < top + track.height { return track }
            top += track.height + StudioTimelineMetrics.trackSpacing
        }
        return nil
    }

    private func dropHint(for track: StudioTrack) -> String? {
        switch track {
        case .overlay: "Drop to add over the video"
        case .audio(0): "Drop to add audio"
        default: nil
        }
    }

    private func hint(for track: StudioTrack) -> String? {
        switch track {
        case .text:
            model.textOverlays.isEmpty ? "Drag across to add text" : nil
        case .overlay:
            model.redactions.isEmpty && model.imageOverlays.isEmpty
                ? "Add images and GIFs, or pixelate part of the picture, with +"
                : nil
        case .clips:
            nil
        case .zooms:
            model.zoomEnabled && model.zoomTimelineBlocks.isEmpty ? "Drag across to add a zoom" : nil
        case .audio(0):
            model.audioClips.isEmpty && model.canImportAudioMedia
                ? "Drop audio files or add with +"
                : nil
        case .audio:
            nil
        }
    }

    private var clipLane: some View {
        RecordingClipTimelineView(
            selectedClipID: model.selectedClipID,
            playheadTime: $model.currentTime,
            timeline: model.clipTimeline,
            sourceDuration: model.sourceDuration,
            thumbnails: model.timelineThumbnails,
            onSelect: { model.selectClip(id: $0) },
            onSeek: { time in
                model.pause()
                model.seek(to: time)
            },
            onHover: { time in
                guard !model.isTrimmingClip, !model.isDraggingTimelineBlock else { return }
                model.hoverPreviewTime = time
            },
            onSplit: { model.splitClip(at: $0) },
            onDelete: { deleteSelection() },
            onTrim: { model.trimClip($0) },
            onZoom: { factor, anchorTime in
                applyZoom(factor: factor, anchorTime: anchorTime)
            },
            onStep: { seconds in
                model.pause()
                model.seek(to: model.currentTime + seconds)
            },
            onScrubbing: { isScrubbing = $0 },
            onReorder: { model.moveClip(id: $0, to: $1) },
            snapPoints: model.clipSnapPoints,
            snaps: model.snapsEdits,
            onSnapGuide: { if snapGuide.time != $0 { snapGuide.time = $0 } },
            onTrimPreview: { model.previewSourceTime($0) },
            allowsKeyboardShortcuts: {
                model.isLoaded && !model.isRestoringDocument && !model.isEditingSourceRegion
            },
            canDetachAudio: { model.canDetachAudio(fromClipID: $0) },
            onDetachAudio: { model.detachAudio(fromClipID: $0) },
            onToggleMute: { model.toggleClipMuted(id: $0) }
        )
    }

    /// Plain drag on the ruler scrubs and clears any range; ⇧-drag marks an
    /// I/O range band (as I and O do).
    private func rulerGesture(scale: StudioTimelineScale, scrollX offset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isRulerGestureActive) { _, active, _ in
                active = true
            }
            .onChanged { value in
                guard model.isLoaded, model.duration > 0 else { return }
                let time = scale.time(forX: value.location.x + offset)
                if rangeAnchor == nil, !isScrubbing, NSEvent.modifierFlags.contains(.shift) {
                    model.pause()
                    model.clearTimelineSelection()
                    rangeAnchor = scale.time(forX: value.startLocation.x + offset)
                }
                if let anchor = rangeAnchor {
                    model.rangeSelection = min(anchor, time)...max(anchor, time)
                    return
                }
                if !isScrubbing {
                    isScrubbing = true
                    model.pause()
                    model.clearRange()
                }
                model.seek(to: time)
            }
            .onEnded { _ in
                finishRulerGesture()
            }
    }

    private func finishRulerGesture() {
        if let range = model.rangeSelection, rangeAnchor != nil,
           range.upperBound - range.lowerBound <= 0.000_5 {
            model.clearRange()
        }
        rangeAnchor = nil
        isScrubbing = false
    }

    // MARK: Zoom & scroll

    /// Rescales around `anchorTime`, keeping that moment under the same
    /// screen position so pinching or ⌘-scrolling doesn't shove the edit
    /// you were aiming at out of the viewport.
    private func applyZoom(factor: Double, anchorTime: TimeInterval?) {
        let current = scale
        guard current.duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = anchorTime ?? current.time(forX: scrollX + viewportWidth / 2)
        let anchorViewportX = current.x(for: anchor) - scrollX
        let next = min(max(zoom * factor, 1), current.maxZoom)
        guard abs(next - zoom) > 0.0001 else { return }

        // A pinch arrives as dozens of small steps; let the storyboard scale
        // with the lane and resample once the gesture settles.
        model.timelineThumbnails.deferSampling()
        zoom = next
        var zoomed = current
        zoomed.zoom = next
        scroll(to: zoomed.x(for: anchor) - anchorViewportX, in: zoomed)
    }

    private func fitTimeline() {
        guard zoom > 1 else { return }
        zoom = 1
        scrollX = 0
        scrollPosition.scrollTo(edge: .leading)
    }

    /// Keeps the zoom inside range after the viewport or the edited duration
    /// changes - a cut or a wider window can leave the old scale past the cap.
    private func clampZoom() {
        let clamped = min(max(zoom, 1), scale.maxZoom)
        if abs(clamped - zoom) > 0.0001 {
            zoom = clamped
        }
    }

    private func followPlayhead(to time: TimeInterval) {
        let current = scale
        guard current.isScrollable else { return }
        let x = current.x(for: time)
        guard x < scrollX + Self.followMargin
            || x > scrollX + viewportWidth - Self.followMargin else { return }
        // While playing, land the playhead a third in so there is room to
        // watch what is coming; a seek just centers it.
        let inset = model.isPlaying ? viewportWidth / 3 : viewportWidth / 2
        scroll(to: x - inset, in: current)
    }

    private func scroll(to x: CGFloat, in scale: StudioTimelineScale) {
        let clamped = min(max(x, 0), max(0, scale.contentWidth - scale.viewportWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Zoom buttons keep the playhead pinned when it is on screen, so the
    /// scale grows around the edit point rather than the viewport middle.
    private var buttonZoomAnchor: TimeInterval {
        let x = scale.x(for: model.currentTime)
        if x >= scrollX, x <= scrollX + viewportWidth {
            return model.currentTime
        }
        return scale.time(forX: scrollX + viewportWidth / 2)
    }

    // MARK: Control row

    private var transport: some View {
        ZStack {
            HStack(spacing: 0) {
                editControls
                Spacer(minLength: 0)
                zoomControls
            }

            playbackControls
        }
        .frame(height: 36)
        .motion(.morph, value: [isAddOpen, canDeleteSelection, model.hasClipEdits, zoom > 1.0001])
    }

    private var editControls: some View {
        HStack(spacing: 6) {
            GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                HStack(spacing: GlassMetrics.gap) {
                    GlassIconButton(systemImage: "scissors", help: "Split at Playhead (⌘B)") {
                        if let audioID = model.selectedAudioClipID {
                            model.splitAudioClip(id: audioID, at: model.currentTime)
                        } else {
                            model.splitClip(at: model.currentTime)
                        }
                    }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!model.isLoaded)
                    .glassEffectID("split", in: glass)

                    addTools

                    if canDeleteSelection {
                        GlassIconButton(systemImage: "trash", help: "Delete Selection") {
                            deleteSelection()
                        }
                        .glassEffectID("delete", in: glass)
                    }

                    if model.hasClipEdits {
                        GlassIconButton(systemImage: "arrow.counterclockwise", help: "Reset All Clip Edits…") {
                            isResetClipsConfirmationPresented = true
                        }
                        .glassEffectID("resetClips", in: glass)
                    }

                    GlassIconButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)") {
                        model.undo()
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                    .glassEffectID("undo", in: glass)
                    .padding(.leading, 4)

                    GlassIconButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") {
                        model.redo()
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
                    .glassEffectID("redo", in: glass)
                }
            }
            .confirmationDialog(
                "Reset all clip edits?",
                isPresented: $isResetClipsConfirmationPresented
            ) {
                Button("Reset Clips", role: .destructive) {
                    model.resetClips()
                }
            } message: {
                Text("Every split, trim, deletion and speed change goes back to the original recording. You can undo this.")
            }
        }
    }

    /// One + button that opens into Text, Pixelate/Blur, and Media, then folds
    /// back once one is picked.
    @ViewBuilder
    private var addTools: some View {
        GlassIconButton(
            systemImage: isAddOpen ? "xmark" : "plus",
            help: isAddOpen ? "Close" : "Add Text, Pixelate or Media"
        ) {
            withAnimation(.morphIfAllowed) { isAddOpen.toggle() }
        }
        .disabled(!model.isLoaded)
        .motion(.morphQuick, value: isAddOpen)
        .glassEffectID("add", in: glass)

        if isAddOpen {
            addTool("Text", systemImage: "textformat", help: "Add Text at Playhead") {
                model.addText(atEditorTime: model.currentTime)
            }
            .glassEffectID("text", in: glass)

            addTool("Pixelate", systemImage: "squareshape.split.3x3", help: "Pixelate or Blur Part of the Picture") {
                model.addRedaction(atEditorTime: model.currentTime, mode: .pixelate)
            }
            .glassEffectID("pixelate", in: glass)

            addTool(
                "Media",
                systemImage: "photo.badge.plus",
                help: model.mediaDirectoryURL == nil
                    ? "Save this recording as a project to add images and GIFs"
                    : "Add Images or Animated GIFs at Playhead"
            ) {
                pickMedia()
            }
            .disabled(!model.canImportMedia)
            .glassEffectID("media", in: glass)
        }
    }

    @ViewBuilder
    private func addTool(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let run = {
            model.pause()
            withAnimation(.morphIfAllowed) {
                isAddOpen = false
                action()
            }
        }
        if viewportWidth >= Self.addLabelsMinimumWidth {
            GlassCapsuleButton(title: title, systemImage: systemImage, action: run)
                .help(help)
        } else {
            GlassIconButton(systemImage: systemImage, help: help, action: run)
        }
    }

    private func pickMedia() {
        model.pause()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // neon-studio-audio adds `.audio` to allowedContentTypes when audio clips land.
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        panel.message = "Images and animated GIF, APNG, WebP, or HEIC files go over the video."
        let time = model.currentTime
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.importMedia(panel.urls, atEditorTime: time)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            if zoom > 1.0001 {
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            StudioTransportTray {
                timelineButton("Zoom Out (⌘-)", systemImage: "minus.magnifyingglass") {
                    applyZoom(factor: 1 / Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.0001)

                timelineButton("Zoom In (⌘=)", systemImage: "plus.magnifyingglass") {
                    applyZoom(factor: Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom >= scale.maxZoom - 0.0001)

                timelineButton("Fit Timeline (⌘0)", systemImage: "arrow.left.and.right") {
                    fitTimeline()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom <= 1.0001)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                StudioTimecodeField(model: model)
                    .frame(width: model.duration >= 3600 ? 74 : 58, alignment: .trailing)
                Text(" / \(studioPreciseTimecode(model.duration))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            HStack(spacing: 4) {
                timelineButton("Back to Start (Home)", systemImage: "backward.end.fill") {
                    model.pause()
                    model.seek(to: 0)
                }

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .disabled(!model.isLoaded || model.isRestoringDocument)

                timelineButton("Skip to End (End)", systemImage: "forward.end.fill") {
                    model.pause()
                    model.seek(to: model.duration)
                }
            }

            if model.isPlaying, model.shuttleRate != 1 {
                Text(RecordingStudioModel.shuttleTitle(model.shuttleRate))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .fixedSize()
            }
        }
    }

    private var canDeleteSelection: Bool {
        model.selectedTextID != nil
            || model.selectedImageID != nil
            || model.selectedRedactionID != nil
            || model.selectedAudioClipID != nil
            || model.selectedCueID != nil
            || model.canDeleteSelectedClip
            || model.rangeSelection != nil
    }

    private func deleteSelection() {
        if let textID = model.selectedTextID {
            model.removeText(id: textID)
        } else if let imageID = model.selectedImageID {
            model.removeImage(id: imageID)
        } else if let redactionID = model.selectedRedactionID {
            model.removeRedaction(id: redactionID)
        } else if let audioID = model.selectedAudioClipID {
            model.removeAudioClip(id: audioID)
        } else if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if model.canDeleteSelectedClip {
            model.deleteSelectedClip()
        } else if model.rangeSelection != nil {
            model.deleteRange()
        }
    }

    private func pickAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Add Audio to Timeline"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            model.importAudioFiles(panel.urls, atEditorTime: model.currentTime)
        }
    }

    private func timelineButton(
        _ help: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(TransportIconButtonStyle(isActive: isActive))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A quiet filled tray grouping related transport buttons, the same
/// treatment as the annotator's tool grid.
private enum StudioTransportMetrics {
    static let buttonRadius: CGFloat = 6
    static let trayInset: CGFloat = 2
}

private struct StudioTransportTray<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nested radius: the tray wraps buttons inset by `inset`.
        let shape = RoundedRectangle(
            cornerRadius: StudioTransportMetrics.buttonRadius + StudioTransportMetrics.trayInset,
            style: .continuous
        )
        HStack(spacing: 0) {
            content()
        }
        .padding(StudioTransportMetrics.trayInset)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
    }
}

private struct TransportIconButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isActive && isEnabled
                    ? Palette.highlight
                    : Color.primary.opacity(
                        isEnabled ? (configuration.isPressed || isHovering ? 0.95 : 0.78) : 0.25
                    )
            )
            .background {
                RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous)
                    .fill(
                        isActive && isEnabled
                            ? Palette.highlight.opacity(configuration.isPressed ? 0.22 : 0.14)
                            : Color.primary.opacity(
                                isEnabled ? (configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0) : 0
                            )
                    )
            }
            .onHover { isHovering = $0 }
    }
}

// MARK: - Track layout & metrics

private enum StudioTimelineMetrics {
    static let trackSpacing: CGFloat = 4
    static let gutterWidth: CGFloat = 40
    static let playheadLaneHeight: CGFloat = 18
    static let rulerHeight: CGFloat = 20
    static let headerHeight = playheadLaneHeight + rulerHeight
    /// Room under the last track for the horizontal scroller.
    static let scrollerGutter: CGFloat = 6
    /// Shortest the tracks get when dragged down: clips and their breathing room.
    static let minimumTracksHeight: CGFloat = 64

    static func scrollingLanesHeight(tracks: [StudioTrack]) -> CGFloat {
        tracks.reduce(scrollerGutter) { $0 + $1.height + trackSpacing }
    }
}

/// A row of the timeline, named by its glyph in the leading gutter.
private enum StudioTrack: Hashable, Identifiable {
    case text
    case overlay
    case clips
    case zooms
    case audio(Int)

    var id: String {
        switch self {
        case .text: "text"
        case .overlay: "overlay"
        case .clips: "clips"
        case .zooms: "zooms"
        case .audio(let lane): "audio-\(lane)"
        }
    }

    var height: CGFloat {
        switch self {
        case .clips: 56
        case .text, .overlay, .zooms: 30
        case .audio: StudioAudioLaneMetrics.laneHeight
        }
    }

    var systemImage: String {
        switch self {
        case .text: "character.textbox"
        case .overlay: "square.3.layers.3d"
        case .clips: "video"
        case .zooms: "viewfinder"
        case .audio: "waveform"
        }
    }

    var title: String {
        switch self {
        case .text: "Text"
        case .overlay: "Images and Effects"
        case .clips: "Clips"
        case .zooms: "Zooms"
        case .audio(let lane): "Audio \(lane + 1)"
        }
    }
}

/// The pointer's place over the lanes, in viewport points.
@MainActor
@Observable
private final class StudioSkimState {
    var x: CGFloat?
    var trackID: String?
}

/// The flat, full-width ground a track sits on. Stays pinned to the viewport
/// while blocks scroll over it, shows hover hints when empty, and lights up
/// with a drop-point bar while files from Finder hang over it.
private struct StudioTrackGround: View {
    let hint: String?
    var dropX: CGFloat? = nil
    let trackID: String
    let skim: StudioSkimState

    private var showsHint: Bool {
        hint != nil && (dropX != nil || skim.trackID == trackID)
    }

    var body: some View {
        Rectangle()
            .fill(dropX == nil ? Color.primary.opacity(0.04) : Palette.highlight.opacity(0.12))
            .overlay(alignment: .leading) {
                if showsHint, let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(dropX == nil ? Palette.tertiaryLabel : Palette.highlight)
                        .lineLimit(1)
                        .padding(.leading, 10)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if let dropX {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Palette.highlight)
                            .frame(width: 2, height: proxy.size.height)
                            .offset(x: min(max(dropX, 0), proxy.size.width) - 1)
                    }
                }
            }
            .motion(.fade, value: hint)
            .motion(.fade, value: showsHint)
            .motion(.fade, value: dropX == nil)
            .allowsHitTesting(false)
    }
}

/// Files dragged over the tracks from Finder: which tracks they'll land on,
/// and the moment under the pointer.
private struct StudioMediaDrop: Equatable {
    var tracks: Set<StudioTrack>
    var time: TimeInterval
}

/// Takes files from Finder. Images and animated GIF/APNG/WebP/HEIC land on
/// the Images & Effects track. `neon-studio-audio` extends `dropUpdated` to
/// also route `.audio` items to its audio track.
private struct StudioMediaDropDelegate: DropDelegate {
    let canDrop: Bool
    let time: (CGPoint) -> TimeInterval
    let onPreview: (StudioMediaDrop?) -> Void
    let onDrop: ([URL], TimeInterval) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        canDrop && info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            onPreview(nil)
            return DropProposal(operation: .forbidden)
        }
        var tracks: Set<StudioTrack> = []
        if info.hasItemsConforming(to: [.image]) { tracks.insert(.overlay) }
        // neon-studio-audio adds `.audio(0)` here when `info.hasItemsConforming(to: [.audio])`.
        if tracks.isEmpty { tracks = [.overlay] }
        onPreview(StudioMediaDrop(tracks: tracks, time: time(info.location)))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onPreview(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        onPreview(nil)
        guard canDrop else { return false }
        let at = time(info.location)
        let providers = info.itemProviders(for: [.fileURL])
        return StudioMediaDropLoader.loadFileURLs(from: providers) { urls in
            if !urls.isEmpty { onDrop(urls, at) }
        }
    }
}

// MARK: - Playhead, chapters, ink marks, and ruler

/// The playhead and the skim line, with the only reads of the playhead's
/// time and hover preview in the dock. Both change many times a second;
/// kept here, they redraw this layer instead of every lane.
private struct StudioPlayheadLayer: View {
    let model: RecordingStudioModel
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let isScrubbing: Bool
    /// The playhead moved, so the lanes can scroll to keep it in sight.
    let onMove: (TimeInterval) -> Void

    var body: some View {
        let hoverTime = (model.isPlaying || model.isDraggingTimelineBlock || model.isTrimmingClip)
            ? nil
            : model.hoverPreviewTime
        StudioTimelinePlayhead(
            time: model.currentTime,
            chapters: chapters,
            scale: scale,
            scrollX: scrollX,
            skimX: hoverTime.map { scale.x(for: $0) - scrollX },
            showsSkim: hoverTime != nil,
            isScrubbing: isScrubbing,
            onScrub: { time in
                model.pause()
                model.seek(to: time)
            },
            onStep: { delta in
                model.stepFrames(delta)
            }
        )
        .transaction { $0.animation = nil }
        .onChange(of: model.currentTime) { _, time in onMove(time) }
    }
}

/// Map chapter names only when chapter/transcript edits change, not on playback ticks.
private struct StudioTimelineChapters: View {
    let model: RecordingStudioModel
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let isScrubbing: Bool
    let onPlayheadMove: (TimeInterval) -> Void

    var body: some View {
        let chapters = model.visibleChapters
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(chapters) { chapter in
                    StudioTimelineChapterMarker(model: model, chapter: chapter, chapters: chapters,
                                                scale: scale, scrollX: scrollX, viewportWidth: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .coordinateSpace(name: StudioTimelineChapterMarker.coordinateSpace)
        .clipped()
        // The playhead stays above the marker controls, with its original, unclipped hit area.
        .overlay {
            StudioPlayheadLayer(
                model: model,
                chapters: chapters,
                scale: scale,
                scrollX: scrollX,
                isScrubbing: isScrubbing,
                onMove: onPlayheadMove
            )
        }
    }
}

/// A short red tick at the bottom of the ruler where each drawing starts.
private struct StudioTimelineInkMarks: View {
    let model: RecordingStudioModel
    let scale: StudioTimelineScale
    let scrollX: CGFloat

    private static let hitWidth: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(model.showsInk ? model.inkStrokes : []) { stroke in
                    if let time = model.clipTimeline.editorTime(forSourceEventTime: stroke.startTime) {
                        let x = scale.x(for: time) - scrollX
                        if x >= 0, x <= proxy.size.width {
                            Button {
                                model.jumpToInkStroke(stroke)
                            } label: {
                                Capsule()
                                    .fill(Color(nsColor: .systemRed))
                                    .frame(width: 3, height: 7)
                                    .frame(width: Self.hitWidth, height: StudioTimelineMetrics.rulerHeight,
                                           alignment: .bottom)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Drawing \(model.inkStrokeNumber(stroke.id))")
                            .accessibilityLabel("Drawing \(model.inkStrokeNumber(stroke.id))")
                            .accessibilityHint("Activate to jump to it.")
                            .offset(x: x - Self.hitWidth / 2,
                                    y: StudioTimelineMetrics.playheadLaneHeight)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .disabled(!model.isLoaded || model.hasRunningWork)
    }
}

/// Cyan marker flags hanging from the top of the ruler. Cyan reads clearly
/// apart from Sukusho's orange chapter lines, red bottom ink ticks, and the
/// yellow I/O range band.
private struct StudioTimelineMarkers: View {
    let model: RecordingStudioModel
    let scale: StudioTimelineScale
    let scrollX: CGFloat

    private static let hitWidth: CGFloat = 12
    private static let flagColor = Color(nsColor: .systemCyan)

    var body: some View {
        let entries = model.markerEditorTimes
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.marker.id) { entry in
                    let x = scale.x(for: entry.time) - scrollX
                    if x >= -6, x <= proxy.size.width + 6 {
                        Button {
                            model.pause()
                            model.seek(to: entry.time)
                        } label: {
                            StudioMarkerFlagShape()
                                .fill(Self.flagColor)
                                .overlay {
                                    StudioMarkerFlagShape()
                                        .stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                                }
                                .frame(width: 8, height: 10)
                                .frame(width: Self.hitWidth, height: StudioTimelineMetrics.rulerHeight, alignment: .top)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Marker", systemImage: "trash", role: .destructive) {
                                model.removeMarker(id: entry.marker.id)
                            }
                        }
                        .help(markerHelp(for: entry))
                        .accessibilityLabel(entry.marker.note.map { "Marker, \($0)" } ?? "Marker")
                        .accessibilityValue(studioPreciseTimecode(entry.time))
                        .accessibilityHint("Activate to jump to this marker.")
                        .accessibilityAction(named: "Remove Marker") {
                            model.removeMarker(id: entry.marker.id)
                        }
                        .offset(
                            x: x - Self.hitWidth / 2,
                            y: StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing
                        )
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .disabled(!model.isLoaded || model.hasRunningWork)
    }

    private func markerHelp(for entry: (marker: RecordingMarker, time: TimeInterval)) -> String {
        if let note = entry.marker.note, !note.isEmpty {
            return "\(note) · \(studioPreciseTimecode(entry.time))"
        }
        return "Marker · \(studioPreciseTimecode(entry.time))"
    }
}

private struct StudioMarkerFlagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.6))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.6))
        path.closeSubpath()
        return path
    }
}

@Observable
private final class StudioSnapGuideState {
    var time: TimeInterval?
}

private struct StudioSnapGuideOverlay: View {
    let state: StudioSnapGuideState
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let size: CGSize

    var body: some View {
        if let time = state.time {
            let guideX = scale.x(for: time) - scrollX
            if guideX >= -1, guideX <= size.width + 1 {
                let top = StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing
                let guideHeight = max(0, size.height - top - StudioTimelineMetrics.scrollerGutter)
                Rectangle()
                    .fill(Color(nsColor: .systemYellow))
                    .frame(width: 1.5, height: guideHeight)
                    .offset(x: guideX - 0.75, y: top)
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil }
            }
        }
    }
}

private struct StudioTimelineChapterMarker: View {
    let model: RecordingStudioModel
    let chapter: RecordingChapter
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let viewportWidth: CGFloat
    @State private var draftStart: TimeInterval?
    @State private var grabOffset: CGFloat?

    private static let hitWidth: CGFloat = 12
    static let coordinateSpace = "studio.chapterMarker"

    var body: some View {
        let x = scale.x(for: draftStart ?? chapter.start) - scrollX
        let visible = x >= 0 && x <= viewportWidth
        Button {
            model.jumpToChapter(chapter)
        } label: {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 1, height: StudioTimelineMetrics.rulerHeight)
                .frame(width: Self.hitWidth, height: StudioTimelineMetrics.rulerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chapter.title)
        .accessibilityLabel("Chapter, \(chapter.title)")
        .accessibilityValue(Text("\(chapter.start, format: .number.precision(.fractionLength(2))) seconds"))
        .accessibilityHint("Activate to jump. Adjust to move the chapter start.")
        .accessibilityAdjustableAction { direction in
            model.pause()
            switch direction {
            case .increment: model.moveChapter(id: chapter.id, to: chapter.start + 1)
            case .decrement: model.moveChapter(id: chapter.id, to: chapter.start - 1)
            @unknown default: break
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpace))
                .onChanged { value in
                    if grabOffset == nil {
                        grabOffset = value.startLocation.x - (scale.x(for: chapter.start) - scrollX)
                        model.pause()
                    }
                    draftStart = clampedTime(at: value.location.x)
                }
                .onEnded { value in
                    if let time = clampedTime(at: value.location.x) { model.moveChapter(id: chapter.id, to: time) }
                    draftStart = nil
                    grabOffset = nil
                }
        )
        .disabled(!model.isLoaded || model.hasRunningWork)
        .opacity(visible || grabOffset != nil ? 1 : 0)
        .allowsHitTesting(visible || grabOffset != nil)
        .offset(x: x - Self.hitWidth / 2,
                y: StudioTimelineMetrics.playheadLaneHeight)
    }

    private func clampedTime(at x: CGFloat) -> TimeInterval? {
        RecordingChapterPlanner.clampedStart(id: chapter.id,
            proposed: scale.time(forX: x + scrollX - (grabOffset ?? 0)),
            chapters: chapters, duration: scale.duration)
    }
}

/// Full-height playhead drawn as one pin: a soft rounded head above the
/// ruler whose underside flows into the stem through concave fillets.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let skimX: CGFloat?
    let showsSkim: Bool
    var isScrubbing = false
    let onScrub: (TimeInterval) -> Void
    let onStep: (Int) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var grabOffset: CGFloat?
    @GestureState private var isScrubGestureActive = false

    private enum Metrics {
        static let headSize = CGSize(width: 17, height: 12)
        static let readoutSize = CGSize(width: 56, height: 17)
        static let longReadoutWidth: CGFloat = 70
        static let hitSize = CGSize(width: 28, height: StudioTimelineMetrics.playheadLaneHeight + 4)
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let laneHeight = StudioTimelineMetrics.playheadLaneHeight
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -2 && x <= width + 2
            let isExpanded = isHovering || isDragging || isScrubbing
            let head = isExpanded
                ? CGSize(
                    width: time >= 3600 ? Metrics.longReadoutWidth : Metrics.readoutSize.width,
                    height: Metrics.readoutSize.height
                )
                : Metrics.headSize
            // At 0:00 the head overhangs the track gutter cleanly; at the end
            // it stops at the edge and the stem slides across into a flag.
            let headX = min(x, width - head.width / 2)
            let headTop = laneHeight - Metrics.headSize.height - 1

            ZStack(alignment: .topLeading) {
                if showsSkim, let skimX, !isDragging, !isScrubbing,
                   skimX >= 0, skimX <= width {
                    Rectangle()
                        .fill(Color.primary.opacity(0.32))
                        .frame(width: 1, height: max(0, proxy.size.height - laneHeight))
                        .offset(x: skimX - 0.5, y: laneHeight)
                        .allowsHitTesting(false)
                }

                if isVisible, let chapter = RecordingChapterPlanner.current(chapters, at: time, duration: scale.duration) {
                    let gap: CGFloat = 6
                    let headLeading = headX - head.width / 2
                    let headTrailing = headX + head.width / 2
                    let right = max(0, width - headTrailing - gap)
                    let left = max(0, headLeading - gap)
                    let useRight = right >= min(240, left)
                    let labelWidth = min(240, useRight ? right : left)
                    Text(chapter.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelWidth, height: laneHeight,
                               alignment: useRight ? .leading : .trailing)
                        .offset(x: useRight ? headTrailing + gap : headLeading - gap - labelWidth)
                        .allowsHitTesting(false)
                }

                PlayheadPinShape(
                    headHeight: head.height,
                    stemOffset: x - headX
                )
                .fill(Palette.highlight)
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                .overlay {
                    if isExpanded {
                        Text(studioPreciseTimecode(time))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .fixedSize()
                            .frame(width: head.width, height: head.height)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(AnyTransition(.blurReplace))
                    }
                }
                .frame(width: head.width, height: max(0, proxy.size.height - headTop))
                .offset(x: headX - head.width / 2, y: headTop)
                .allowsHitTesting(false)
                .opacity(isVisible ? 1 : 0)

                Color.clear
                    .frame(width: max(Metrics.hitSize.width, head.width), height: Metrics.hitSize.height)
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(Self.coordinateSpace)
                        )
                        .updating($isScrubGestureActive) { _, active, _ in
                            active = true
                        }
                        .onChanged { value in
                            isDragging = true
                            onScrub(scale.playheadDragTime(
                                locationX: value.location.x,
                                startX: value.startLocation.x,
                                stemX: x,
                                grabOffset: &grabOffset,
                                scrollX: scrollX
                            ))
                        }
                        .onEnded { _ in
                            endDrag()
                        }
                    )
                    .onChange(of: isScrubGestureActive) { _, active in
                        if !active { endDrag() }
                    }
                    .onDisappear { endDrag() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Playhead")
                    .accessibilityValue(studioPreciseTimecode(time))
                    .accessibilityHint("Adjust to step frame by frame.")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onStep(1)
                        case .decrement: onStep(-1)
                        @unknown default: break
                        }
                    }
                    .position(x: headX, y: Metrics.hitSize.height / 2 - 2)
                    .allowsHitTesting(isVisible)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .motion(.morphQuick, value: isHovering || isDragging || isScrubbing)
    }

    private func endDrag() {
        isDragging = false
        grabOffset = nil
    }
}

private struct PlayheadPinShape: Shape {
    var headHeight: CGFloat
    var stemOffset: CGFloat = 0
    var stemWidth: CGFloat = 2
    var cornerRadius: CGFloat = 4
    var filletRadius: CGFloat = 3.5

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(headHeight, stemOffset) }
        set {
            headHeight = newValue.first
            stemOffset = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let head = min(headHeight, rect.height)
        let corner = min(cornerRadius, head / 2, rect.width / 2)
        let halfStem = stemWidth / 2
        let stemX = min(
            max(rect.midX + stemOffset, rect.minX + corner + halfStem),
            rect.maxX - halfStem
        )
        let trailingRoom = rect.maxX - (stemX + halfStem)
        let trailingCorner = min(corner, trailingRoom)
        let leadingFillet = max(0, min(
            filletRadius,
            stemX - halfStem - (rect.minX + corner),
            rect.height - head
        ))
        let trailingFillet = max(0, min(
            filletRadius,
            trailingRoom - trailingCorner,
            rect.height - head
        ))
        let headBottom = rect.minY + head

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        if trailingRoom > 1 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: headBottom),
                radius: trailingCorner
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: headBottom),
                radius: trailingCorner
            )
            path.addArc(
                tangent1End: CGPoint(x: stemX + halfStem, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: rect.maxY),
                radius: trailingFillet
            )
        } else {
            path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.maxY))
        path.addLine(to: CGPoint(x: stemX - halfStem, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: stemX - halfStem, y: headBottom),
            tangent2End: CGPoint(x: rect.minX, y: headBottom),
            radius: leadingFillet
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: headBottom),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: corner
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: corner
        )
        path.closeSubpath()
        return path
    }
}

/// Absolute-time ruler above the tracks: full-height major hairlines with
/// leading-edge labels, minor floor ticks, and a bottom closing hairline.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat
    /// The stretch marked with I and O (or ⇧-drag), drawn as a band.
    var range: ClosedRange<TimeInterval>?

    private static let minorTickHeight: CGFloat = 5
    private static let labelInset = CGPoint(x: 5, y: 2)

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                with: .color(Palette.hairline)
            )
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            if let range {
                let low = CGFloat(range.lowerBound) * pointsPerSecond - scrollX
                let high = CGFloat(range.upperBound) * pointsPerSecond - scrollX
                let band = CGRect(x: low, y: 0, width: max(1, high - low), height: size.height)
                context.fill(Path(band), with: .color(Color(nsColor: .systemYellow).opacity(0.28)))
                for edge in [low, high] {
                    context.fill(
                        Path(CGRect(x: edge - 1, y: 0, width: 2, height: size.height)),
                        with: .color(Color(nsColor: .systemYellow))
                    )
                }
            }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let minorStep = Self.minorStep(for: step)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            var minorIndex = max(0, Int(floor(startTime / minorStep)))
            while true {
                let time = Double(minorIndex) * minorStep
                minorIndex += 1
                guard time <= endTime else { break }
                context.fill(
                    Path(CGRect(
                        x: x(for: time) - 0.5,
                        y: size.height - 1 - Self.minorTickHeight,
                        width: 1,
                        height: Self.minorTickHeight
                    )),
                    with: .color(.primary.opacity(0.14))
                )
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)
                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: 0, width: 1, height: size.height)),
                    with: .color(Palette.hairline)
                )

                guard time > 0 else { continue }

                let label = context.resolve(
                    Text(Self.label(for: time, step: step))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.tertiaryLabel)
                )
                let labelSize = label.measure(in: size)
                let labelX = tickX + Self.labelInset.x
                guard labelX + labelSize.width <= size.width else { continue }
                context.draw(label, in: CGRect(
                    x: labelX,
                    y: Self.labelInset.y,
                    width: labelSize.width,
                    height: labelSize.height
                ))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline Ruler")
        .accessibilityValue(StudioEditing.rulerAccessibilityValue(duration: duration, range: range))
    }

    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 72 {
            return candidate
        }
        return candidates.last ?? 60
    }

    private static func minorStep(for step: Double) -> Double {
        let isFifths = step >= 1 && step.truncatingRemainder(dividingBy: 5) == 0
        return step / (isFifths ? 5 : 4)
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

// MARK: - Text and Images/Effects lanes

/// Text blocks. Dragging across empty track draws out a text block; a click scrubs.
private struct StudioTextLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedTextID,
            scale: scale,
            height: StudioTrack.text.height,
            empty: .create(tint: Palette.textCue, minimumLength: RecordingTextOverlay.minimumDuration) { range in
                model.addText(fromEditorTime: range.lowerBound, toEditorTime: range.upperBound)
            },
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { model.selectText(id: $0.id) },
                begin: { _ in model.beginTextEdit() },
                edit: { edit in
                    var text = edit.base.item
                    let range = studioOverlaySourceRange(for: edit, model: model, start: text.start, end: text.end)
                    text.start = range.start
                    text.end = range.end
                    model.setText(text)
                },
                end: { kind in model.endTextEdit(actionName: kind == .move ? "Move Text" : "Resize Text") }
            ),
            content: { block, state in
                StudioOverlayBlockContent(
                    style: .text,
                    systemImage: "textformat",
                    title: title(for: block.item),
                    length: block.editorLength,
                    state: state
                )
            },
            menu: { block in
                Button("Delete Text", systemImage: "trash", role: .destructive) {
                    model.removeText(id: block.id)
                }
            },
            help: { block in "\(title(for: block.item)). Drag to move, drag an end to resize, right-click for options." },
            accessibility: { block in
                StudioBlockAccessibility(
                    label: "Text, \(title(for: block.item))",
                    value: "\(studioPreciseTimecode(block.editorStart)) to \(studioPreciseTimecode(block.editorEnd))"
                )
            }
        )
        .contextMenu {
            Button("Add Text at Playhead", systemImage: "textformat") {
                model.addText(atEditorTime: model.currentTime)
            }
        }
    }

    private func title(for text: RecordingTextOverlay) -> String {
        text.text.isEmpty ? "Text" : text.text.replacingOccurrences(of: "\n", with: " ")
    }

    private var visibleBlocks: [StudioLaneBlock<RecordingTextOverlay>] {
        model.textTimelineBlocks
            .filter { $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound }
            .map { StudioLaneBlock(item: $0.item, editorStart: $0.editorStart, editorEnd: $0.editorEnd) }
    }
}

/// Items on the Images and Effects track: images/GIFs and pixelate/blur
/// redactions share it so they hit-test together.
private enum StudioEffectsItem: Identifiable {
    case image(RecordingImageOverlay)
    case redaction(RecordingRedaction)

    var id: UUID {
        switch self {
        case .image(let overlay): overlay.id
        case .redaction(let redaction): redaction.id
        }
    }

    var title: String {
        switch self {
        case .image(let overlay): overlay.isAnimated ? "\(overlay.displayName) · GIF" : overlay.displayName
        case .redaction(let redaction): redaction.mode.title
        }
    }
}

/// Images, GIFs, and pixelate/blur redaction blocks on the Images & Effects track.
private struct StudioRedactionLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onScrubbing: (Bool) -> Void

    var body: some View {
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks,
            selectedID: model.selectedImageID ?? model.selectedRedactionID,
            scale: scale,
            height: StudioTrack.overlay.height,
            empty: .scrub,
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { item in
                    switch item {
                    case .image(let overlay): model.selectImage(id: overlay.id)
                    case .redaction(let redaction): model.selectRedaction(id: redaction.id)
                    }
                },
                begin: { _ in
                    model.beginImageEdit()
                    model.beginRedactionEdit()
                },
                edit: apply,
                end: { kind in
                    let verb = kind == .move ? "Move" : "Resize"
                    model.endImageEdit(actionName: "\(verb) Image")
                    model.endRedactionEdit(actionName: "\(verb) Redaction")
                }
            ),
            content: { block, state in
                switch block.item {
                case .image(let overlay):
                    StudioOverlayBlockContent(
                        style: .image,
                        systemImage: overlay.isAnimated ? "photo.stack" : "photo",
                        title: block.item.title,
                        length: block.editorLength,
                        state: state
                    )
                case .redaction(let redaction):
                    StudioOverlayBlockContent(
                        style: .effect,
                        systemImage: redaction.mode.systemImage,
                        title: block.item.title,
                        length: block.editorLength,
                        state: state,
                        isHatched: true
                    )
                }
            },
            menu: { block in menu(for: block.item) },
            help: { block in "\(block.item.title). Drag to move, drag an end to resize, right-click for options." },
            accessibility: { block in
                StudioBlockAccessibility(
                    label: block.item.title,
                    value: "\(studioPreciseTimecode(block.editorStart)) to \(studioPreciseTimecode(block.editorEnd))"
                )
            }
        )
        .contextMenu {
            Button("Pixelate at Playhead", systemImage: "squareshape.split.3x3") {
                model.addRedaction(atEditorTime: model.currentTime, mode: .pixelate)
            }
            Button("Blur at Playhead", systemImage: "drop.halffull") {
                model.addRedaction(atEditorTime: model.currentTime, mode: .blur)
            }
        }
    }

    private func apply(_ edit: StudioBlockEdit<StudioEffectsItem>) {
        switch edit.base.item {
        case .image(var overlay):
            let range = studioOverlaySourceRange(for: edit, model: model, start: overlay.start, end: overlay.end)
            overlay.start = range.start
            overlay.end = range.end
            model.setImage(overlay)
        case .redaction(var redaction):
            let range = studioOverlaySourceRange(for: edit, model: model, start: redaction.start, end: redaction.end)
            redaction.start = range.start
            redaction.end = range.end
            model.setRedaction(redaction)
        }
    }

    @ViewBuilder
    private func menu(for item: StudioEffectsItem) -> some View {
        switch item {
        case .image(let overlay):
            Button("Delete Image", systemImage: "trash", role: .destructive) {
                model.removeImage(id: overlay.id)
            }
        case .redaction(let redaction):
            Menu("Effect") {
                ForEach(RecordingRedaction.Mode.allCases) { mode in
                    Toggle(mode.title, isOn: Binding(
                        get: { redaction.mode == mode },
                        set: { _ in
                            var edited = redaction
                            edited.mode = mode
                            model.updateRedaction(edited, actionName: "Change Redaction Mode")
                        }
                    ))
                }
            }
            Divider()
            Button("Delete \(redaction.mode.title)", systemImage: "trash", role: .destructive) {
                model.removeRedaction(id: redaction.id)
            }
        }
    }

    /// Images under effects, matching their visual distinction on the lane.
    private var visibleBlocks: [StudioLaneBlock<StudioEffectsItem>] {
        let images = model.imageTimelineBlocks.map {
            StudioLaneBlock(item: StudioEffectsItem.image($0.item), editorStart: $0.editorStart, editorEnd: $0.editorEnd)
        }
        let redactions = model.redactionTimelineBlocks.map {
            StudioLaneBlock(item: StudioEffectsItem.redaction($0.item), editorStart: $0.editorStart, editorEnd: $0.editorEnd)
        }
        return (images + redactions).filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

/// Where a text, image, or effect lands after a timeline drag. Moves keep
/// their length on the edited timeline; trims move one end without passing the other.
private func studioOverlaySourceRange<Item>(
    for edit: StudioBlockEdit<Item>,
    model: RecordingStudioModel,
    start: TimeInterval,
    end: TimeInterval
) -> (start: TimeInterval, end: TimeInterval) {
    switch edit.kind {
    case .move:
        guard abs(edit.delta) >= 0.000_001 else { return (start, end) }
        return studioMovedSourceRange(
            model: model,
            editorStart: edit.base.editorStart + edit.delta,
            editorLength: edit.base.editorLength
        )
    case .trimLeading:
        let source = abs(edit.delta) < 0.000_001
            ? start
            : studioSourceStart(atEditorTime: edit.base.editorStart + edit.delta, in: model.clipTimeline)
        return (min(source, end - 0.1), end)
    case .trimTrailing:
        let source = abs(edit.delta) < 0.000_001
            ? end
            : studioSourceEnd(atEditorTime: edit.base.editorEnd + edit.delta, in: model.clipTimeline)
        return (start, max(source, start + 0.1))
    }
}

/// A text, image, or effect block: tinted softly at rest, filled when selected.
private struct StudioOverlayBlockContent: View {
    let style: StudioBlockStyle
    let systemImage: String
    let title: String
    let length: TimeInterval
    let state: StudioBlockState
    var isHatched = false

    var body: some View {
        let foreground = style.label(isSelected: state.isSelected)
        StudioBlockLabel(
            systemImage: systemImage,
            title: title,
            detail: studioClock(length),
            state: state,
            color: foreground
        )
        .background {
            StudioBlockSurface(fill: style.fill(isSelected: state.isSelected, isHovering: state.isHovered))
                .overlay {
                    if isHatched {
                        StudioBlockHatch(color: foreground.opacity(0.12), spacing: 12, lineWidth: 6)
                    }
                }
        }
    }
}

// MARK: - Zoom lane

/// Zoom cues. Dragging across empty track draws out a zoom in the gap it
/// started in; a click scrubs. Recorded clicks mark the track's floor.
private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    var onScrubbing: ((Bool) -> Void)?

    var body: some View {
        let blocks = model.zoomTimelineBlocks
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks(of: blocks),
            selectedID: model.selectedCueID,
            scale: scale,
            height: StudioTrack.zooms.height,
            overlap: .forbidden(spans: model.zoomOverlapSpans),
            empty: .create(tint: Palette.highlight, minimumLength: ZoomCue.minimumDuration) { range in
                model.addZoomCue(overEditorRange: range)
            },
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { model.selectZoomCue(id: $0.id) },
                begin: { _ in model.beginZoomCueEdit() },
                edit: apply,
                end: { kind in model.endZoomCueEdit(actionName: kind == .move ? "Move Zoom" : "Resize Zoom") }
            ),
            decoration: { pressMarks },
            content: { block, state in content(for: block, state: state) },
            menu: { block in menu(for: block.item) },
            help: { block in
                block.item.isEnabled
                    ? "Drag to move, drag an end to resize, right-click for options"
                    : "Turned off. Right-click to turn it back on."
            },
            accessibility: { block in accessibility(for: block) }
        )
        .opacity(model.zoomEnabled ? 1 : 0.45)
        .contextMenu {
            Button("Add Zoom at Playhead", systemImage: "plus.viewfinder") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    private var pressMarks: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Circle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: scale.x(for: pressTime) - 1.5,
                        y: StudioTrack.zooms.height - StudioBlockMetrics.inset - 3
                    )
            }
        }
    }

    @ViewBuilder
    private func content(for block: StudioLaneBlock<ZoomCue>, state: StudioBlockState) -> some View {
        let cue = block.item
        StudioBlockLabel(
            systemImage: cue.anchorMode == .pinnedAnchor ? "scope" : "viewfinder",
            title: cue.isEnabled
                ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: cue.zoom)
                : "Off",
            detail: (cue.isEnabled && cue.anchorMode != .pointerAnchor ? "\(cue.anchorMode.inspectorTitle) · " : "")
                + studioClock(block.editorLength),
            state: state,
            color: cue.isEnabled ? StudioBlockStyle.zoom.label(isSelected: state.isSelected) : .secondary
        )
        .background {
            if cue.isEnabled {
                StudioBlockSurface(fill: StudioBlockStyle.zoom.fill(isSelected: state.isSelected, isHovering: state.isHovered))
            } else {
                StudioBlockSurface(fill: Color.primary.opacity(0.08))
                    .overlay { StudioBlockHatch(color: .primary.opacity(0.10)) }
            }
        }
    }

    private func accessibility(for block: StudioLaneBlock<ZoomCue>) -> StudioBlockAccessibility {
        let cue = block.item
        let label = if cue.isEnabled {
            "Zoom \(InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: cue.zoom)), \(cue.anchorMode.inspectorTitle)"
        } else {
            "Zoom, Off"
        }
        let range = "\(studioPreciseTimecode(block.editorStart)) to \(studioPreciseTimecode(block.editorEnd))"
        let value = model.zoomEnabled ? range : "\(range), zooms off"
        return StudioBlockAccessibility(label: label, value: value)
    }

    private func apply(_ edit: StudioBlockEdit<ZoomCue>) {
        let base = edit.base
        switch edit.kind {
        case .move:
            model.moveZoomCue(studioMovedZoomCue(for: edit, clipTimeline: model.clipTimeline))
        case .trimLeading, .trimTrailing:
            if let trim = studioTrimmedZoomSourceTime(for: edit, clipTimeline: model.clipTimeline) {
                model.trimZoomCue(
                    id: base.item.id,
                    edge: trim.edge,
                    toSourceTime: trim.sourceTime,
                    base: base.item
                )
            }
        }
    }

    @ViewBuilder
    private func menu(for cue: ZoomCue) -> some View {
        Menu("Zoom Level") {
            ForEach(Self.zoomPresets, id: \.self) { preset in
                Toggle(
                    String(format: "%g×", preset),
                    isOn: Binding(
                        get: { abs(cue.zoom - preset) < 0.01 },
                        set: { _ in edit(cue, action: "Change Zoom Level") { $0.zoom = preset } }
                    )
                )
            }
        }

        Menu("Camera Focus") {
            ForEach(ZoomAnchorMode.allCases, id: \.self) { mode in
                Toggle(
                    mode.inspectorTitle,
                    isOn: Binding(
                        get: { cue.anchorMode == mode },
                        set: { _ in
                            edit(cue, action: "Change Camera Focus") { updated in
                                updated.anchorMode = mode
                                if mode == .pinnedAnchor,
                                   let pointer = model.pointerLocation(at: model.currentTime) {
                                    updated.pinnedPoint = pointer
                                }
                            }
                        }
                    )
                )
            }
        }

        Divider()

        Button(cue.isEnabled ? "Turn Off This Zoom" : "Turn On This Zoom",
               systemImage: cue.isEnabled ? "eye.slash" : "eye") {
            edit(cue, action: cue.isEnabled ? "Turn Off Zoom" : "Turn On Zoom") {
                $0.isEnabled.toggle()
            }
        }

        Button("Remove Zoom", systemImage: "trash", role: .destructive) {
            model.removeZoomCue(id: cue.id)
        }
    }

    private static let zoomPresets: [Double] = [1.25, 1.5, 2, 2.5, 3]

    private func edit(_ cue: ZoomCue, action: String, _ change: (inout ZoomCue) -> Void) {
        var updated = cue
        change(&updated)
        model.beginZoomCueEdit()
        model.updateZoomCue(updated)
        model.endZoomCueEdit(actionName: action)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private func visibleBlocks(of blocks: [RecordingZoomTimelineBlock]) -> [StudioLaneBlock<ZoomCue>] {
        blocks
            .filter { $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound }
            .map {
                StudioLaneBlock(
                    item: $0.cue,
                    editorStart: $0.editorStart,
                    editorEnd: $0.editorEnd,
                    allowsTrim: model.clipTimeline.editorRuns(overlapping: $0.cue.start, sourceEnd: $0.cue.end).count <= 1
                )
            }
    }
}
