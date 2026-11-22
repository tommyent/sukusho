//
//  StudioTimelineBlocks.swift
//  Screendrop
//
//  The blocks on the Studio timeline's tracks - zooms, camera layouts, text,
//  images and effects, audio - and the one interaction engine they share.
//  Blocks only draw. Each track hit-tests the pointer against the same
//  frames it draws with and runs a single drag gesture, so a block is never
//  swallowed by its own trim handles, and every track selects, moves, trims
//  and creates the same way.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Scale

/// Shared horizontal scale for every lane in the Studio timeline. `zoom` is a
/// multiplier over "the whole recording fits the viewport", so zoom 1 keeps
/// the original fixed-width timeline and higher values widen the lanes into a
/// scrolling surface where cuts, trim handles and zoom blocks stay grabbable
/// on long recordings.
struct StudioTimelineScale: Equatable {
    /// Finest scale worth offering; past this a single frame is wider than a
    /// thumbnail tile.
    static let maximumPointsPerSecond: CGFloat = 240
    /// Ceiling on lane width, which is what actually bounds the scale on long
    /// recordings. A 30-minute take still reaches ~55 points per second here.
    static let maximumContentWidth: CGFloat = 100_000

    var viewportWidth: CGFloat
    var duration: TimeInterval
    var zoom: Double

    var contentWidth: CGFloat {
        max(viewportWidth, viewportWidth * CGFloat(zoom))
    }

    var pointsPerSecond: CGFloat {
        duration > 0 ? contentWidth / CGFloat(duration) : 0
    }

    var secondsPerPoint: Double {
        pointsPerSecond > 0 ? 1 / Double(pointsPerSecond) : 0
    }

    var isScrollable: Bool {
        contentWidth > viewportWidth + 0.5
    }

    var maxZoom: Double {
        guard duration > 0, viewportWidth > 1 else { return 1 }
        let widest = min(
            Self.maximumContentWidth,
            Self.maximumPointsPerSecond * CGFloat(duration)
        )
        return max(1, Double(widest / viewportWidth))
    }

    func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time, 0), duration)) * pointsPerSecond
    }

    func time(forX x: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max(Double(x / pointsPerSecond), 0), duration)
    }

    /// Editor time span currently on screen, padded a little so lane content
    /// culled against it never pops in at the edges.
    func visibleRange(scrollX: CGFloat) -> ClosedRange<TimeInterval> {
        let margin: CGFloat = 120
        let lower = time(forX: scrollX - margin)
        let upper = time(forX: scrollX + viewportWidth + margin)
        return lower...max(lower, upper)
    }

    /// Time scrubbed to by a playhead drag that preserves the initial pointer
    /// offset from the stem (so grabbing the center of an off-center end flag
    /// does not jump away from the end on press).
    func playheadDragTime(
        locationX: CGFloat,
        startX: CGFloat,
        stemX: CGFloat,
        grabOffset: inout CGFloat?,
        scrollX: CGFloat
    ) -> TimeInterval {
        if grabOffset == nil {
            grabOffset = startX - stemX
        }
        return time(forX: locationX - (grabOffset ?? 0) + scrollX)
    }
}

// MARK: - Metrics

enum StudioBlockMetrics {
    static let cornerRadius: CGFloat = 8
    /// Room above and below a block inside its track; the selection rim
    /// sits in it.
    static let inset: CGFloat = 3
    /// Narrowest a block draws, however short, so it stays visible and
    /// grabbable on a fitted timeline.
    static let minimumWidth: CGFloat = 24
    /// The selection's handles, outside the block's ends.
    static let handleWidth: CGFloat = 8
    static let rimWidth: CGFloat = 2
    /// The rim's outer corners. A selected block's corners tighten to the
    /// rim's inner edge, so the frame runs an even width all the way round
    /// instead of bulging into rounder block corners.
    static let selectionCornerRadius: CGFloat = 6
    static let selectedCornerRadius: CGFloat = selectionCornerRadius - rimWidth
    /// How far past an unselected block's end a trim can still be grabbed.
    static let edgeOutset: CGFloat = 4
    /// How far into an unselected block its trim reaches, at most. Never
    /// more than a fifth of the block, so its middle always moves it.
    static let edgeInset: CGFloat = 6
    /// How far into a selected block its outside handles still answer.
    static let handleOverlap: CGFloat = 2
    static let labelInset: CGFloat = 9
    /// Pointer travel before a press on a block becomes a move, or a press
    /// on empty track becomes a new block.
    static let dragThreshold: CGFloat = 3
    /// Pointer travel before a press on a trim handle becomes a resize.
    static let trimThreshold: CGFloat = 0.5

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension EnvironmentValues {
    /// The corners of the block being drawn: tighter while it's selected.
    @Entry var studioBlockCornerRadius: CGFloat = StudioBlockMetrics.cornerRadius
}

private struct StudioBlockClip: ViewModifier {
    @Environment(\.studioBlockCornerRadius) private var cornerRadius

    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// Clips to the block's corners as they are drawn right now.
    func studioBlockClip() -> some View {
        modifier(StudioBlockClip())
    }
}

// MARK: - Model

/// Minimum surface `StudioBlockLane` needs from the Studio model so the block
/// engine can compile and run in hostless tests as well as the app.
protocol StudioBlockLaneHost: AnyObject {
    var isDraggingTimelineBlock: Bool { get set }
    func pause()
    func seek(to time: TimeInterval)
    func clearTimelineSelection()
}

/// One block on a track: what it stands for and where it sits on the
/// edited timeline.
struct StudioLaneBlock<Item: Identifiable>: Identifiable where Item.ID == UUID {
    let item: Item
    let editorStart: TimeInterval
    let editorEnd: TimeInterval
    /// False when a single source cue plays on more than one editor run (e.g.
    /// across a reordered backward join) so trimming one displayed piece cannot
    /// silently remove the effect from untouched clips.
    var allowsTrim: Bool = true

    var id: UUID { item.id }
    var editorLength: TimeInterval { max(0, editorEnd - editorStart) }
}

enum StudioBlockEditKind: Equatable {
    case move
    case trimLeading
    case trimTrailing

    /// A trim follows the pointer from the first half-point; a move waits out
    /// a small wobble so a click only selects.
    var dragThreshold: CGFloat {
        self == .move ? StudioBlockMetrics.dragThreshold : StudioBlockMetrics.trimThreshold
    }

    func startsDrag(translation: CGFloat, vertical: CGFloat = 0) -> Bool {
        abs(translation) >= dragThreshold || (self == .move && abs(vertical) >= dragThreshold)
    }
}

/// A drag in progress, measured from the block as the press found it -
/// the live block re-derives on every update, so measuring against it would
/// compound the translation.
struct StudioBlockEdit<Item: Identifiable> where Item.ID == UUID {
    let base: StudioLaneBlock<Item>
    let kind: StudioBlockEditKind
    /// Editor seconds the pointer has travelled since the press.
    let delta: TimeInterval
    /// Points the pointer has travelled up (negative) or down since the
    /// press, for tracks whose blocks can change row.
    var verticalTranslation: CGFloat = 0
}

/// What a drag across empty track does.
enum StudioLaneEmptyBehavior {
    /// Scrubs the playhead.
    case scrub
    /// A click scrubs; a drag draws out a new block. The dashed draft is the
    /// block: `commit` gets exactly the range it shows, already fitted
    /// between the neighbours and grown to `minimumLength` (timeline
    /// seconds), and must add it as is.
    case create(
        tint: Color,
        minimumLength: TimeInterval,
        barriers: [TimeInterval] = [],
        commit: (ClosedRange<TimeInterval>) -> Void
    )
}

/// A block's place on the edited timeline.
struct StudioLaneSpan: Equatable {
    let id: UUID
    let editorStart: TimeInterval
    let editorEnd: TimeInterval
}

/// Whether blocks on a track may overlap.
enum StudioLaneOverlap {
    case allowed
    /// Moves, trims and new blocks stop at the neighbours, as zooms and
    /// camera layouts must. `spans` is every block on the track, not just
    /// the ones drawn, so a drag also stops at a neighbour scrolled out of
    /// view.
    case forbidden(spans: [StudioLaneSpan])

    /// The gap a block sits in: from the end of the block before it to the
    /// start of the block after it, or the timeline's ends.
    func room(
        aroundID id: UUID,
        editorStart: TimeInterval,
        editorEnd: TimeInterval,
        duration: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        guard case .forbidden(let spans) = self else { return 0...max(0, duration) }
        let others = spans.filter { $0.id != id }
        let floor = others.map(\.editorEnd).filter { $0 <= editorStart + 0.0001 }.max() ?? 0
        let ceiling = others.map(\.editorStart).filter { $0 >= editorEnd - 0.0001 }.min() ?? duration
        return floor...max(floor, ceiling)
    }

    /// Stop at the neighbours on the timeline, where the block's length is the
    /// one you see. Stopping later, in recording time, would park it with a
    /// length measured where the pointer is - over a sped-up clip, a different
    /// one.
    func clampedDelta(
        _ delta: TimeInterval,
        blockID: UUID,
        editorStart: TimeInterval,
        editorEnd: TimeInterval,
        kind: StudioBlockEditKind,
        duration: TimeInterval
    ) -> TimeInterval {
        guard case .forbidden = self else { return delta }
        let room = room(aroundID: blockID, editorStart: editorStart, editorEnd: editorEnd, duration: duration)
        switch kind {
        case .move:
            return min(max(delta, room.lowerBound - editorStart), room.upperBound - editorEnd)
        case .trimLeading:
            return max(delta, room.lowerBound - editorStart)
        case .trimTrailing:
            return min(delta, room.upperBound - editorEnd)
        }
    }
}

/// Where a drag across empty track puts a new block, in editor time.
///
/// The block starts where the press landed and runs to the pointer, either
/// way, stopped at the edges of the gap the press landed in. A drag shorter
/// than `minimumLength` still makes a block that long, grown in the drag's
/// direction (and back from the gap's end if it runs out of room), so the
/// draft never shows less than will be added. Nil when the gap is too short
/// to hold a block at all.
func studioDraftRange(
    anchor: TimeInterval,
    pointer: TimeInterval,
    gap: ClosedRange<TimeInterval>,
    minimumLength: TimeInterval
) -> ClosedRange<TimeInterval>? {
    guard gap.contains(anchor), gap.upperBound - gap.lowerBound >= minimumLength else { return nil }
    let pointer = min(max(pointer, gap.lowerBound), gap.upperBound)
    var lower = min(anchor, pointer)
    var upper = max(anchor, pointer)
    if upper - lower < minimumLength {
        if pointer >= anchor {
            upper = min(lower + minimumLength, gap.upperBound)
            lower = upper - minimumLength
        } else {
            lower = max(upper - minimumLength, gap.lowerBound)
            upper = lower + minimumLength
        }
    }
    return lower...upper
}

/// The empty stretch of track around `time`: from the end of the last block
/// before it to the start of the first block after it, or the timeline's
/// ends. Nil when `time` is inside a block.
///
/// Zero-width spans represent occupied deleted ranges sitting at an editor-time
/// cut. When `time` lands right on a cut, `toward` decides which side of the
/// cut the drag is entering.
func studioGap(
    around time: TimeInterval,
    toward: TimeInterval? = nil,
    spans: [StudioLaneSpan],
    duration: TimeInterval
) -> ClosedRange<TimeInterval>? {
    guard !spans.contains(where: { $0.editorStart < time && time < $0.editorEnd }) else { return nil }
    let floor = spans.compactMap { span -> TimeInterval? in
        if span.editorStart == span.editorEnd, span.editorStart == time {
            return (toward ?? time) >= time ? span.editorEnd : nil
        }
        return span.editorEnd <= time ? span.editorEnd : nil
    }.max() ?? 0
    let ceiling = spans.compactMap { span -> TimeInterval? in
        if span.editorStart == span.editorEnd, span.editorStart == time {
            return (toward ?? time) < time ? span.editorStart : nil
        }
        return span.editorStart >= time ? span.editorStart : nil
    }.min() ?? duration
    return floor...max(floor, ceiling)
}

/// Source time at the start of an editor-time range: at a cut, lands on the
/// clip after the cut so a block beginning there sits in that clip.
func studioSourceStart(
    atEditorTime editorTime: TimeInterval,
    in clipTimeline: RecordingClipTimeline
) -> TimeInterval {
    clipTimeline.sourceTime(at: editorTime)
}

/// Source time at the end of an editor-time range: at a cut, lands on the clip
/// before the cut so a block ending there does not swallow the deleted source
/// span.
func studioSourceEnd(
    atEditorTime editorTime: TimeInterval,
    in clipTimeline: RecordingClipTimeline
) -> TimeInterval {
    guard !clipTimeline.segments.isEmpty, clipTimeline.duration > 0 else { return 0 }
    let clamped = min(max(editorTime, 0), clipTimeline.duration)
    var editorStart: TimeInterval = 0
    for (index, segment) in clipTimeline.segments.enumerated() {
        let editorEnd = editorStart + segment.editorDuration
        if clamped <= editorEnd + 0.000_000_1
            || index == clipTimeline.segments.index(before: clipTimeline.segments.endIndex) {
            let offset = min(max(clamped - editorStart, 0), segment.editorDuration)
            let sourceOffset = min(offset * segment.speed, segment.duration)
            return segment.sourceStart + sourceOffset
        }
        editorStart = editorEnd
    }
    return clipTimeline.segments.last?.sourceEnd ?? 0
}

/// Editor-time spans for every zoom cue (all surviving touching runs, not just
/// the longest), hidden cues inside forward cuts as zero-width barriers, and
/// zero-width barriers at backward joins (`hardCuts`) so single-source-range
/// draw/move/trim gestures stay inside one monotonic source run.
func studioOccupiedLaneSpans(
    cues: [ZoomCue],
    clipTimeline: RecordingClipTimeline
) -> [StudioLaneSpan] {
    var spans: [StudioLaneSpan] = []
    for cue in cues where cue.end > cue.start {
        let runs = clipTimeline.editorRuns(overlapping: cue.start, sourceEnd: cue.end)
        if !runs.isEmpty {
            for run in runs {
                spans.append(StudioLaneSpan(
                    id: cue.id,
                    editorStart: run.editorStart,
                    editorEnd: run.editorEnd
                ))
            }
            continue
        }
        guard clipTimeline.isInRecordingOrder else { continue }
        var cutTime: TimeInterval = 0
        for segment in clipTimeline.segments {
            if cue.end <= segment.sourceStart + 0.000_001 {
                break
            }
            cutTime += segment.editorDuration
        }
        spans.append(StudioLaneSpan(id: cue.id, editorStart: cutTime, editorEnd: cutTime))
    }
    for cut in clipTimeline.hardCuts {
        spans.append(StudioLaneSpan(id: UUID(), editorStart: cut, editorEnd: cut))
    }
    return spans
}

/// The contiguous editor-time run containing `anchor` that contains no
/// backward jump (`hardCut`) in source time.
private func studioMonotonicRun(
    around anchor: TimeInterval,
    in clipTimeline: RecordingClipTimeline
) -> ClosedRange<TimeInterval> {
    let duration = max(0, clipTimeline.duration)
    let clamped = min(max(anchor, 0), duration)
    let cuts = clipTimeline.hardCuts
    let floor = cuts.last { $0 <= clamped + 0.000_001 } ?? 0
    let ceiling = cuts.first { $0 > clamped + 0.000_001 } ?? duration
    return floor...max(floor, ceiling)
}

/// The recording under a range drawn on a track whose blocks can't overlap.
/// The track has fitted the range between the blocks (and cut barriers) it
/// knows about, so this only trims away any rounding hair against a neighbour.
/// Nil when that leaves less than `minimum`, which the track already measured,
/// in editor time.
func studioDrawnSourceSpan(
    for range: ClosedRange<TimeInterval>,
    clipTimeline: RecordingClipTimeline,
    sourceDuration: TimeInterval,
    among occupied: [ClosedRange<TimeInterval>],
    minimum: TimeInterval
) -> ClosedRange<TimeInterval>? {
    let run = studioMonotonicRun(around: range.lowerBound, in: clipTimeline)
    let clampedLower = min(max(range.lowerBound, run.lowerBound), run.upperBound)
    let clampedUpper = min(max(range.upperBound, clampedLower), run.upperBound)
    var lower = min(max(0, studioSourceStart(atEditorTime: clampedLower, in: clipTimeline)), sourceDuration)
    let end = min(max(lower, studioSourceEnd(atEditorTime: clampedUpper, in: clipTimeline)), sourceDuration)
    while let covering = occupied.first(where: { $0.lowerBound <= lower && lower < $0.upperBound }) {
        lower = covering.upperBound
    }
    let ceiling = occupied.map(\.lowerBound).filter { $0 >= lower }.min() ?? sourceDuration
    let upper = min(end, ceiling)
    // Speed only ever packs more recording into a timeline second, so a block
    // drawn `minimum` long covers at least that much recording; the slack
    // absorbs rounding.
    guard upper - lower >= minimum - 0.001 else { return nil }
    return lower...upper
}

/// How the timeline `+` button presents Text, Pixelate, and Media so the
/// expanded controls never sit under the centered timecode and playback buttons.
nonisolated enum StudioAddToolsLayout: Equatable, Sendable {
    case popover
    case inlineIcons
    case inlineLabels

    /// Width needed for `+` plus the three icon-only add pills and gaps.
    static let inlineIconsWidth: CGFloat = 148
    /// Width needed for `+` plus the three labeled add pills and gaps.
    static let inlineLabelsWidth: CGFloat = 324
    /// Minimum breathing room between the rightmost expanded pill and the centered transport.
    static let transportClearance: CGFloat = 12

    /// Picks the widest layout that keeps the expanded edit cluster clear of
    /// the centered playback cluster (including hour-long timecodes and the
    /// shuttle badge) using the measured widths of the transport row, the
    /// centered transport, and the fixed tools to the left of `+`.
    static func forAvailableWidth(
        rowWidth: CGFloat,
        centeredTransportWidth: CGFloat,
        leadingToolsWidth: CGFloat
    ) -> Self {
        guard rowWidth > 0, centeredTransportWidth > 0 else { return .popover }
        let freeWidth = (rowWidth - centeredTransportWidth) / 2 - leadingToolsWidth - transportClearance
        if freeWidth >= inlineLabelsWidth { return .inlineLabels }
        if freeWidth >= inlineIconsWidth { return .inlineIcons }
        return .popover
    }
}

/// How a track turns block edits into model changes.
struct StudioBlockLaneActions<Item: Identifiable> where Item.ID == UUID {
    let select: (Item) -> Void
    /// An edit is starting: open one undo step for the edited item.
    let begin: (Item, StudioBlockEditKind) -> Void
    let edit: (StudioBlockEdit<Item>) -> Void
    /// The edit is done: close the undo step for the edited item.
    let end: (Item, StudioBlockEditKind) -> Void
}

/// What a block's content needs to know to draw itself.
struct StudioBlockState {
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let isHovered: Bool
}

/// Accessible label, value, and step size for a timeline block so VoiceOver can
/// select, move, and trim even a narrow block reduced to a glyph.
struct StudioBlockAccessibility: Equatable {
    let label: String
    let value: String
    /// Step size (in editor seconds) for named move and trim actions.
    var step: TimeInterval = 0.5
}

// MARK: - Geometry and hit-testing

/// Where a block draws on its track. Rendering and hit-testing both use it,
/// so what you see is what you grab.
struct StudioBlockFrame: Equatable {
    let minX: CGFloat
    let width: CGFloat
    /// When a selected block sits against a timeline end, an outside handle
    /// would be clipped by the scroll view, so that grip and its hit region
    /// move just inside the block's end instead.
    let leadingHandleInside: Bool
    let trailingHandleInside: Bool

    var maxX: CGFloat { minX + width }

    init(editorStart: TimeInterval, editorEnd: TimeInterval, scale: StudioTimelineScale) {
        let startX = scale.x(for: editorStart)
        let natural = CGFloat(max(0, editorEnd - editorStart)) * scale.pointsPerSecond
        // A block running past the edited video's end is cut there; one
        // drawn wider than it lasts slides inward to stay whole.
        let visible = min(natural, scale.contentWidth - startX)
        let width = min(max(StudioBlockMetrics.minimumWidth, visible), scale.contentWidth)
        let minX = min(startX, max(0, scale.contentWidth - width))
        self.width = width
        self.minX = minX
        self.leadingHandleInside = minX < StudioBlockMetrics.handleWidth
        self.trailingHandleInside = (minX + width) > scale.contentWidth - StudioBlockMetrics.handleWidth
    }

    var selectionMinX: CGFloat {
        leadingHandleInside ? minX : minX - StudioBlockMetrics.handleWidth
    }

    var selectionMaxX: CGFloat {
        trailingHandleInside ? maxX : maxX + StudioBlockMetrics.handleWidth
    }

    var selectionWidth: CGFloat {
        max(0, selectionMaxX - selectionMinX)
    }

    /// Hit range for the selected block's leading trim handle, driven from the
    /// same geometry as `StudioSelectionFrame`.
    var selectedLeadingHandleRange: Range<CGFloat> {
        let lower = selectionMinX
        let upper = leadingHandleInside
            ? minX + StudioBlockMetrics.handleWidth
            : minX + StudioBlockMetrics.handleOverlap
        return lower..<max(lower, upper)
    }

    /// Hit range for the selected block's trailing trim handle, driven from the
    /// same geometry as `StudioSelectionFrame`.
    var selectedTrailingHandleRange: ClosedRange<CGFloat> {
        let upper = selectionMaxX
        let lower = trailingHandleInside
            ? maxX - StudioBlockMetrics.handleWidth
            : maxX - StudioBlockMetrics.handleOverlap
        return min(lower, upper)...upper
    }

    /// How far into this block, when unselected, its ends trim.
    var edgeInset: CGFloat {
        min(StudioBlockMetrics.edgeInset, width * 0.2)
    }
}

enum StudioBlockEdge: Equatable {
    case leading
    case trailing
}

/// What the pointer is over on a track.
enum StudioBlockTarget: Equatable {
    case empty
    case body(UUID)
    case edge(UUID, StudioBlockEdge)

    var blockID: UUID? {
        switch self {
        case .empty: nil
        case .body(let id), .edge(let id, _): id
        }
    }
}

struct StudioBlockHitTester {
    struct Entry {
        let id: UUID
        let frame: StudioBlockFrame
        var allowsTrim: Bool = true
    }

    /// Bottom to top, as drawn.
    let entries: [Entry]
    let selectedID: UUID?

    func target(atX x: CGFloat) -> StudioBlockTarget {
        // The selected block draws on top with its handles driven from the
        // same frame as `StudioSelectionFrame`, so it answers first: the
        // handles trim, the block moves.
        if let selected = entries.last(where: { $0.id == selectedID }) {
            let frame = selected.frame
            if selected.allowsTrim {
                if frame.selectedLeadingHandleRange.contains(x) {
                    return .edge(selected.id, .leading)
                }
                if x > frame.selectedTrailingHandleRange.lowerBound, x <= frame.selectedTrailingHandleRange.upperBound {
                    return .edge(selected.id, .trailing)
                }
            }
            if x >= frame.minX, x <= frame.maxX {
                return .body(selected.id)
            }
        }

        // Otherwise the topmost block whose middle is under the pointer.
        for entry in entries.reversed() where entry.id != selectedID {
            let frame = entry.frame
            let inset = entry.allowsTrim ? frame.edgeInset : 0
            if x >= frame.minX + inset, x <= frame.maxX - inset {
                return .body(entry.id)
            }
        }

        // Then the nearest end within reach. Where two blocks meet, the end
        // of the block the pointer is inside wins over a neighbour's reach.
        var nearest: (target: StudioBlockTarget, isInside: Bool, distance: CGFloat)?
        for entry in entries where entry.id != selectedID && entry.allowsTrim {
            let frame = entry.frame
            let isInside = x >= frame.minX && x <= frame.maxX
            let candidates: [(StudioBlockEdge, CGFloat, ClosedRange<CGFloat>)] = [
                (.leading, frame.minX, (frame.minX - StudioBlockMetrics.edgeOutset)...(frame.minX + frame.edgeInset)),
                (.trailing, frame.maxX, (frame.maxX - frame.edgeInset)...(frame.maxX + StudioBlockMetrics.edgeOutset)),
            ]
            for (edge, edgeX, reach) in candidates where reach.contains(x) {
                let distance = abs(x - edgeX)
                let isBetter = nearest.map { best in
                    isInside != best.isInside ? isInside : distance < best.distance
                } ?? true
                if isBetter {
                    nearest = (.edge(entry.id, edge), isInside, distance)
                }
            }
        }
        return nearest?.target ?? .empty
    }
}

// MARK: - Track

/// One track of blocks. Owns every pointer interaction on the track: hover,
/// the cursor, selection, moving, trimming, scrubbing and drawing out new
/// blocks. Each kind of block supplies only its content, its menu, and how
/// an edit lands in the model.
struct StudioBlockLane<Item: Identifiable, Content: View, Menu: View, Decoration: View>: View
where Item.ID == UUID {
    let model: any StudioBlockLaneHost
    /// The blocks to draw, bottom to top. Usually only those on screen.
    let blocks: [StudioLaneBlock<Item>]
    let selectedID: UUID?
    let scale: StudioTimelineScale
    let height: CGFloat
    let overlap: StudioLaneOverlap
    let empty: StudioLaneEmptyBehavior
    var onScrubbing: ((Bool) -> Void)?
    let actions: StudioBlockLaneActions<Item>
    @ViewBuilder let decoration: () -> Decoration
    @ViewBuilder let content: (StudioLaneBlock<Item>, StudioBlockState) -> Content
    @ViewBuilder let menu: (StudioLaneBlock<Item>) -> Menu
    let help: (StudioLaneBlock<Item>) -> String
    let accessibility: (StudioLaneBlock<Item>) -> StudioBlockAccessibility

    /// A press on the track, from mouse-down to mouse-up.
    private enum Press {
        /// On a block, not yet far enough to edit it.
        case block(StudioLaneBlock<Item>, StudioBlockEditKind)
        case editing(StudioLaneBlock<Item>, StudioBlockEditKind)
        /// On empty track that can grow a new block, not yet dragged.
        case empty(startTime: TimeInterval)
        /// Drawing out a new block from where the press landed.
        case creating(startTime: TimeInterval)
        case scrubbing
    }

    @State private var press: Press?
    /// The block a drag across empty track will add on release.
    @State private var draft: ClosedRange<TimeInterval>?
    @State private var hover: StudioBlockTarget = .empty
    /// Tracks whether SwiftUI's drag recognizer is still live so a cancelled
    /// gesture (where `onEnded` never runs) still closes any active edit,
    /// discards an uncommitted draft, and resets scrub state.
    @GestureState private var isGestureActive = false

    private var blockHeight: CGFloat {
        height - StudioBlockMetrics.inset * 2
    }

    var body: some View {
        let frames = Dictionary(
            blocks.map {
                ($0.id, StudioBlockFrame(editorStart: $0.editorStart, editorEnd: $0.editorEnd, scale: scale))
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let selected = blocks.first { $0.id == selectedID }

        ZStack(alignment: .topLeading) {
            // The track's own surface: presses between blocks land here.
            Color.clear

            decoration()
                .allowsHitTesting(false)

            if let draft, case .create(let tint, _, _, _) = empty {
                StudioDraftBlock(
                    frame: StudioBlockFrame(editorStart: draft.lowerBound, editorEnd: draft.upperBound, scale: scale),
                    height: blockHeight,
                    tint: tint
                )
            }

            // The selected block draws last, so its handles sit over its
            // neighbours.
            ForEach(blocks.filter { $0.id != selectedID } + (selected.map { [$0] } ?? [])) { block in
                if let frame = frames[block.id] {
                    blockView(block, frame: frame)
                }
            }

            if let selected, let frame = frames[selected.id] {
                if selected.allowsTrim {
                    StudioSelectionFrame(width: frame.selectionWidth, blockHeight: blockHeight)
                        .offset(
                            x: frame.selectionMinX,
                            y: StudioBlockMetrics.inset - StudioBlockMetrics.rimWidth
                        )
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(
                        cornerRadius: StudioBlockMetrics.selectedCornerRadius + StudioBlockMetrics.rimWidth,
                        style: .continuous
                    )
                    .strokeBorder(Color(nsColor: .systemYellow), lineWidth: StudioBlockMetrics.rimWidth)
                    .frame(
                        width: frame.width + StudioBlockMetrics.rimWidth * 2,
                        height: blockHeight + StudioBlockMetrics.rimWidth * 2
                    )
                    .offset(
                        x: frame.minX - StudioBlockMetrics.rimWidth,
                        y: StudioBlockMetrics.inset - StudioBlockMetrics.rimWidth
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture(frames: frames))
        .onChange(of: isGestureActive) { _, active in
            if !active { finish(commitDraft: false) }
        }
        .onDisappear { finish(commitDraft: false) }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let target = hitTester(frames).target(atX: location.x)
                if target != hover { hover = target }
            case .ended:
                if hover != .empty { hover = .empty }
            }
        }
        .pointerStyle(pointerStyle)
    }

    @ViewBuilder
    private func blockView(_ block: StudioLaneBlock<Item>, frame: StudioBlockFrame) -> some View {
        let isSelected = block.id == selectedID
        let state = StudioBlockState(
            width: frame.width,
            height: blockHeight,
            isSelected: isSelected,
            isHovered: activeTarget.blockID == block.id
        )
        let cornerRadius = isSelected ? StudioBlockMetrics.selectedCornerRadius : StudioBlockMetrics.cornerRadius
        let a11y = accessibility(block)
        content(block, state)
            .environment(\.studioBlockCornerRadius, cornerRadius)
            .frame(width: frame.width, height: blockHeight, alignment: .leading)
            .overlay {
                // An unselected block shows which end the pointer would trim.
                if !isSelected, case .edge(block.id, let edge) = activeTarget {
                    StudioBlockGrip()
                        .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                        .padding(.horizontal, 3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contextMenu { menu(block) }
            .help(help(block))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11y.label)
            .accessibilityValue(a11y.value)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(
                block.allowsTrim
                    ? "Activate to select. Use actions to move or resize."
                    : "Activate to select. Use actions to move."
            )
            .accessibilityAction {
                model.pause()
                actions.select(block.item)
            }
            .accessibilityAction(named: "Move Earlier") {
                performAccessibleEdit(block, kind: .move, delta: -a11y.step)
            }
            .accessibilityAction(named: "Move Later") {
                performAccessibleEdit(block, kind: .move, delta: a11y.step)
            }
            .modifier(StudioBlockTrimAccessibilityModifier(
                enabled: block.allowsTrim,
                onTrim: { kind, delta in performAccessibleEdit(block, kind: kind, delta: delta) },
                step: a11y.step
            ))
            .offset(x: frame.minX, y: StudioBlockMetrics.inset)
    }

    func performAccessibleEdit(_ block: StudioLaneBlock<Item>, kind: StudioBlockEditKind, delta: TimeInterval) {
        guard kind == .move || block.allowsTrim else { return }
        model.pause()
        actions.select(block.item)
        let clamped = overlap.clampedDelta(
            delta,
            blockID: block.id,
            editorStart: block.editorStart,
            editorEnd: block.editorEnd,
            kind: kind,
            duration: scale.duration
        )
        actions.begin(block.item, kind)
        actions.edit(StudioBlockEdit(base: block, kind: kind, delta: clamped))
        actions.end(block.item, kind)
    }

    // MARK: Pointer

    private func hitTester(_ frames: [UUID: StudioBlockFrame]) -> StudioBlockHitTester {
        StudioBlockHitTester(
            entries: blocks.compactMap { block in
                frames[block.id].map { .init(id: block.id, frame: $0, allowsTrim: block.allowsTrim) }
            },
            selectedID: selectedID
        )
    }

    /// The press's target while one is held, the hovered one otherwise.
    private var activeTarget: StudioBlockTarget {
        switch press {
        case .block(let block, let kind), .editing(let block, let kind):
            switch kind {
            case .move: .body(block.id)
            case .trimLeading: .edge(block.id, .leading)
            case .trimTrailing: .edge(block.id, .trailing)
            }
        case .empty, .creating, .scrubbing:
            .empty
        case nil:
            hover
        }
    }

    private var pointerStyle: PointerStyle? {
        guard case .edge(_, let edge) = activeTarget else { return nil }
        return .frameResize(position: edge == .leading ? .leading : .trailing)
    }

    private func dragGesture(frames: [UUID: StudioBlockFrame]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isGestureActive) { _, active, _ in
                active = true
            }
            .onChanged { value in
                guard scale.pointsPerSecond > 0 else { return }
                if press == nil {
                    begin(at: value.startLocation.x, frames: frames)
                }
                update(
                    translation: value.location.x - value.startLocation.x,
                    vertical: value.location.y - value.startLocation.y,
                    x: value.location.x
                )
            }
            .onEnded { _ in finish(commitDraft: true) }
    }

    private func begin(at x: CGFloat, frames: [UUID: StudioBlockFrame]) {
        model.pause()
        let target = hitTester(frames).target(atX: x)
        if let id = target.blockID, let block = blocks.first(where: { $0.id == id }) {
            // Selecting on mouse-down shows the handles before any drag.
            actions.select(block.item)
            let kind: StudioBlockEditKind = switch target {
            case .edge(_, .leading): .trimLeading
            case .edge(_, .trailing): .trimTrailing
            default: .move
            }
            press = .block(block, kind)
            return
        }

        // Empty track lets go of the selection, like clicking empty canvas,
        // and scrubs.
        model.clearTimelineSelection()
        let time = scale.time(forX: x)
        model.seek(to: time)
        onScrubbing?(true)
        switch empty {
        case .scrub: press = .scrubbing
        case .create: press = .empty(startTime: time)
        }
    }

    private func update(translation: CGFloat, vertical: CGFloat, x: CGFloat) {
        let time = scale.time(forX: x)
        switch press {
        case .block(let block, let kind):
            guard kind.startsDrag(translation: translation, vertical: vertical) else { return }
            actions.begin(block.item, kind)
            press = .editing(block, kind)
            // The preview stays on the playhead while a block is dragged,
            // instead of chasing the pointer.
            model.isDraggingTimelineBlock = true
            edit(block, kind: kind, translation: translation, vertical: vertical)
        case .editing(let block, let kind):
            edit(block, kind: kind, translation: translation, vertical: vertical)
        case .empty(let startTime):
            if abs(translation) < StudioBlockMetrics.dragThreshold {
                model.seek(to: time)
                return
            }
            onScrubbing?(false)
            press = .creating(startTime: startTime)
            draft = draftRange(from: startTime, to: time)
        case .creating(let startTime):
            draft = draftRange(from: startTime, to: time)
        case .scrubbing:
            model.seek(to: time)
        case nil:
            break
        }
    }

    private func edit(_ block: StudioLaneBlock<Item>, kind: StudioBlockEditKind, translation: CGFloat, vertical: CGFloat) {
        let rawDelta = Double(translation) * scale.secondsPerPoint
        let delta = overlap.clampedDelta(
            rawDelta,
            blockID: block.id,
            editorStart: block.editorStart,
            editorEnd: block.editorEnd,
            kind: kind,
            duration: scale.duration
        )
        actions.edit(StudioBlockEdit(base: block, kind: kind, delta: delta, verticalTranslation: vertical))
    }

    /// Ends the current press. Idempotent so both `onEnded` and `@GestureState`
    /// cancellation (or `onDisappear`) can invoke it safely; cancellation closes
    /// an applied edit as one Undo step, discards an uncommitted draft, and
    /// clears scrub state.
    private func finish(commitDraft: Bool) {
        guard let activePress = press else {
            draft = nil
            return
        }
        let pendingDraft = draft
        press = nil
        draft = nil
        switch activePress {
        case .editing(let block, let kind):
            model.isDraggingTimelineBlock = false
            actions.end(block.item, kind)
        case .creating:
            if commitDraft, let pendingDraft, case .create(_, _, _, let commit) = empty {
                commit(pendingDraft)
            }
        case .empty, .scrubbing:
            onScrubbing?(false)
        case .block:
            break
        }
    }

    /// The block a drag from `start` to `current` would add, or nil when
    /// there's no room for one where the press landed.
    private func draftRange(from start: TimeInterval, to current: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard case .create(_, let minimumLength, let barriers, _) = empty else { return nil }
        let gap: ClosedRange<TimeInterval>? = switch overlap {
        case .allowed:
            barriers.isEmpty
                ? 0...scale.duration
                : studioGap(
                    around: start,
                    toward: current,
                    spans: barriers.map { StudioLaneSpan(id: UUID(), editorStart: $0, editorEnd: $0) },
                    duration: scale.duration
                )
        case .forbidden(let spans):
            studioGap(around: start, toward: current, spans: spans, duration: scale.duration)
        }
        guard let gap else { return nil }
        return studioDraftRange(anchor: start, pointer: current, gap: gap, minimumLength: minimumLength)
    }
}

extension StudioBlockLane where Decoration == EmptyView {
    init(
        model: any StudioBlockLaneHost,
        blocks: [StudioLaneBlock<Item>],
        selectedID: UUID?,
        scale: StudioTimelineScale,
        height: CGFloat,
        overlap: StudioLaneOverlap = .allowed,
        empty: StudioLaneEmptyBehavior,
        onScrubbing: ((Bool) -> Void)? = nil,
        actions: StudioBlockLaneActions<Item>,
        @ViewBuilder content: @escaping (StudioLaneBlock<Item>, StudioBlockState) -> Content,
        @ViewBuilder menu: @escaping (StudioLaneBlock<Item>) -> Menu,
        help: @escaping (StudioLaneBlock<Item>) -> String,
        accessibility: @escaping (StudioLaneBlock<Item>) -> StudioBlockAccessibility
    ) {
        self.init(
            model: model,
            blocks: blocks,
            selectedID: selectedID,
            scale: scale,
            height: height,
            overlap: overlap,
            empty: empty,
            onScrubbing: onScrubbing,
            actions: actions,
            decoration: { EmptyView() },
            content: content,
            menu: menu,
            help: help,
            accessibility: accessibility
        )
    }
}

/// Where a dragged block lands in the recording. It keeps its length on the
/// timeline, not in the recording, so sliding it from a sped-up clip onto a
/// normal one doesn't stretch it (or squeeze it the other way). Constrained to
/// one monotonic source run so moving across a backward join never collapses
/// the source range.
func studioMovedSourceRange(
    clipTimeline: RecordingClipTimeline,
    editorStart: TimeInterval,
    editorLength: TimeInterval
) -> (start: TimeInterval, end: TimeInterval) {
    let clampedStart = min(max(0, editorStart), max(0, clipTimeline.duration - editorLength))
    let run = studioMonotonicRun(around: clampedStart, in: clipTimeline)
    let start = min(max(run.lowerBound, clampedStart), max(run.lowerBound, run.upperBound - editorLength))
    let end = min(start + max(0, editorLength), run.upperBound)
    let sourceStart = studioSourceStart(atEditorTime: start, in: clipTimeline)
    guard end > start else { return (sourceStart, sourceStart) }
    let sourceEnd = max(sourceStart, studioSourceEnd(atEditorTime: end, in: clipTimeline))
    return (sourceStart, sourceEnd)
}

/// Normalizes stored zoom cues at document ingestion: drops non-finite or
/// inverted/empty ranges, clamps fields to valid bounds, assigns fresh IDs to
/// duplicate IDs, sorts by start time, and trims overlaps forward.
func studioNormalizedZoomCues(
    _ cues: [ZoomCue],
    sourceDuration: TimeInterval
) -> [ZoomCue] {
    let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
    guard safeDuration > 0 else { return [] }
    var seenIDs = Set<UUID>()
    let sanitized = cues.compactMap { raw -> ZoomCue? in
        guard raw.start.isFinite, raw.end.isFinite, raw.end > raw.start else { return nil }
        var cue = studioSanitizedZoomCue(raw, sourceDuration: safeDuration)
        guard cue.end - cue.start > 0.000_001 else { return nil }
        if !seenIDs.insert(cue.id).inserted {
            cue.id = UUID()
        }
        return cue
    }
    .sorted {
        if abs($0.start - $1.start) > 0.000_001 {
            return $0.start < $1.start
        }
        return $0.end < $1.end
    }

    var previousEnd: TimeInterval = 0
    return sanitized.compactMap { raw in
        var cue = raw
        cue.start = max(cue.start, previousEnd)
        guard cue.end - cue.start > 0.000_001 else { return nil }
        previousEnd = cue.end
        return cue
    }
}

/// Sanitizes a zoom cue's scalar fields without altering neighbor placement.
func studioSanitizedZoomCue(_ cue: ZoomCue, sourceDuration: TimeInterval) -> ZoomCue {
    let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
    var cue = cue
    cue.start = min(max(0, cue.start.isFinite ? cue.start : 0), safeDuration)
    cue.end = min(max(cue.start, cue.end.isFinite ? cue.end : cue.start), safeDuration)
    cue.zoom = min(max(cue.zoom.isFinite ? cue.zoom : 1.5, 1), 4)
    cue.boundsBias = min(max(cue.boundsBias.isFinite ? cue.boundsBias : 0.25, 0), 1)
    cue.pinnedPoint = CGPoint(
        x: min(max(cue.pinnedPoint.x.isFinite ? cue.pinnedPoint.x : 0.5, 0), 1),
        y: min(max(cue.pinnedPoint.y.isFinite ? cue.pinnedPoint.y : 0.5, 0), 1)
    )
    return cue
}

/// Room a cue has to grow or slide into before it would run into a neighbour
/// in source time.
func studioZoomNeighborBounds(
    forCueAt index: Int,
    in cues: [ZoomCue],
    sourceDuration: TimeInterval
) -> (lower: TimeInterval, upper: TimeInterval) {
    (
        lower: index > 0 ? max(0, cues[index - 1].end) : 0,
        upper: index + 1 < cues.count
            ? min(cues[index + 1].start, sourceDuration)
            : sourceDuration
    )
}

/// Applies a move in source time while preserving the positive source span
/// calculated from the editor interval (so a short cue moved from 2× to 1×
/// keeps its visible editor length instead of inflating to `minimumDuration`).
func studioPlaceMovedZoomCue(
    _ cue: ZoomCue,
    in cues: [ZoomCue],
    sourceDuration: TimeInterval
) -> [ZoomCue]? {
    var next = cues
    guard let index = next.firstIndex(where: { $0.id == cue.id }) else { return nil }
    let bounds = studioZoomNeighborBounds(forCueAt: index, in: next, sourceDuration: sourceDuration)
    var moved = studioSanitizedZoomCue(cue, sourceDuration: sourceDuration)
    let room = max(0, bounds.upper - bounds.lower)
    let length = min(moved.duration, room)
    guard length > 0.000_001 else { return nil }
    // Preserve both sanitized endpoints verbatim when the cue already fits
    // within its neighbour bounds; recomputing `start + (end - start)` can
    // shift the last ULP of fractional frame times and trigger a false edit.
    if moved.start < bounds.lower || moved.end > bounds.upper {
        moved.start = min(max(moved.start, bounds.lower), max(bounds.lower, bounds.upper - length))
        moved.end = min(moved.start + length, bounds.upper)
    }
    next[index] = moved
    return next
}

/// Applies an explicit single-edge trim in source time while keeping the
/// opposite edge fixed. Enforces `ZoomCue.minimumDuration` against the moving
/// edge only: if an already-short cue (e.g. moved from 2× to 1×) has no room on
/// the moving side to reach `minimumDuration`, or is asked to shrink further,
/// the cue stays at `base` untouched instead of shifting the opposite edge.
func studioPlaceTrimmedZoomCue(
    id: UUID,
    edge: StudioBlockEdge,
    proposedSourceTime: TimeInterval,
    base: ZoomCue? = nil,
    in cues: [ZoomCue],
    sourceDuration: TimeInterval
) -> [ZoomCue]? {
    var next = cues
    guard let index = next.firstIndex(where: { $0.id == id }) else { return nil }
    let anchor = studioSanitizedZoomCue(base ?? next[index], sourceDuration: sourceDuration)
    let bounds = studioZoomNeighborBounds(forCueAt: index, in: next, sourceDuration: sourceDuration)
    let safeDuration = max(0, sourceDuration.isFinite ? sourceDuration : 0)
    let proposed = min(max(0, proposedSourceTime.isFinite ? proposedSourceTime : 0), safeDuration)
    var trimmed = anchor

    switch edge {
    case .leading:
        let fixedEnd = anchor.end
        if abs(proposed - anchor.start) < 0.000_001
            || (anchor.duration < ZoomCue.minimumDuration && proposed > anchor.start) {
            trimmed = anchor
        } else {
            let minStart = bounds.lower
            let maxStart = fixedEnd - ZoomCue.minimumDuration
            if minStart <= maxStart {
                trimmed.start = min(max(proposed, minStart), maxStart)
                trimmed.end = fixedEnd
            } else {
                trimmed = anchor
            }
        }
    case .trailing:
        let fixedStart = anchor.start
        if abs(proposed - anchor.end) < 0.000_001
            || (anchor.duration < ZoomCue.minimumDuration && proposed < anchor.end) {
            trimmed = anchor
        } else {
            let minEnd = fixedStart + ZoomCue.minimumDuration
            let maxEnd = bounds.upper
            if minEnd <= maxEnd {
                trimmed.start = fixedStart
                trimmed.end = max(min(proposed, maxEnd), minEnd)
            } else {
                trimmed = anchor
            }
        }
    }

    next[index] = trimmed
    return next
}

/// Resolves a zoom cue for a move edit. A zero clamped editor delta keeps the
/// drag's original source cue unchanged (preserving any overhang into a cut,
/// and restoring it when the pointer moves away and returns to its start).
func studioMovedZoomCue(
    for edit: StudioBlockEdit<ZoomCue>,
    clipTimeline: RecordingClipTimeline
) -> ZoomCue {
    let base = edit.base
    guard abs(edit.delta) >= 0.000_001 else { return base.item }
    var cue = base.item
    let range = studioMovedSourceRange(
        clipTimeline: clipTimeline,
        editorStart: base.editorStart + edit.delta,
        editorLength: base.editorLength
    )
    cue.start = range.start
    cue.end = range.end
    return cue
}

private struct StudioBlockTrimAccessibilityModifier: ViewModifier {
    let enabled: Bool
    let onTrim: (StudioBlockEditKind, TimeInterval) -> Void
    let step: TimeInterval

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: "Trim Start Earlier") { onTrim(.trimLeading, -step) }
                .accessibilityAction(named: "Trim Start Later") { onTrim(.trimLeading, step) }
                .accessibilityAction(named: "Trim End Earlier") { onTrim(.trimTrailing, -step) }
                .accessibilityAction(named: "Trim End Later") { onTrim(.trimTrailing, step) }
        } else {
            content
        }
    }
}

/// Resolves the target source time for a leading or trailing trim edit on a
/// zoom block; a zero editor delta preserves the drag's original source edge.
/// Returns nil for cues playing across multiple editor runs (e.g. split across
/// a backward join) so trimming one displayed piece cannot remove the effect
/// from untouched clips.
func studioTrimmedZoomSourceTime(
    for edit: StudioBlockEdit<ZoomCue>,
    clipTimeline: RecordingClipTimeline
) -> (edge: StudioBlockEdge, sourceTime: TimeInterval)? {
    guard edit.base.allowsTrim,
          clipTimeline.editorRuns(overlapping: edit.base.item.start, sourceEnd: edit.base.item.end).count <= 1 else {
        return nil
    }
    let run = studioMonotonicRun(around: (edit.base.editorStart + edit.base.editorEnd) / 2, in: clipTimeline)
    switch edit.kind {
    case .trimLeading:
        if abs(edit.delta) < 0.000_001 {
            return (.leading, edit.base.item.start)
        }
        let target = min(max(edit.base.editorStart + edit.delta, run.lowerBound), run.upperBound)
        let source = target >= run.upperBound - 0.000_001
            ? studioSourceEnd(atEditorTime: run.upperBound, in: clipTimeline)
            : studioSourceStart(atEditorTime: target, in: clipTimeline)
        return (.leading, source)
    case .trimTrailing:
        if abs(edit.delta) < 0.000_001 {
            return (.trailing, edit.base.item.end)
        }
        let target = min(max(edit.base.editorEnd + edit.delta, run.lowerBound), run.upperBound)
        let source = target <= run.lowerBound + 0.000_001
            ? studioSourceStart(atEditorTime: run.lowerBound, in: clipTimeline)
            : studioSourceEnd(atEditorTime: target, in: clipTimeline)
        return (.trailing, source)
    case .move:
        return nil
    }
}

/// Applies a cue edit. Attribute-only edits (such as magnification or focus
/// mode) preserve the cue's existing span intact; explicit resizes enforce
/// `ZoomCue.minimumDuration` clamped against neighbouring cues.
func studioPlaceUpdatedZoomCue(
    _ cue: ZoomCue,
    in cues: [ZoomCue],
    sourceDuration: TimeInterval
) -> [ZoomCue]? {
    var next = cues
    guard let index = next.firstIndex(where: { $0.id == cue.id }) else { return nil }
    let previous = next[index]
    var updated = studioSanitizedZoomCue(cue, sourceDuration: sourceDuration)
    let spanChanged = abs(updated.start - previous.start) > 0.000_001
        || abs(updated.end - previous.end) > 0.000_001
    if spanChanged {
        let bounds = studioZoomNeighborBounds(forCueAt: index, in: next, sourceDuration: sourceDuration)
        updated.start = min(
            max(updated.start, bounds.lower),
            max(bounds.lower, bounds.upper - ZoomCue.minimumDuration)
        )
        updated.end = min(
            max(updated.end, updated.start + ZoomCue.minimumDuration),
            bounds.upper
        )
    } else {
        updated.start = previous.start
        updated.end = previous.end
    }
    next[index] = updated
    return next
}

// MARK: - Drawing

/// How a block is painted: tinted softly at rest with matching label ink so
/// a busy multi-track timeline stays calm, and filled solid with `onTint`
/// marks when selected.
struct StudioBlockStyle {
    let tint: NSColor
    /// Marks on the solid, selected fill.
    var onTint: Color = .white

    static let zoom = StudioBlockStyle(tint: .controlAccentColor)
    static let layout = StudioBlockStyle(tint: .systemGreen)
    static let text = StudioBlockStyle(tint: .systemPurple)
    static let image = StudioBlockStyle(tint: .systemTeal)
    static let effect = StudioBlockStyle(tint: .systemGray)
    static let audio = StudioBlockStyle(tint: .systemIndigo)

    /// Tinted at rest, deepened slightly on hover, filled solid when selected.
    func fill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected {
            return fill(isHovering: isHovering)
        }
        return Color(nsColor: tint).opacity(isHovering ? 0.32 : 0.22)
    }

    func label(isSelected: Bool) -> Color {
        isSelected ? onTint : restingLabel
    }

    /// The tint, deepened on light backgrounds and lifted on dark ones, so
    /// resting labels read cleanly over their soft tint fill.
    private var restingLabel: Color {
        let tint = tint
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = tint
            appearance.performAsCurrentDrawingAppearance {
                resolved = tint.usingColorSpace(.sRGB) ?? tint
            }
            return appearance.isDarkAppearance
                ? resolved.blended(withFraction: 0.2, of: .white) ?? resolved
                : resolved.blended(withFraction: 0.4, of: .black) ?? resolved
        })
    }

    /// The solid tint, lifted a touch toward white in light mode; the pointer
    /// lifts it a little more.
    func fill(isHovering: Bool) -> Color {
        let tint = tint
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = tint
            appearance.performAsCurrentDrawingAppearance {
                resolved = tint.usingColorSpace(.sRGB) ?? tint
            }
            let lift = (appearance.isDarkAppearance ? 0 : 0.08) + (isHovering ? 0.1 : 0)
            return lift > 0 ? resolved.blended(withFraction: lift, of: .white) ?? resolved : resolved
        })
    }
}

/// A block's body: its fill, a faint light along the top and a hairline
/// rim, so neighbouring blocks and the track behind them stay apart.
struct StudioBlockSurface<Fill: ShapeStyle>: View {
    let fill: Fill
    @Environment(\.studioBlockCornerRadius) private var cornerRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(fill)
            .overlay {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.14), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                ))
            }
            .overlay {
                shape.strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
            }
    }
}

/// Diagonal stripes across a block, clipped to it.
struct StudioBlockHatch: View {
    let color: Color
    var spacing: CGFloat = 6
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
        .studioBlockClip()
    }
}

/// The one label every block uses: a glyph, its name, then a quieter
/// detail - usually how long the block runs, "Audio 00:56" style. As the
/// block narrows the detail goes first, then the name (a long one is
/// truncated while a few letters still show), then the glyph sits alone,
/// centred, so nothing is ever cut to a stub like "C…".
///
/// It always spans the whole block, so a surface put behind it covers the
/// block rather than just the line of text.
struct StudioBlockLabel: View {
    let systemImage: String
    let title: String
    var detail: String?
    let state: StudioBlockState
    let color: Color
    /// Where the line sits; audio keeps it along the top, over its waveform.
    var verticalAlignment: VerticalAlignment = .center

    var body: some View {
        line
            .frame(
                width: state.width,
                height: state.height,
                alignment: Alignment(horizontal: .leading, vertical: verticalAlignment)
            )
    }

    /// Collapses detail first, then the glyph - every block on a lane
    /// shares its glyph, while the title (a zoom's "1.5×") is what tells
    /// blocks apart - and only then the title.
    @ViewBuilder
    private var line: some View {
        let width = state.width
        if width >= StudioBlockMetrics.labelInset * 2 + 14 {
            ViewThatFits(in: .horizontal) {
                if let detail {
                    HStack(spacing: 5) {
                        glyph
                        HStack(spacing: 6) {
                            titleText
                            Text(detail)
                                .font(.system(size: 10.5).monospacedDigit())
                                .opacity(0.8)
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 5) {
                    glyph
                    titleText
                }
                .fixedSize()
                if width >= 88 {
                    HStack(spacing: 5) {
                        glyph
                        titleText
                            .truncationMode(.tail)
                    }
                }
                titleText
                    .fixedSize()
                glyph
            }
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, StudioBlockMetrics.labelInset)
            .frame(width: width, alignment: .leading)
            .allowsHitTesting(false)
        } else {
            glyph
                .foregroundStyle(color)
                .frame(width: width)
                .allowsHitTesting(false)
        }
    }

    private var glyph: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .medium))
    }

    /// Digits keep their width, so "1.5×" doesn't shuffle as it changes.
    private var titleText: Text {
        Text(title)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
    }
}

/// Selection: a yellow rim around the block, widening past each end into a
/// handle marked with a line (or tucked inside an end against the timeline's
/// edge so it is never clipped). The block itself is left as it was.
struct StudioSelectionFrame: View {
    let width: CGFloat
    let blockHeight: CGFloat

    init(width: CGFloat, blockHeight: CGFloat) {
        self.width = width
        self.blockHeight = blockHeight
    }

    init(blockWidth: CGFloat, blockHeight: CGFloat) {
        self.width = blockWidth + StudioBlockMetrics.handleWidth * 2
        self.blockHeight = blockHeight
    }

    var body: some View {
        StudioSelectionFrameShape()
            .fill(Color(nsColor: .systemYellow), style: FillStyle(eoFill: true))
            .overlay(alignment: .leading) { grip }
            .overlay(alignment: .trailing) { grip }
            .frame(
                width: width,
                height: blockHeight + StudioBlockMetrics.rimWidth * 2
            )
    }

    private var grip: some View {
        Capsule()
            .fill(Color.black.opacity(0.55))
            .frame(width: 1.5, height: 10)
            .frame(width: StudioBlockMetrics.handleWidth)
    }
}

/// The rim's outline: the frame's rounded rect with the selected block cut
/// out along its tightened corners, so the rim's two edges run parallel.
private struct StudioSelectionFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let rim = StudioBlockMetrics.rimWidth
        var path = Path(roundedRect: rect, cornerRadius: StudioBlockMetrics.selectionCornerRadius, style: .continuous)
        let block = rect.insetBy(dx: StudioBlockMetrics.handleWidth, dy: rim)
        if block.width > 0, block.height > 0 {
            path.addPath(Path(roundedRect: block, cornerRadius: StudioBlockMetrics.selectedCornerRadius, style: .continuous))
        }
        return path
    }
}

/// The mark inside an unselected block's end while the pointer would trim it.
struct StudioBlockGrip: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2, height: 10)
            .shadow(color: .black.opacity(0.25), radius: 0.5)
    }
}

/// The dashed block a drag across empty track will add. It sits in the
/// same frame the block will, minimum width included, so letting go never
/// makes it jump.
private struct StudioDraftBlock: View {
    let frame: StudioBlockFrame
    let height: CGFloat
    let tint: Color

    var body: some View {
        let shape = StudioBlockMetrics.shape
        shape
            .fill(tint.opacity(0.22))
            .overlay {
                shape.strokeBorder(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: frame.width, height: height)
            .offset(x: frame.minX, y: StudioBlockMetrics.inset)
            .allowsHitTesting(false)
    }
}
