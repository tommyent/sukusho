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
    case markRange(StudioRangeEdge)
    case clearRange
    case deleteRange
    case toggleMarker
    case toggleSnapping
    case seekToEditPoint(forward: Bool)
    case consume
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
    /// over J/K/L, S, C, Space, ←/→, Home/End, or non-range deletes.
    static func keyAction(
        keyCode: UInt16,
        characters: String?,
        modifiers: StudioKeyModifiers,
        isARepeat: Bool,
        hasFocusedControl: Bool = false,
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
            guard !hasFocusedControl, modifiers.isEmpty, hasRangeSelection, !hasDeletableSelection else {
                return nil
            }
            return isARepeat ? .consume : .deleteRange
        default:
            break
        }

        let key = characters?.lowercased()
        if modifiers == .option, key == "x", hasRangeSelection {
            return isARepeat ? .consume : .clearRange
        }

        guard modifiers.isEmpty else { return nil }
        switch key {
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

    /// Markers whose source moments still survive in `timeline`, mapped to
    /// their edited times in playback order.
    static func markerEditorTimes(
        _ markers: [RecordingMarker],
        in timeline: RecordingClipTimeline
    ) -> [(marker: RecordingMarker, time: TimeInterval)] {
        markers
            .compactMap { marker -> (marker: RecordingMarker, time: TimeInterval)? in
                guard marker.sourceTime.isFinite,
                      let time = timeline.editorTime(forSourceTime: marker.sourceTime) else {
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
        playhead: TimeInterval,
        markers: [TimeInterval],
        recordedClicks: [TimeInterval],
        audioClipEdges: [TimeInterval] = []
    ) -> [TimeInterval] {
        var points: [TimeInterval] = []
        points.reserveCapacity(1 + audioClipEdges.count + markers.count + recordedClicks.count)
        if playhead.isFinite { points.append(playhead) }
        points.append(contentsOf: audioClipEdges.filter(\.isFinite))
        points.append(contentsOf: markers.filter(\.isFinite))
        points.append(contentsOf: recordedClicks.filter(\.isFinite))
        return points
    }

    /// Returns the nearest point in `points` within `tolerance` of `time`, or
    /// `time` unchanged when nothing is close enough.
    static func snapped(
        _ time: TimeInterval,
        to points: [TimeInterval],
        tolerance: TimeInterval
    ) -> TimeInterval {
        guard time.isFinite, tolerance.isFinite, tolerance > 0 else { return time }
        var best = time
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
