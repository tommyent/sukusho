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

nonisolated struct StudioSampleNeighborhood: Equatable, Sendable {
    /// Sample currently displayed at the queried source time (the latest sample
    /// with presentation time `<= sourceTime + epsilon`).
    var displayed: TimeInterval?
    /// Sample immediately before `displayed` in presentation order.
    var previous: TimeInterval?
    /// Sample immediately after `displayed` (or the first sample when `displayed == nil`).
    var next: TimeInterval?
}

nonisolated struct StudioPlaybackCapabilities: Equatable, Sendable {
    var isReady: Bool
    var canPlayFastForward: Bool
    var canPlaySlowForward: Bool
    var canPlayReverse: Bool
    var canPlaySlowReverse: Bool
    var canPlayFastReverse: Bool

    /// Per AVFoundation's `AVPlayerItem` contract, ready items support forward
    /// rates in `1...2` unconditionally; `> 2` requires `canPlayFastForward`,
    /// `-1` requires `canPlayReverse`, `< -1` requires `canPlayFastReverse`,
    /// and fractional rates require the matching slow capability.
    func supports(rate: Float) -> Bool {
        guard isReady, rate.isFinite, rate != 0 else { return false }
        if rate > 2 { return canPlayFastForward }
        if rate >= 1 { return true }
        if rate > 0 { return canPlaySlowForward }
        if rate == -1 { return canPlayReverse }
        if rate > -1 { return canPlaySlowReverse }
        return canPlayFastReverse
    }
}

nonisolated enum StudioShuttleResolution: Equatable, Sendable {
    case play(rate: Float)
    case seekStep(TimeInterval, notice: String)
    case ignore
}

nonisolated struct StudioCameraSeekCoordinator: Equatable, Sendable {
    enum Completion: Equatable, Sendable {
        case ignore
        case applyPlaybackRate
        case startCoalescedSeek(generation: Int, target: TimeInterval)
    }

    private(set) var generation: Int = 0
    private(set) var isSeeking = false
    private(set) var pendingTarget: TimeInterval?

    /// Keeps at most one camera seek in flight. Returns `(generation, target)`
    /// to dispatch immediately when idle, or `nil` while a seek is already in
    /// flight (coalescing `target` to run once the active seek settles).
    mutating func requestSeek(to target: TimeInterval) -> (generation: Int, target: TimeInterval)? {
        if isSeeking {
            pendingTarget = target
            return nil
        }
        generation &+= 1
        isSeeking = true
        pendingTarget = nil
        return (generation, target)
    }

    mutating func completeSeek(generation seekGeneration: Int, finished: Bool) -> Completion {
        guard seekGeneration == generation, isSeeking else { return .ignore }
        if let next = pendingTarget {
            generation &+= 1
            pendingTarget = nil
            isSeeking = true
            return .startCoalescedSeek(generation: generation, target: next)
        }
        isSeeking = false
        return finished ? .applyPlaybackRate : .ignore
    }

    mutating func invalidate() {
        generation &+= 1
        isSeeking = false
        pendingTarget = nil
    }
}

nonisolated struct StudioScrubberFocusRegistry: Equatable, Sendable {
    private var focusedByWindow: [ObjectIdentifier: Set<UUID>] = [:]

    mutating func setFocused(_ id: UUID, in windowID: ObjectIdentifier, focused: Bool) {
        if focused {
            focusedByWindow[windowID, default: []].insert(id)
        } else {
            remove(id, from: windowID)
        }
    }

    mutating func remove(_ id: UUID, from windowID: ObjectIdentifier? = nil) {
        if let windowID {
            focusedByWindow[windowID]?.remove(id)
            if focusedByWindow[windowID]?.isEmpty == true {
                focusedByWindow.removeValue(forKey: windowID)
            }
        } else {
            for key in Array(focusedByWindow.keys) {
                focusedByWindow[key]?.remove(id)
                if focusedByWindow[key]?.isEmpty == true {
                    focusedByWindow.removeValue(forKey: key)
                }
            }
        }
    }

    func hasFocusedScrubber(in windowID: ObjectIdentifier) -> Bool {
        !(focusedByWindow[windowID]?.isEmpty ?? true)
    }
}

nonisolated struct StudioPlaybackBoundaryState: Equatable, Sendable {
    var isPlaying: Bool
    var shuttleRate: Float
    var currentTime: TimeInterval
}

nonisolated enum StudioPlaybackEndTrigger: Equatable, Sendable {
    case periodic(seconds: TimeInterval)
    case itemDidPlayToEnd(
        isCurrentItem: Bool,
        itemSeconds: TimeInterval?,
        reverseEnd: TimeInterval,
        forwardEnd: TimeInterval
    )
}

nonisolated enum StudioPlayback {
    static let maxShuttleRate: Float = 8
    static let defaultFrameDuration: TimeInterval = 1.0 / 30
    static let maxCameraDriftTolerance: TimeInterval = 0.25
    /// Seek timescale that preserves exact frame-step positions up to 120 fps
    /// at 8× clip speed (960 frames/s = 625 ticks/frame).
    static let seekTimescale: Int32 = 600_000

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

    /// Resolves a J/K/L shuttle request against the current player item's
    /// readiness and playback capabilities so the model never publishes or
    /// applies a rate the item cannot run.
    static func resolveShuttle(
        currentRate: Float,
        isPlaying: Bool,
        forward: Bool,
        capabilities: StudioPlaybackCapabilities
    ) -> StudioShuttleResolution {
        guard capabilities.isReady else { return .ignore }
        let desired = nextShuttleRate(currentRate: currentRate, isPlaying: isPlaying, forward: forward)
        if capabilities.supports(rate: desired) {
            return .play(rate: desired)
        }
        if !forward {
            if isPlaying, currentRate < 0, capabilities.supports(rate: currentRate) {
                return .play(rate: currentRate)
            }
            return .seekStep(-1, notice: "-1s")
        }
        if isPlaying, currentRate > 0, capabilities.supports(rate: currentRate) {
            return .play(rate: currentRate)
        }
        return .ignore
    }

    /// True when the independent camera player should resync to the screen
    /// timeline: always across a clip cut, or whenever source-time drift
    /// exceeds the bounded tolerance (capped so high shuttle rates still catch
    /// small cuts).
    static func shouldResyncCamera(
        expected: TimeInterval,
        actual: TimeInterval,
        segmentID: UUID?,
        lastSegmentID: UUID?,
        shuttleRate: Float
    ) -> Bool {
        if segmentID != lastSegmentID {
            return true
        }
        guard expected.isFinite, actual.isFinite else { return false }
        let tolerance = min(0.12 * Double(max(1, abs(shuttleRate))), maxCameraDriftTolerance)
        return abs(expected - actual) > tolerance
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
        case .itemDidPlayToEnd(let isCurrentItem, let itemSeconds, let reverseEnd, let forwardEnd):
            guard isCurrentItem, let itemSeconds, itemSeconds.isFinite else { return nil }
            let raw = state.shuttleRate < 0 ? reverseEnd : forwardEnd
            endpoint = min(max(raw.isFinite ? raw : (state.shuttleRate < 0 ? 0 : limit), 0), limit)
            // Half the minimum clip duration (0.12 s), so a delayed reverse
            // notification at 0 cannot match a forward boundary after L starts
            // forward playback (or vice versa).
            guard abs(itemSeconds - endpoint) <= 0.05 else { return nil }
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

    /// Resolves the displayed sample and its immediate neighbors from a sorted
    /// list of sample presentation times.
    static func sampleNeighborhood(
        in sortedSamples: [TimeInterval],
        at sourceTime: TimeInterval,
        epsilon: TimeInterval = 1e-5
    ) -> StudioSampleNeighborhood {
        guard !sortedSamples.isEmpty else {
            return StudioSampleNeighborhood(displayed: nil, previous: nil, next: nil)
        }
        guard let displayedIndex = sortedSamples.lastIndex(where: { $0 <= sourceTime + epsilon }) else {
            return StudioSampleNeighborhood(displayed: nil, previous: nil, next: sortedSamples.first)
        }
        let previous = displayedIndex > 0 ? sortedSamples[displayedIndex - 1] : nil
        let next = displayedIndex + 1 < sortedSamples.count ? sortedSamples[displayedIndex + 1] : nil
        return StudioSampleNeighborhood(
            displayed: sortedSamples[displayedIndex],
            previous: previous,
            next: next
        )
    }

    /// Steps the playhead by `count` video frames along the edited timeline.
    /// When `sampleNeighborhood` supplies the displayed video sample and its
    /// neighbors, resolves the currently displayed sample first and moves to
    /// the adjacent surviving sample (honoring VFR timestamps, in-between start
    /// times, clip speed, and cuts). When sample timing is unavailable, falls
    /// back to `frameDuration` scaled by the active clip's speed.
    static func steppedEditorTime(
        from currentTime: TimeInterval,
        frames count: Int,
        timeline: RecordingClipTimeline,
        frameDuration: TimeInterval,
        duration: TimeInterval,
        sampleNeighborhood: ((TimeInterval) -> StudioSampleNeighborhood?)? = nil
    ) -> TimeInterval {
        let limit = max(duration.isFinite ? duration : 0, 0)
        let clampedStart = min(max(currentTime.isFinite ? currentTime : 0, 0), limit)
        guard count != 0, limit > 0 else { return clampedStart }

        let forward = count > 0
        let epsilon: TimeInterval = 1e-5

        if let sampleNeighborhood, !timeline.segments.isEmpty {
            var editorTime = clampedStart
            for _ in 0..<abs(count) {
                guard let location = timeline.location(at: editorTime) else { break }
                let segmentIndex: Int
                let segmentEditorStart: TimeInterval
                let sourceTime: TimeInterval
                let crossedBackwardFromCut: Bool
                if !forward, location.offset <= epsilon, location.segmentIndex > 0 {
                    segmentIndex = location.segmentIndex - 1
                    let previous = timeline.segments[segmentIndex]
                    segmentEditorStart = location.editorStart - previous.editorDuration
                    sourceTime = previous.sourceEnd
                    crossedBackwardFromCut = true
                } else {
                    segmentIndex = location.segmentIndex
                    segmentEditorStart = location.editorStart
                    sourceTime = location.sourceTime
                    crossedBackwardFromCut = false
                }

                let segment = timeline.segments[segmentIndex]
                let speed = max(segment.speed, RecordingClipSegment.minimumSpeed)

                func lastSampleTime(in target: RecordingClipSegment, editorStart: TimeInterval) -> TimeInterval {
                    let targetSpeed = max(target.speed, RecordingClipSegment.minimumSpeed)
                    let boundary = sampleNeighborhood(target.sourceEnd)
                    let candidate: TimeInterval?
                    if let displayed = boundary?.displayed, displayed < target.sourceEnd - epsilon {
                        candidate = displayed
                    } else {
                        candidate = boundary?.previous
                    }
                    if let candidate, candidate >= target.sourceStart - epsilon {
                        return editorStart + min(target.duration, max(0, candidate - target.sourceStart)) / targetSpeed
                    }
                    return editorStart
                }

                if forward {
                    if let nextSource = sampleNeighborhood(sourceTime)?.next,
                       nextSource < segment.sourceEnd - epsilon {
                        editorTime = segmentEditorStart + max(0, nextSource - segment.sourceStart) / speed
                    } else if segmentIndex + 1 < timeline.segments.count {
                        let nextSegment = timeline.segments[segmentIndex + 1]
                        let nextEditorStart = segmentEditorStart + segment.editorDuration
                        let nextSpeed = max(nextSegment.speed, RecordingClipSegment.minimumSpeed)
                        let boundary = sampleNeighborhood(nextSegment.sourceStart)
                        if let displayed = boundary?.displayed,
                           displayed >= nextSegment.sourceStart - epsilon,
                           displayed < nextSegment.sourceEnd - epsilon {
                            editorTime = nextEditorStart + max(0, displayed - nextSegment.sourceStart) / nextSpeed
                        } else {
                            editorTime = nextEditorStart
                        }
                    } else {
                        editorTime = limit
                        break
                    }
                } else if crossedBackwardFromCut {
                    // Stepping back from a cut boundary lands on the last surviving
                    // sample strictly before the preceding segment's source end.
                    editorTime = lastSampleTime(in: segment, editorStart: segmentEditorStart)
                } else {
                    if let previousSource = sampleNeighborhood(sourceTime)?.previous,
                       previousSource >= segment.sourceStart - epsilon {
                        editorTime = segmentEditorStart + min(segment.duration, max(0, previousSource - segment.sourceStart)) / speed
                    } else if segmentIndex > 0 {
                        let previousSegment = timeline.segments[segmentIndex - 1]
                        let previousEditorStart = segmentEditorStart - previousSegment.editorDuration
                        editorTime = lastSampleTime(in: previousSegment, editorStart: previousEditorStart)
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

    /// Formats seconds as `m:ss.f` (or `h:mm:ss.f` past an hour) from a single
    /// rounded total of tenths so boundary values like `59.96` carry cleanly to
    /// `1:00.0`.
    static func preciseTimecode(_ seconds: TimeInterval) -> String {
        studioPreciseTimecode(seconds)
    }

    /// Returns the seek target when submitting the timecode field, or `nil` if
    /// the prefilled text is unchanged (so pressing Return without editing
    /// preserves sub-tenth playhead precision) or cannot be parsed.
    static func submittedTimecode(_ text: String, prefill: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != prefill.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return seconds(from: trimmed)
    }

    /// Seconds from `ss`, `m:ss`, or `h:mm:ss`, allowing a decimal fraction on
    /// the last component. Bare seconds may be 60 or larger; components after
    /// the first colon must stay below 60, and the accumulated total must stay
    /// finite.
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
            if index > 0, value >= 60 {
                return nil
            }
            total = total * 60 + value
            guard total.isFinite else { return nil }
        }
        return total
    }

    /// Reconciles a tracked held key code against physical key state (for
    /// example after menu tracking swallows a key-up event).
    static func reconcileHeldKey(
        _ heldKeyCode: UInt16?,
        isPhysicallyDown: (UInt16) -> Bool
    ) -> UInt16? {
        guard let heldKeyCode, isPhysicallyDown(heldKeyCode) else { return nil }
        return heldKeyCode
    }

    /// Maps a Studio window keyDown event to its playback action, leaving all
    /// other shortcuts (Space, ⌘B, ⌘0, ⌘Z, ⇧⌘Z, ⌫, etc.) untouched and
    /// yielding navigation/arrow keys when a focusable control (such as an
    /// inspector scrub handle or `NSControl`) has focus.
    static func keyAction(
        keyCode: UInt16,
        characters: String?,
        hasShift: Bool,
        hasOtherModifiers: Bool,
        isKHeld: Bool,
        isARepeat: Bool,
        hasFocusedControl: Bool = false
    ) -> StudioPlaybackKeyAction? {
        switch keyCode {
        case 123, 124: // ← →
            guard !hasFocusedControl, !hasOtherModifiers else { return nil }
            let forward = keyCode == 124
            if hasShift {
                return .stepSeconds(forward ? 1 : -1)
            }
            return .stepFrames(forward ? 1 : -1)
        case 115: // Home
            guard !hasFocusedControl, !hasShift, !hasOtherModifiers else { return nil }
            return .seekToStart
        case 119: // End
            guard !hasFocusedControl, !hasShift, !hasOtherModifiers else { return nil }
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
            return isARepeat ? .consume : .pauseAndHoldK
        default:
            return nil
        }
    }
}

// Studio writes every time one of two ways: `m:ss` for positions and
// lengths on the ruler, blocks, clips and window title, and `m:ss.f` for the
// playhead readouts. No leading zero on the minutes, `h:mm:ss` past an hour.

/// A position on the timeline, `m:ss`, rounded down so a label never runs
/// ahead of the frame it marks.
nonisolated func studioTimecode(_ seconds: Double) -> String {
    studioClockText(wholeSeconds: Int(studioSafeSeconds(seconds).rounded(.down)))
}

/// A length, `m:ss`, rounded to the nearest second.
nonisolated func studioClock(_ seconds: Double) -> String {
    studioClockText(wholeSeconds: Int(studioSafeSeconds(seconds).rounded()))
}

/// The playhead's time, `m:ss.f`. Counted in rounded integer tenths so
/// 59.96 reads 1:00.0, never 0:60.0.
nonisolated func studioPreciseTimecode(_ seconds: Double) -> String {
    let tenths = Int((studioSafeSeconds(seconds) * 10).rounded())
    return "\(studioClockText(wholeSeconds: tenths / 10)).\(tenths % 10)"
}

private nonisolated func studioSafeSeconds(_ seconds: Double) -> Double {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    return min(safe, 1e15)
}

private nonisolated func studioClockText(wholeSeconds total: Int) -> String {
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    return hours > 0
        ? "\(hours):\(String(format: "%02d:%02d", minutes, remainingSeconds))"
        : String(format: "%d:%02d", minutes, remainingSeconds)
}
