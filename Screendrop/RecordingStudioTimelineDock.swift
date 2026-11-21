//
//  RecordingStudioTimelineDock.swift
//  Screendrop
//
//  The Recording Studio timeline dock: transport controls, ruler, ink marks,
//  chapters, clip strip, and zoom lane.
//

import AppKit
import SwiftUI

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
        VStack(spacing: StudioTimelineMetrics.rowSpacing) {
            transport
            lanes
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
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

            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                StudioTimelineRuler(
                    duration: model.duration,
                    pointsPerSecond: scale.pointsPerSecond,
                    scrollX: scrollX
                )
                .frame(height: StudioTimelineMetrics.rulerHeight)

                scrollingLanes(scale: scale)
            }
            .overlay {
                StudioTimelineInkMarks(model: model, scale: scale, scrollX: scrollX)
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
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
        }
        .frame(height: StudioTimelineMetrics.lanesHeight)
        .onChange(of: model.duration) { _, _ in clampZoom() }
    }

    /// The two lanes that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and lane chrome
    /// stay viewport-sized and redraw against `scrollX` instead - a rounded
    /// rectangle or Canvas tens of thousands of points wide would be a single
    /// oversized layer, while an AppKit view only ever draws its visible rect.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.clipLaneHeight)
                StudioZoomLaneBackground(
                    showsHint: model.zoomEnabled && model.zoomTimelineBlocks.isEmpty
                )
                    .frame(height: StudioTimelineMetrics.zoomLaneHeight)
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                    clipLane
                        .frame(
                            width: scale.contentWidth,
                            height: StudioTimelineMetrics.clipLaneHeight
                        )

                    StudioZoomLane(
                        model: model,
                        scale: scale,
                        visibleRange: scale.visibleRange(scrollX: scrollX),
                        onScrubbing: { isScrubbing = $0 }
                    )
                    .frame(
                        width: scale.contentWidth,
                        height: StudioTimelineMetrics.zoomLaneHeight
                    )

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
        .frame(height: StudioTimelineMetrics.scrollingLanesHeight)
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
            onScrubbing: { isScrubbing = $0 }
        )
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

    private var zoomControls: some View {
        HStack(spacing: 6) {
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

            if zoom > 1.0001 {
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editControls: some View {
        HStack(spacing: 6) {
            StudioTransportTray {
                timelineButton("Split at Playhead (⌘B)", systemImage: "scissors") {
                    model.splitClip(at: model.currentTime)
                }
                .keyboardShortcut("b", modifiers: .command)

                timelineButton("Delete Selection", systemImage: "trash") {
                    deleteSelection()
                }
                .disabled(!canDeleteSelection)

                timelineButton("Reset All Clip Edits…", systemImage: "arrow.counterclockwise") {
                    isResetClipsConfirmationPresented = true
                }
                .disabled(!model.hasClipEdits)
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

            StudioTransportTray {
                timelineButton("Undo (⌘Z)", systemImage: "arrow.uturn.backward") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                timelineButton("Redo (⇧⌘Z)", systemImage: "arrow.uturn.forward") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
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

    private var transport: some View {
        ZStack {
            HStack(spacing: 0) {
                zoomControls
                Spacer(minLength: 0)
                editControls
            }

            playbackControls
        }
        .frame(height: 36)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if model.selectedClipID != nil {
            model.deleteSelectedClip()
        }
    }

    private func timelineButton(
        _ help: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(TransportIconButtonStyle())
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
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                .primary.opacity(
                    isEnabled ? (configuration.isPressed || isHovering ? 0.95 : 0.78) : 0.25
                )
            )
            .background {
                RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous)
                    .fill(Color.primary.opacity(
                        isEnabled ? (configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0) : 0
                    ))
            }
            .onHover { isHovering = $0 }
    }
}

private enum StudioTimelineMetrics {
    static let rowSpacing: CGFloat = 8
    static let playheadLaneHeight: CGFloat = 14
    static let rulerHeight: CGFloat = 16
    static let clipLaneHeight: CGFloat = 52
    static let zoomLaneHeight: CGFloat = 30
    /// Room under the lanes for the horizontal scroller, so it never sits on
    /// top of a zoom block.
    static let scrollerGutter: CGFloat = 8

    static let scrollingLanesHeight = clipLaneHeight + zoomLaneHeight
        + scrollerGutter + rowSpacing * 2
    static let lanesHeight = playheadLaneHeight + rulerHeight
        + scrollingLanesHeight + rowSpacing * 2
}

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
        let hoverTime = (model.isPlaying || model.isDraggingTimelineBlock) ? nil : model.hoverPreviewTime
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
                    if let time = model.editorTime(forSourceTime: stroke.startTime) {
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
                                    y: StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing)
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
                y: StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing)
    }

    private func clampedTime(at x: CGFloat) -> TimeInterval? {
        RecordingChapterPlanner.clampedStart(id: chapter.id,
            proposed: scale.time(forX: x + scrollX - (grabOffset ?? 0)),
            chapters: chapters, duration: scale.duration)
    }
}

/// Full-height playhead drawn as one pin: a soft rounded head above the
/// ruler whose underside flows into the stem through concave fillets. At
/// rest the head is a small tab; hovered or dragged it widens into a
/// readout of the time, then folds back. At the trailing end it turns into
/// a flush flag so the inspector never clips it. The head is the only hit
/// target - everywhere else the overlay passes clicks through to the tracks
/// underneath. The pointer's skim line is drawn here too, so it runs
/// through every lane rather than just the clip strip.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    /// The pointer's position while skimming, in viewport points.
    let skimX: CGFloat?
    let showsSkim: Bool
    /// The playhead is being scrubbed from the clips or an empty track; the
    /// head opens into its readout as if it were dragged.
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
        /// Breathing room from the timeline's 16 pt leading padding so the
        /// expanded readout stays inside the window at 0:00.
        static let leadingOverhang: CGFloat = 12
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let laneHeight = StudioTimelineMetrics.playheadLaneHeight
            // Viewport space: the playhead overlay never scrolls, it just
            // tracks the scrolled lanes underneath it.
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -2 && x <= width + 2
            let isExpanded = isHovering || isDragging || isScrubbing
            let head = isExpanded
                ? CGSize(
                    width: time >= 3600 ? Metrics.longReadoutWidth : Metrics.readoutSize.width,
                    height: Metrics.readoutSize.height
                )
                : Metrics.headSize
            // The stem stays on the true time. At the trailing edge the
            // inspector column would clip it, so it stops at the edge and the
            // stem slides across to its trailing side into a flag; at 0:00
            // an expanded readout nudges just enough to clear the window edge.
            let trailingMax = width - head.width / 2
            let leadingMin = min(head.width / 2 - Metrics.leadingOverhang, trailingMax)
            let headX = min(max(x, leadingMin), trailingMax)
            // The head hangs from the top of its lane, so the readout grows
            // downward toward the ruler rather than off the dock.
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
        // Opening into the readout and folding back is the one spring left
        // on the timeline.
        .motion(.morphQuick, value: isHovering || isDragging || isScrubbing)
    }

    private func endDrag() {
        isDragging = false
        grabOffset = nil
    }
}

/// A playhead pin in one outline: a rounded head across the top of the
/// rect, a stem down to the bottom, and concave fillets where the head's
/// underside meets the stem so the two read as a single soft piece. The
/// stem can sit right of centre, up to the head's trailing edge; as it gets
/// there that side's corners close up, so the pin becomes a flag.
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
        // Head left between the stem and the trailing edge. The trailing
        // corners shrink with it, reaching square when the stem is flush.
        let trailingRoom = rect.maxX - (stemX + halfStem)
        let trailingCorner = min(corner, trailingRoom)
        // A fillet can't reach past the head's own rounded corners.
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
        // Under a point of room the lip would read as a notch, so the
        // pin is already a flag.
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
            // Underside into the stem's right edge, curving down.
            path.addArc(
                tangent1End: CGPoint(x: stemX + halfStem, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: rect.maxY),
                radius: trailingFillet
            )
        } else {
            // Flush: the top edge turns straight down into the stem.
            path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.maxY))
        path.addLine(to: CGPoint(x: stemX - halfStem, y: rect.maxY))
        // Back up the stem's left edge and out along the underside.
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

/// Absolute-time ruler above the clip lane. The ruler itself never scrolls: it
/// draws only the time span currently on screen, so a deeply zoomed timeline
/// costs the same to render as a fitted one.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat

    var body: some View {
        Canvas { context, size in
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))
            let endpointLabel = Self.label(for: duration, step: step)
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            /// `anchorX` is the tick position; `trailing` right-aligns the
            /// label onto it instead of centering, which is how the endpoint
            /// label stays inside the viewport.
            func drawLabel(_ text: String, at anchorX: CGFloat, trailing: Bool = false) {
                let label = context.resolve(
                    Text(text)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                )
                let labelSize = label.measure(in: size)
                let labelX = trailing ? anchorX - labelSize.width : anchorX - labelSize.width / 2
                let clampedX = min(max(labelX, 0), max(0, size.width - labelSize.width))
                guard clampedX >= lastLabelMaxX + 8 else { return }
                context.draw(label, in: CGRect(
                    x: clampedX,
                    y: size.height - 5 - labelSize.height,
                    width: labelSize.width,
                    height: labelSize.height
                ))
                lastLabelMaxX = clampedX + labelSize.width
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)

                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: size.height - 4, width: 1, height: 4)),
                    with: .color(.primary.opacity(0.30))
                )

                let minorTime = time + step / 2
                if minorTime < duration {
                    context.fill(
                        Path(CGRect(
                            x: x(for: minorTime) - 0.5,
                            y: size.height - 2.5,
                            width: 1,
                            height: 2.5
                        )),
                        with: .color(.primary.opacity(0.16))
                    )
                }

                // The start needs no label: the playhead parks over it, and
                // the lane's leading edge already says where the cut begins.
                guard time > 0 else { continue }

                // A final whole-second tick can format identically to a
                // fractional endpoint (for example 4.2 -> 0:04). Let the
                // actual endpoint own that label.
                let timeLabel = Self.label(for: time, step: step)
                if timeLabel != endpointLabel {
                    drawLabel(timeLabel, at: tickX)
                }
            }

            // The end of the recording always gets a tick, right-aligned when
            // it lands at the trailing edge of the viewport.
            let endpointX = x(for: duration)
            if endpointX >= -1, endpointX <= size.width + 1 {
                context.fill(
                    Path(CGRect(
                        x: min(endpointX, size.width - 0.5) - 0.5,
                        y: size.height - 4,
                        width: 1,
                        height: 4
                    )),
                    with: .color(.primary.opacity(0.30))
                )
                drawLabel(endpointLabel, at: endpointX, trailing: true)
            }
        }
    }

    /// Smallest "nice" interval whose labels stay comfortably apart at the
    /// current scale. Sub-second steps unlock once a zoomed lane spreads a
    /// single second across most of the viewport.
    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 64 {
            return candidate
        }
        return candidates.last ?? 60
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

/// Frame around the zoom lane. It stays pinned to the viewport while the cue
/// blocks scroll inside it, so the lane reads as a fixed track no matter how
/// far the timeline is zoomed.
private struct StudioZoomLaneBackground: View {
    /// An empty lane explains itself instead of reading as dead space.
    var showsHint = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: StudioBlockMetrics.cornerRadius + StudioBlockMetrics.inset,
            style: .continuous
        )
            .fill(Color.primary.opacity(0.055))
            .overlay {
                if showsHint {
                    Label("Drag here to add a zoom", systemImage: "plus.viewfinder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

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
            height: StudioTimelineMetrics.zoomLaneHeight,
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

    /// Recorded clicks as small dots along the track's floor, so they mark
    /// where Auto Zoom would act without striping the blocks. Culled to the
    /// visible span: an hour-long take can hold thousands of clicks.
    private var pressMarks: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Circle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: scale.x(for: pressTime) - 1.5,
                        y: StudioTimelineMetrics.zoomLaneHeight - StudioBlockMetrics.inset - 3
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
            // Following the pointer is the default, so only a zoom that
            // does something else says so, ahead of its length.
            detail: (cue.isEnabled && cue.anchorMode != .pointerAnchor ? "\(cue.anchorMode.inspectorTitle) · " : "")
                + studioClock(block.editorLength),
            state: state,
            color: cue.isEnabled ? StudioBlockStyle.zoom.onTint : .secondary
        )
        .background {
            if cue.isEnabled {
                StudioBlockSurface(fill: StudioBlockStyle.zoom.fill(isHovering: state.isHovered))
            } else {
                // Hatched, so a turned-off zoom reads as "kept, not used".
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

    /// Magnifications offered from a block's context menu.
    private static let zoomPresets: [Double] = [1.25, 1.5, 2, 2.5, 3]

    /// One undoable change to a zoom from its context menu.
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
            .map { StudioLaneBlock(item: $0.cue, editorStart: $0.editorStart, editorEnd: $0.editorEnd) }
    }
}

