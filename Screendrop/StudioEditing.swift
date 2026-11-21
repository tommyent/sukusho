//
//  StudioEditing.swift
//  Screendrop
//
//  Pure editing types and math for the Studio editor: markers, range marking,
//  edit-point navigation, trim snapping, reorder math, and editing key routing.
//  Compiled into both the app and ScreendropTests.
//

import CoreGraphics
import Foundation

/// A flag dropped on the timeline with M. It sits on the source clock, so
/// it stays with its footage through cuts, and drops out of sight while
/// that footage is cut away.
nonisolated struct RecordingMarker: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var sourceTime: TimeInterval
    var note: String?
}

/// Which end of the I/O range selection is being marked.
nonisolated enum StudioRangeEdge: Equatable, Sendable {
    case start
    case end
}

/// Modifier flags normalized for pure key-routing checks.
nonisolated struct StudioKeyModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let shift = StudioKeyModifiers(rawValue: 1 << 0)
    static let option = StudioKeyModifiers(rawValue: 1 << 1)
    static let command = StudioKeyModifiers(rawValue: 1 << 2)
    static let control = StudioKeyModifiers(rawValue: 1 << 3)
}

/// Window-level editing shortcuts handled alongside `StudioPlaybackKeyAction`.
nonisolated enum StudioEditingKeyAction: Equatable, Sendable {
    case splitAtPlayhead
    case splitAtHover
    case deleteSelection
    case markRange(StudioRangeEdge)
    case clearRange
    case deleteRange
    case toggleMarker
    case toggleSnapping
    case seekToEditPoint(forward: Bool)
    case consume
}

/// Where live trim preview should seek the player: either an editor time on
/// the current cut composition, or a direct source time on the unedited source
/// asset when extending an edge restores footage outside the current cut.
nonisolated enum StudioTrimPreviewTarget: Equatable, Sendable {
    case editedTime(TimeInterval)
    case sourceTime(TimeInterval)
}

/// Coordinates cut-item rebuilds and temporary source-asset trim previews under
/// a single generation counter so competing async redaction tasks can never
/// leave an unedited source item active after trim release.
nonisolated struct StudioPlayerItemGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isCutReady = false
    private(set) var isShowingSourcePreview = false

    mutating func beginCutBuild(isAsync: Bool) -> UInt64 {
        generation &+= 1
        isShowingSourcePreview = false
        isCutReady = !isAsync
        return generation
    }

    mutating func finishCutBuild(generation token: UInt64) -> Bool {
        guard token == generation else { return false }
        isCutReady = true
        return true
    }

    /// Starts direct source preview only when a ready cut item exists to
    /// restore on release; returns nil while a cut rebuild is still in flight.
    mutating func beginSourcePreview(isAsync: Bool) -> UInt64? {
        guard isCutReady, !isShowingSourcePreview else { return nil }
        generation &+= 1
        isShowingSourcePreview = true
        _ = isAsync
        return generation
    }

    mutating func finishSourcePreview(generation token: UInt64) -> Bool {
        token == generation && isShowingSourcePreview
    }

    /// Handles a runtime player-item failure. When the temporary source-preview
    /// item fails, preserves `isCutReady` (keeping the saved redacted cut intact
    /// for release) and returns `true`. When the real cut item fails, invalidates
    /// the gate and returns `false`.
    mutating func handleRuntimeItemFailure() -> Bool {
        if isShowingSourcePreview {
            generation &+= 1
            return true
        }
        invalidate()
        return false
    }

    /// Ends direct source preview, returning true when the saved cut item
    /// should be restored onto the player.
    mutating func endSourcePreview() -> Bool {
        guard isShowingSourcePreview else { return false }
        generation &+= 1
        isShowingSourcePreview = false
        return isCutReady
    }

    mutating func invalidate() {
        generation &+= 1
        isCutReady = false
        isShowingSourcePreview = false
    }
}

nonisolated enum StudioEditing {
    /// How near, in points, a trimmed edge has to come to a snap point to catch.
    static let snapTolerancePoints: CGFloat = 7
    /// Minimum playhead proximity (seconds) for M to remove an existing marker.
    static let markerToggleToleranceMinimum: TimeInterval = 0.02

    /// Shared guard for window-level Studio key handling: stands aside in text
    /// fields, attached sheets, modal crop/redaction picking, or unloaded state.
    static func shouldHandleKeyEvent(
        isLoaded: Bool,
        isRestoringDocument: Bool,
        isEditingSourceRegion: Bool,
        isWindowMatch: Bool,
        hasAttachedSheet: Bool,
        isEditingText: Bool
    ) -> Bool {
        isLoaded
            && !isRestoringDocument
            && !isEditingSourceRegion
            && isWindowMatch
            && !hasAttachedSheet
            && !isEditingText
    }

    /// Maps a Studio window keyDown event to its editing action without taking
    /// over J/K/L, Space, ←/→, Home/End, or focused controls.
    static func keyAction(
        keyCode: UInt16,
        characters: String?,
        modifiers: StudioKeyModifiers,
        isARepeat: Bool,
        hasFocusedControl: Bool = false,
        hasHoverTime: Bool = false,
        hasRangeSelection: Bool = false,
        hasDeletableSelection: Bool = false
    ) -> StudioEditingKeyAction? {
        switch keyCode {
        case 126: // ↑
            guard !hasFocusedControl, modifiers.isEmpty else { return nil }
            return .seekToEditPoint(forward: false)
        case 125: // ↓
            guard !hasFocusedControl, modifiers.isEmpty else { return nil }
            return .seekToEditPoint(forward: true)
        case 51, 117: // ⌫, ⌦
            guard !hasFocusedControl, modifiers.isEmpty else { return nil }
            if hasDeletableSelection {
                return isARepeat ? .consume : .deleteSelection
            }
            if hasRangeSelection {
                return isARepeat ? .consume : .deleteRange
            }
            return nil
        default:
            break
        }

        let key = characters?.lowercased()
        if modifiers == .option, key == "x", hasRangeSelection {
            return isARepeat ? .consume : .clearRange
        }

        guard modifiers.isEmpty else { return nil }
        switch key {
        case "s":
            return isARepeat ? .consume : .splitAtPlayhead
        case "c":
            guard hasHoverTime else { return nil }
            return isARepeat ? .consume : .splitAtHover
        case "i":
            return isARepeat ? .consume : .markRange(.start)
        case "o":
            return isARepeat ? .consume : .markRange(.end)
        case "m":
            return isARepeat ? .consume : .toggleMarker
        case "n":
            return isARepeat ? .consume : .toggleSnapping
        default:
            return nil
        }
    }

    /// Updates an editor-time range selection when marking In (`.start`) or
    /// Out (`.end`) at `time`.
    static func markedRange(
        current: ClosedRange<TimeInterval>?,
        edge: StudioRangeEdge,
        at time: TimeInterval,
        duration: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard duration.isFinite, duration > 0 else { return nil }
        let clamped = min(max(time.isFinite ? time : 0, 0), duration)
        switch edge {
        case .start:
            let end = current.map { max($0.upperBound, clamped) } ?? duration
            var range = clamped...max(clamped, end)
            if range.upperBound - range.lowerBound <= 0.000_5 {
                // An In point at or past the old Out point opens to the end until O is pressed.
                range = clamped...duration
            }
            return range
        case .end:
            let start = current.map { min($0.lowerBound, clamped) } ?? 0
            return min(start, clamped)...clamped
        }
    }

    /// Accessible value for the timeline ruler, exposing both marked bounds
    /// whenever an I/O range is active.
    static func rulerAccessibilityValue(
        duration: TimeInterval,
        range: ClosedRange<TimeInterval>?
    ) -> String {
        if let range {
            return "Marked range \(studioPreciseTimecode(range.lowerBound)) to \(studioPreciseTimecode(range.upperBound))"
        }
        return "Duration \(studioClock(duration))"
    }

    /// Source timestamp to record for a marker dropped at `editorTime`.
    /// Uses the half-open footage owner at `editorTime`; at the timeline's
    /// terminal frame, steps back inside the final clip so a reordered join
    /// at that exact timestamp cannot claim the marker later.
    static func markerSourceTime(
        at editorTime: TimeInterval,
        in timeline: RecordingClipTimeline
    ) -> TimeInterval {
        guard let location = timeline.location(at: editorTime) else { return 0 }
        let segment = timeline.segments[location.segmentIndex]
        if location.sourceTime >= segment.sourceEnd - 0.000_001 {
            return max(segment.sourceStart, segment.sourceEnd - 0.001)
        }
        return location.sourceTime
    }

    /// Markers whose source moments still survive in `timeline`, mapped to
    /// their edited times in playback order.
    static func markerEditorTimes(
        _ markers: [RecordingMarker],
        in timeline: RecordingClipTimeline
    ) -> [(marker: RecordingMarker, time: TimeInterval)] {
        markers
            .compactMap { marker -> (marker: RecordingMarker, time: TimeInterval)? in
                guard marker.sourceTime.isFinite,
                      let time = timeline.editorTime(
                          forSourceEventTime: marker.sourceTime,
                          includeTimelineEnd: true
                      ) else {
                    return nil
                }
                return (marker, time)
            }
            .sorted { lhs, rhs in
                if abs(lhs.time - rhs.time) > 0.000_001 {
                    return lhs.time < rhs.time
                }
                return lhs.marker.sourceTime < rhs.marker.sourceTime
            }
    }

    /// Every moment worth jumping to with ↑/↓: video cuts, markers, and any
    /// audio clip edges.
    static func editPoints(
        timeline: RecordingClipTimeline,
        markerTimes: [TimeInterval],
        audioClipEdges: [TimeInterval] = [],
        duration: TimeInterval
    ) -> [TimeInterval] {
        let limit = max(duration.isFinite ? duration : 0, 0)
        var points = timeline.editPoints
        points.append(contentsOf: audioClipEdges)
        points.append(contentsOf: markerTimes)
        return points
            .filter { $0.isFinite && $0 >= 0 && $0 <= limit }
            .sorted()
    }

    /// Next or previous edit point from `currentTime` in `points` (sorted).
    static func nextEditPoint(
        from currentTime: TimeInterval,
        in points: [TimeInterval],
        duration: TimeInterval,
        forward: Bool
    ) -> TimeInterval {
        let limit = max(duration.isFinite ? duration : 0, 0)
        let current = min(max(currentTime.isFinite ? currentTime : 0, 0), limit)
        if forward {
            return points.first { $0 > current + 0.01 } ?? limit
        }
        return points.last { $0 < current - 0.01 } ?? 0
    }

    /// Editor times a trimmed video clip edge can snap to.
    static func clipSnapPoints(
        playhead: TimeInterval? = nil,
        markers: [TimeInterval],
        recordedClicks: [TimeInterval],
        audioClipEdges: [TimeInterval] = []
    ) -> [TimeInterval] {
        var points: [TimeInterval] = []
        points.reserveCapacity((playhead == nil ? 0 : 1) + audioClipEdges.count + markers.count + recordedClicks.count)
        if let playhead, playhead.isFinite { points.append(playhead) }
        points.append(contentsOf: audioClipEdges.filter(\.isFinite))
        points.append(contentsOf: markers.filter(\.isFinite))
        points.append(contentsOf: recordedClicks.filter(\.isFinite))
        return points
    }

    /// Returns the nearest snap target in `points` within `tolerance` of
    /// `time` (including an exact match where `point == time`), or `nil` when
    /// nothing is close enough.
    static func snapTarget(
        for time: TimeInterval,
        in points: [TimeInterval],
        tolerance: TimeInterval
    ) -> TimeInterval? {
        guard time.isFinite, tolerance.isFinite, tolerance > 0 else { return nil }
        var best: TimeInterval?
        var bestDistance = tolerance
        for point in points where point.isFinite {
            let distance = abs(point - time)
            if distance <= bestDistance {
                best = point
                bestDistance = distance
            }
        }
        return best
    }

    /// Returns the nearest point in `points` within `tolerance` of `time`, or
    /// `time` unchanged when nothing is close enough.
    static func snapped(
        _ time: TimeInterval,
        to points: [TimeInterval],
        tolerance: TimeInterval
    ) -> TimeInterval {
        snapTarget(for: time, in: points, tolerance: tolerance) ?? time
    }

    /// Source-time room a clip has to expand its leading or trailing edge
    /// without overlapping any other clip, regardless of clip list order.
    static func trimBounds(
        forClipID id: UUID,
        in timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval
    ) -> (previousEnd: TimeInterval, nextStart: TimeInterval)? {
        guard let clip = timeline.segments.first(where: { $0.id == id }) else { return nil }
        let safeDuration = max(sourceDuration.isFinite ? sourceDuration : 0, clip.sourceEnd)
        let others = timeline.segments.filter { $0.id != id }
        let previousEnd = others
            .map(\.sourceEnd)
            .filter { $0 <= clip.sourceStart + 0.000_5 }
            .max() ?? 0
        let nextStart = others
            .map(\.sourceStart)
            .filter { $0 >= clip.sourceEnd - 0.000_5 }
            .min() ?? safeDuration
        return (previousEnd, nextStart)
    }

    /// Picks whether live trim preview can seek the current cut composition or
    /// needs the source asset directly (when extending an edge restores cut
    /// footage, or once a drag has already switched to source preview). Gates
    /// direct source preview on a ready cut item so no race can lose the cut.
    static func trimPreviewTarget(
        forSourceTime sourceTime: TimeInterval,
        in timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        usingSourceAsset: Bool,
        hasReadyCutItem: Bool = true
    ) -> StudioTrimPreviewTarget? {
        guard sourceTime.isFinite else { return nil }
        let limit = max(sourceDuration.isFinite ? sourceDuration : 0, 0)
        let clamped = min(max(sourceTime, 0), limit)
        if !usingSourceAsset,
           let editorTime = timeline.editorTime(forSourceEventTime: clamped, includeTimelineEnd: true) {
            return .editedTime(editorTime)
        }
        guard hasReadyCutItem else { return nil }
        return .sourceTime(clamped)
    }

    /// Slot boundary index `0...segments.count` where a clip dragged to `time`
    /// will be inserted: before the first clip whose midpoint lies after `time`.
    static func reorderInsertionIndex(
        atEditorTime time: TimeInterval,
        in timeline: RecordingClipTimeline
    ) -> Int {
        var editorStart: TimeInterval = 0
        for (index, segment) in timeline.segments.enumerated() {
            if time < editorStart + segment.editorDuration / 2 {
                return index
            }
            editorStart += segment.editorDuration
        }
        return timeline.segments.count
    }

    /// Converts a slot boundary `insertionIndex` (`0...count`) into the final
    /// post-removal destination index for `moving(segmentID:to:)`, or `nil`
    /// when dropping in place.
    static func reorderDestinationIndex(
        from currentIndex: Int,
        insertionIndex: Int
    ) -> Int? {
        let target = insertionIndex > currentIndex ? insertionIndex - 1 : insertionIndex
        return target == currentIndex ? nil : target
    }
}
