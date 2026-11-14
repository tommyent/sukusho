//
//  ScrollingCaptureAutoScrollPacer.swift
//  Screendrop
//

import Foundation

/// Decides when auto-scroll posts its next step and when the page has run
/// out, from the stitched height and the newest stream frame's display time.
/// Free of events and timers, so the pacing is checked on its own.
///
/// One step is in flight at a time, and nothing happens until a frame shown
/// after the step has reached the engine. The scroll amount never places
/// rows: progress is only what the engine stitched.
///
/// - A full step stitched: post the next one.
/// - The view went still (no new frame for `settleTime`), or the step ran
///   out of time: anything stitched is progress (an app scrolling less than
///   asked, or the last of the page), so carry on. The end of the page ends
///   the capture, so a step that moved, however little, never counts as it.
/// - Nothing on screen changed since the step (the page didn't move), or the
///   frames since it were placed without moving (a playing video at the end
///   of the page, or an inner scroller that took the step): they share one
///   budget. Each such step is followed by one at another of the region's
///   points, and at most `maximumStepsWithoutProgress` steps are ever posted
///   since the last stitched progress, then the page has ended. Frames that
///   don't fit never count: the caller pauses on one and starts a new pacer
///   once a frame is placed, so the end of the page only follows steps whose
///   frames were placed.
nonisolated struct AutoScrollPacer: Equatable {
    enum Action: Equatable {
        /// The step is still under way.
        case wait
        /// Post the next step now, where the last one went.
        case step
        /// Post the next step now at the region's next point: the last one moved nothing stitched,
        /// and an inner scroller under the point (MDN's example boxes) may have taken it.
        case stepElsewhere
        /// The page has run out.
        case endOfPage
    }

    /// No new frame for this long means the view has stopped moving.
    static let settleTime: TimeInterval = 0.25
    /// SCK idle/unchanged samples covering this long after a retry probe
    /// (`stepsWithoutProgress > 1`) mean the view did not move in response to it.
    static let idleResponseTime: TimeInterval = 0.375
    /// First step whose view keeps changing (a playing video) is judged by
    /// what it stitched after this long; subsequent probe steps tighten to `retryStepTimeout`.
    static let stepTimeout: TimeInterval = 1.25
    static let retryStepTimeout: TimeInterval = 0.625
    /// Fallback when neither a frame nor an idle stream sample arrived after a step.
    static let responseTime: TimeInterval = 1
    /// Steps posted since the last stitched progress, the one in flight
    /// included, one at each of the region's points: the view stays within
    /// three quarter-region steps of what was stitched. Five carried the page
    /// a region and a quarter past it on a playing video that blocks
    /// registration (VM, 2026-10-10).
    /// ponytail: re-covering rows captured before auto-scroll started would
    /// end the capture after this too; the stitcher trims the output when the
    /// view moves back up, so re-covered rows are appended again instead.
    static let maximumStepsWithoutProgress = 3

    /// Paused on a frame that doesn't fit, with no new frame since it for `responseTime`: the
    /// view is at rest where nothing fits, and no further step can bring one back, so
    /// auto-scroll hands the session back (lost track).
    static func hasLostTrack(lastFrameTime: TimeInterval, now: TimeInterval) -> Bool {
        now - lastFrameTime >= responseTime
    }

    /// One step's distance, in captured pixels.
    let stepPixels: Int
    private var postedAt: TimeInterval
    private var startHeight: Int
    private var stepsWithoutProgress = 1

    /// Starts pacing with the first step posted at `now`, at this height.
    /// Times are the stream's clock (`ScrollingCaptureSampleTiming.now()`).
    init(stepPixels: Int, height: Int, now: TimeInterval) {
        self.stepPixels = max(1, stepPixels)
        postedAt = now
        startHeight = height
    }

    /// Takes the stitched height, the newest placed/changed frame time, and the
    /// newest stream sample time (`.idle` and identical frames included).
    mutating func update(height: Int, lastFrameTime: TimeInterval, lastSampleTime: TimeInterval = -.infinity, now: TimeInterval) -> Action {
        let stitched = height - startHeight
        guard lastFrameTime > postedAt else {
            let idleConfirmed = stepsWithoutProgress > 1
                && lastSampleTime - postedAt >= Self.idleResponseTime
                && now - postedAt >= Self.idleResponseTime
            guard idleConfirmed || now - postedAt >= Self.responseTime else { return .wait }
            return noProgress(height: height, now: now)
        }
        if stitched >= stepPixels { return progress(height: height, now: now) }
        let timeout = stepsWithoutProgress > 1 ? Self.retryStepTimeout : Self.stepTimeout
        guard now - lastFrameTime >= Self.settleTime || now - postedAt >= timeout else { return .wait }
        return stitched > 0 ? progress(height: height, now: now) : noProgress(height: height, now: now)
    }

    private mutating func progress(height: Int, now: TimeInterval) -> Action {
        stepsWithoutProgress = 1
        post(height: height, now: now)
        return .step
    }

    private mutating func noProgress(height: Int, now: TimeInterval) -> Action {
        guard stepsWithoutProgress < Self.maximumStepsWithoutProgress else { return .endOfPage }
        stepsWithoutProgress += 1
        post(height: height, now: now)
        return .stepElsewhere
    }

    private mutating func post(height: Int, now: TimeInterval) {
        postedAt = now
        startHeight = height
    }
}
