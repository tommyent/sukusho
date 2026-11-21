//
//  StudioPlayback.swift
//  Screendrop
//
//  Pure playback state math, timecode parsing, key routing, and canvas notice
//  values for the Studio editor. Compiled into both the app and ScreendropTests.
//

import Foundation

/// A word shown over the picture for a moment. Each one is new, so the
/// same word twice in a row still shows again.
nonisolated struct StudioNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
}

nonisolated enum StudioPlaybackKeyAction: Equatable, Sendable {
    case shuttle(forward: Bool)
    case pauseAndHoldK
    case stepFrames(Int)
    case stepSeconds(TimeInterval)
    case seekToStart
    case seekToEnd
    case consume
}

nonisolated struct StudioPlaybackBoundaryState: Equatable, Sendable {
    var isPlaying: Bool
    var shuttleRate: Float
    var currentTime: TimeInterval
}

nonisolated enum StudioPlaybackEndTrigger: Equatable, Sendable {
    case periodic(seconds: TimeInterval)
    case itemDidPlayToEnd(reverseEnd: TimeInterval, forwardEnd: TimeInterval)
}

nonisolated enum StudioPlayback {
    static let maxShuttleRate: Float = 8
    static let defaultFrameDuration: TimeInterval = 1.0 / 30

    /// Next J/K/L rate. Playing in the same direction doubles up to 8×;
    /// starting from pause or reversing begins at normal speed (1× or -1×).
    static func nextShuttleRate(currentRate: Float, isPlaying: Bool, forward: Bool) -> Float {
        let direction: Float = forward ? 1 : -1
        if isPlaying, currentRate * direction > 0 {
            let base = max(abs(currentRate), 1)
            return direction * min(base * 2, maxShuttleRate)
        }
        return direction
    }

    /// "2×", "◀ 1×".
    static func shuttleTitle(_ rate: Float) -> String {
        let speed = RecordingClipSegment.speedTitle(Double(abs(rate)))
        return rate < 0 ? "◀ \(speed)" : speed
    }

    /// Idempotent boundary transition shared by the periodic time observer and
    /// `AVPlayerItem.didPlayToEndTimeNotification`. Returns the endpoint to
    /// seek to when this event stops playback, or `nil` if playback already
    /// stopped or has not reached a boundary.
    static func resolvePlaybackEnd(
        state: inout StudioPlaybackBoundaryState,
        trigger: StudioPlaybackEndTrigger,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard state.isPlaying else { return nil }
        let limit = max(duration.isFinite ? duration : 0, 0)
        let endpoint: TimeInterval
        switch trigger {
        case .periodic(let seconds):
            guard seconds.isFinite else { return nil }
            if state.shuttleRate < 0, seconds <= 0.001 {
                endpoint = 0
            } else if state.shuttleRate > 0, seconds >= limit - 0.001 {
                endpoint = limit
            } else {
                return nil
            }
        case .itemDidPlayToEnd(let reverseEnd, let forwardEnd):
            let raw = state.shuttleRate < 0 ? reverseEnd : forwardEnd
            endpoint = min(max(raw.isFinite ? raw : (state.shuttleRate < 0 ? 0 : limit), 0), limit)
        }
        state.isPlaying = false
        state.shuttleRate = 1
        state.currentTime = endpoint
        return endpoint
    }

    /// Duration of one frame from a video track's nominal frame rate, accepting
    /// finite positive rates below 1 fps and falling back to 30 fps otherwise.
    static func frameDuration(nominalFrameRate: Float) -> TimeInterval {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else {
            return defaultFrameDuration
        }
        return 1 / Double(nominalFrameRate)
    }

    /// Playhead time after stepping by whole frames using the approximate
    /// fallback duration, scaled by clip speed and clamped to `[0, duration]`.
    static func steppedTime(
        from currentTime: TimeInterval,
        frames count: Int,
        frameDuration: TimeInterval,
        duration: TimeInterval,
        clipSpeed: Double = 1
    ) -> TimeInterval {
        let step = frameDuration.isFinite && frameDuration > 0 ? frameDuration : defaultFrameDuration
        let speed = clipSpeed.isFinite && clipSpeed >= RecordingClipSegment.minimumSpeed ? clipSpeed : 1
        let limit = max(duration.isFinite ? duration : 0, 0)
        return min(max(currentTime + Double(count) * (step / speed), 0), limit)
    }

    /// Steps the playhead by `count` video frames along the edited timeline.
    /// When `adjacentSourceSample` supplies video sample presentation times,
    /// moves to the adjacent surviving sample (honoring VFR timestamps, clip
    /// speed, and cuts). When sample timing is unavailable, falls back to
    /// `frameDuration` scaled by the active clip's speed.
    static func steppedEditorTime(
        from currentTime: TimeInterval,
        frames count: Int,
        timeline: RecordingClipTimeline,
        frameDuration: TimeInterval,
        duration: TimeInterval,
        adjacentSourceSample: ((TimeInterval, Bool) -> TimeInterval?)? = nil
    ) -> TimeInterval {
        let limit = max(duration.isFinite ? duration : 0, 0)
        let clampedStart = min(max(currentTime.isFinite ? currentTime : 0, 0), limit)
        guard count != 0, limit > 0 else { return clampedStart }

        let forward = count > 0
        let epsilon: TimeInterval = 1e-5

        if let adjacentSourceSample, !timeline.segments.isEmpty {
            var editorTime = clampedStart
            for _ in 0..<abs(count) {
                guard let location = timeline.location(at: editorTime) else { break }
                let segmentIndex: Int
                let segmentEditorStart: TimeInterval
                let sourceTime: TimeInterval
                if !forward, location.offset <= epsilon, location.segmentIndex > 0 {
                    segmentIndex = location.segmentIndex - 1
                    let previous = timeline.segments[segmentIndex]
                    segmentEditorStart = location.editorStart - previous.editorDuration
                    sourceTime = previous.sourceEnd
                } else {
                    segmentIndex = location.segmentIndex
                    segmentEditorStart = location.editorStart
                    sourceTime = location.sourceTime
                }

                let segment = timeline.segments[segmentIndex]
                let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)

                if forward {
                    if let nextSource = adjacentSourceSample(sourceTime, true),
                       nextSource < segment.sourceEnd - epsilon {
                        editorTime = segmentEditorStart + max(0, nextSource - segment.sourceStart) / speed
                    } else if segmentIndex + 1 < timeline.segments.count {
                        let nextSegment = timeline.segments[segmentIndex + 1]
                        let nextEditorStart = segmentEditorStart + segment.editorDuration
                        let nextSpeed = max(nextSegment.speed, RecordingClipSegment.minimumSpeed)
                        if let first = adjacentSourceSample(nextSegment.sourceStart - 2 * epsilon, true),
                           first >= nextSegment.sourceStart - epsilon,
                           first < nextSegment.sourceEnd - epsilon {
                            editorTime = nextEditorStart + max(0, first - nextSegment.sourceStart) / nextSpeed
                        } else {
                            editorTime = nextEditorStart
                        }
                    } else {
                        editorTime = limit
                        break
                    }
                } else {
                    if let previousSource = adjacentSourceSample(sourceTime, false),
                       previousSource >= segment.sourceStart - epsilon {
                        editorTime = segmentEditorStart + min(segment.duration, max(0, previousSource - segment.sourceStart)) / speed
                    } else if segmentIndex > 0 {
                        let previousSegment = timeline.segments[segmentIndex - 1]
                        let previousEditorStart = segmentEditorStart - previousSegment.editorDuration
                        let previousSpeed = max(previousSegment.speed, RecordingClipSegment.minimumSpeed)
                        if let last = adjacentSourceSample(previousSegment.sourceEnd, false),
                           last >= previousSegment.sourceStart - epsilon,
                           last < previousSegment.sourceEnd - epsilon {
                            editorTime = previousEditorStart + min(previousSegment.duration, max(0, last - previousSegment.sourceStart)) / previousSpeed
                        } else {
                            editorTime = previousEditorStart
                        }
                    } else {
                        editorTime = 0
                        break
                    }
                }
            }
            return min(max(editorTime, 0), limit)
        }

        // Approximate fallback when sample timing is unavailable: scale one
        // nominal source frame by the active clip's speed.
        let clipSpeed = timeline.location(at: clampedStart).map {
            max(timeline.segments[$0.segmentIndex].speed, RecordingClipSegment.minimumSpeed)
        } ?? 1
        return steppedTime(
            from: clampedStart,
            frames: count,
            frameDuration: frameDuration,
            duration: limit,
            clipSpeed: clipSpeed
        )
    }

    /// Seconds from `ss`, `m:ss`, or `h:mm:ss`, allowing a decimal fraction on
    /// the last component.
    static func seconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { return nil }
            let isLast = index == parts.count - 1
            let allowed = part.allSatisfy { ch in
                (ch >= "0" && ch <= "9") || (isLast && ch == ".")
            }
            guard allowed, let value = Double(part), value.isFinite, value >= 0 else {
                return nil
            }
            total = total * 60 + value
        }
        return total
    }

    /// Maps a Studio window keyDown event to its playback action, leaving all
    /// other shortcuts (Space, ⌘B, ⌘0, ⌘Z, ⇧⌘Z, ⌫, etc.) untouched.
    static func keyAction(
        keyCode: UInt16,
        characters: String?,
        hasShift: Bool,
        hasOtherModifiers: Bool,
        isKHeld: Bool,
        isARepeat: Bool
    ) -> StudioPlaybackKeyAction? {
        switch keyCode {
        case 123, 124: // ← →
            guard !hasOtherModifiers else { return nil }
            let forward = keyCode == 124
            if hasShift {
                return .stepSeconds(forward ? 1 : -1)
            }
            return .stepFrames(forward ? 1 : -1)
        case 115: // Home
            guard !hasShift, !hasOtherModifiers else { return nil }
            return .seekToStart
        case 119: // End
            guard !hasShift, !hasOtherModifiers else { return nil }
            return .seekToEnd
        default:
            break
        }

        guard !hasShift, !hasOtherModifiers else { return nil }
        switch characters?.lowercased() {
        case "j":
            if isKHeld { return .stepFrames(-1) }
            return isARepeat ? .consume : .shuttle(forward: false)
        case "l":
            if isKHeld { return .stepFrames(1) }
            return isARepeat ? .consume : .shuttle(forward: true)
        case "k":
            return .pauseAndHoldK
        default:
            return nil
        }
    }
}
