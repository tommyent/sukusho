import Foundation
import Testing

struct StudioPlaybackTests {
    // MARK: - Timecode parser

    @Test func timecodeParserAcceptsSecondsMinutesHoursAndDecimals() {
        #expect(StudioPlayback.seconds(from: "0") == 0)
        #expect(StudioPlayback.seconds(from: "12") == 12)
        #expect(StudioPlayback.seconds(from: "12.5") == 12.5)
        #expect(StudioPlayback.seconds(from: "60") == 60)
        #expect(StudioPlayback.seconds(from: "125.5") == 125.5)
        #expect(StudioPlayback.seconds(from: ".25") == 0.25)
        #expect(StudioPlayback.seconds(from: "1:05") == 65)
        #expect(StudioPlayback.seconds(from: "01:05.5") == 65.5)
        #expect(StudioPlayback.seconds(from: "90:59.9") == 5459.9)
        #expect(StudioPlayback.seconds(from: "1:02:03") == 3723)
        #expect(StudioPlayback.seconds(from: "1:02:03.25") == 3723.25)
        #expect(StudioPlayback.seconds(from: "  00:12.4\n") == 12.4)
    }

    @Test func timecodeParserRejectsMalformedInputs() {
        let overflowMinutes = String(repeating: "9", count: 308) + ":0"
        let invalid = [
            "",
            "   ",
            ":",
            ":5",
            "5:",
            "1::5",
            "1:2:3:4",
            "1:60",
            "1:60.0",
            "1:60:00",
            "1:00:60",
            "1:00:60.5",
            overflowMinutes,
            "-5",
            "1:-05",
            "+5",
            "1.5:00",
            "1:02.5:03",
            "1.2.3",
            ".",
            "abc",
            "1e2",
            "inf",
            "nan",
            "1 : 05",
        ]
        for input in invalid {
            #expect(StudioPlayback.seconds(from: input) == nil, "Expected nil for \(input.debugDescription)")
        }
    }

    @Test func studioTimeFormattersHandlePositionsLengthsTenthsCarryAndHours() {
        // Positions (`studioTimecode`) round down so a label never runs ahead of its frame.
        #expect(studioTimecode(0) == "0:00")
        #expect(studioTimecode(4.9) == "0:04")
        #expect(studioTimecode(59.99) == "0:59")
        #expect(studioTimecode(60) == "1:00")
        #expect(studioTimecode(605.9) == "10:05")
        #expect(studioTimecode(3599.9) == "59:59")
        #expect(studioTimecode(3600) == "1:00:00")
        #expect(studioTimecode(3665.9) == "1:01:05")
        #expect(studioTimecode(36_000) == "10:00:00")

        // Lengths (`studioClock`) round to the nearest second.
        #expect(studioClock(0) == "0:00")
        #expect(studioClock(4.4) == "0:04")
        #expect(studioClock(4.5) == "0:05")
        #expect(studioClock(59.4) == "0:59")
        #expect(studioClock(59.5) == "1:00")
        #expect(studioClock(3599.4) == "59:59")
        #expect(studioClock(3599.5) == "1:00:00")
        #expect(studioClock(3661.4) == "1:01:01")

        // Playhead readouts (`studioPreciseTimecode`) count integer tenths and carry cleanly.
        #expect(studioPreciseTimecode(0) == "0:00.0")
        #expect(studioPreciseTimecode(12.049) == "0:12.0")
        #expect(studioPreciseTimecode(59.94) == "0:59.9")
        #expect(studioPreciseTimecode(59.96) == "1:00.0")
        #expect(studioPreciseTimecode(65.26) == "1:05.3")
        #expect(studioPreciseTimecode(3599.94) == "59:59.9")
        #expect(studioPreciseTimecode(3599.96) == "1:00:00.0")
        #expect(studioPreciseTimecode(3661.44) == "1:01:01.4")

        // Invalid or negative inputs clamp to zero; huge finite inputs never overflow.
        for bad: Double in [-5, -0.1, .nan, .infinity, -.infinity] {
            #expect(studioTimecode(bad) == "0:00")
            #expect(studioClock(bad) == "0:00")
            #expect(studioPreciseTimecode(bad) == "0:00.0")
        }
        #expect(!studioTimecode(.greatestFiniteMagnitude).isEmpty)
        #expect(!studioClock(.greatestFiniteMagnitude).isEmpty)
        #expect(!studioPreciseTimecode(.greatestFiniteMagnitude).isEmpty)
    }

    @Test func preciseTimecodeCarriesTenthsAndUnchangedPrefillSkipsSeek() {
        #expect(StudioPlayback.preciseTimecode(0) == "0:00.0")
        #expect(StudioPlayback.preciseTimecode(12.049) == "0:12.0")
        #expect(StudioPlayback.preciseTimecode(59.96) == "1:00.0")
        #expect(StudioPlayback.preciseTimecode(3599.96) == "1:00:00.0")
        #expect(StudioPlayback.preciseTimecode(-5) == "0:00.0")
        #expect(StudioPlayback.preciseTimecode(.nan) == "0:00.0")

        // Opening at 12.049 prefills "0:12.0"; pressing Return untouched must not seek.
        let prefill = StudioPlayback.preciseTimecode(12.049)
        #expect(StudioPlayback.submittedTimecode(prefill, prefill: prefill) == nil)
        #expect(StudioPlayback.submittedTimecode("  \(prefill)  ", prefill: prefill) == nil)
        // Changing the text commits the new target, with or without leading zeroes.
        #expect(StudioPlayback.submittedTimecode("0:12.5", prefill: prefill) == 12.5)
        #expect(StudioPlayback.submittedTimecode("00:12.5", prefill: prefill) == 12.5)
        #expect(StudioPlayback.submittedTimecode("1:00:00.0", prefill: prefill) == 3600)
        #expect(StudioPlayback.submittedTimecode("12", prefill: prefill) == 12)
    }

    // MARK: - Frame duration and stepping

    @Test func frameDurationUsesNominalFrameRateWithThirtyFpsFallback() {
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 60) - (1.0 / 60)) < 1e-12)
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 24) - (1.0 / 24)) < 1e-12)
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 120) - (1.0 / 120)) < 1e-12)
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 29.97) - (1.0 / Double(Float(29.97)))) < 1e-12)
        // Finite positive rates below 1 fps are honored (e.g. timelapses/slides).
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 0.5) - 2.0) < 1e-12)

        for invalidRate: Float in [0, -30, .nan, .infinity, -.infinity] {
            #expect(StudioPlayback.frameDuration(nominalFrameRate: invalidRate) == StudioPlayback.defaultFrameDuration)
        }
    }

    @Test func frameStepTargetsHonorVariableFrameRateClipSpeedAndCuts() {
        // Variable frame rate recording with samples at 0, 16.7, 25, and 100 ms
        // and a nominal 30 fps rate: first press lands on 16.7 ms, not 33.3 ms.
        let vfrSamples: [TimeInterval] = [0.0, 0.0167, 0.025, 0.100]
        let vfrNeighborhood: (TimeInterval) -> StudioSampleNeighborhood? = { time in
            StudioPlayback.sampleNeighborhood(in: vfrSamples, at: time)
        }
        let vfrTimeline = RecordingClipTimeline.full(sourceDuration: 0.2)
        let f1 = StudioPlayback.steppedEditorTime(
            from: 0,
            frames: 1,
            timeline: vfrTimeline,
            frameDuration: 1.0 / 30,
            duration: vfrTimeline.duration,
            sampleNeighborhood: vfrNeighborhood
        )
        #expect(abs(f1 - 0.0167) < 1e-9)
        let f2 = StudioPlayback.steppedEditorTime(
            from: f1,
            frames: 1,
            timeline: vfrTimeline,
            frameDuration: 1.0 / 30,
            duration: vfrTimeline.duration,
            sampleNeighborhood: vfrNeighborhood
        )
        #expect(abs(f2 - 0.025) < 1e-9)
        let f3 = StudioPlayback.steppedEditorTime(
            from: f2,
            frames: 1,
            timeline: vfrTimeline,
            frameDuration: 1.0 / 30,
            duration: vfrTimeline.duration,
            sampleNeighborhood: vfrNeighborhood
        )
        #expect(abs(f3 - 0.100) < 1e-9)
        let back = StudioPlayback.steppedEditorTime(
            from: f3,
            frames: -1,
            timeline: vfrTimeline,
            frameDuration: 1.0 / 30,
            duration: vfrTimeline.duration,
            sampleNeighborhood: vfrNeighborhood
        )
        #expect(abs(back - 0.025) < 1e-9)

        // Starting between frames at 30 ms (where the 25 ms sample is displayed):
        // Previous Frame must step back to 16.7 ms, not stay on 25 ms; Next Frame goes to 100 ms.
        let backFromBetween = StudioPlayback.steppedEditorTime(
            from: 0.030,
            frames: -1,
            timeline: vfrTimeline,
            frameDuration: 1.0 / 30,
            duration: vfrTimeline.duration,
            sampleNeighborhood: vfrNeighborhood
        )
        #expect(abs(backFromBetween - 0.0167) < 1e-9)
        let forwardFromBetween = StudioPlayback.steppedEditorTime(
            from: 0.030,
            frames: 1,
            timeline: vfrTimeline,
            frameDuration: 1.0 / 30,
            duration: vfrTimeline.duration,
            sampleNeighborhood: vfrNeighborhood
        )
        #expect(abs(forwardFromBetween - 0.100) < 1e-9)

        // 2x clip from a 60 fps recording: one Right press steps by 1/120 editor s (1 source frame).
        let fastTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 4, speed: 2)
        ])
        let cfr60Samples = (0...240).map { Double($0) / 60 }
        let cfr60Neighborhood: (TimeInterval) -> StudioSampleNeighborhood? = { time in
            StudioPlayback.sampleNeighborhood(in: cfr60Samples, at: time)
        }
        let fastStepSample = StudioPlayback.steppedEditorTime(
            from: 1.0,
            frames: 1,
            timeline: fastTimeline,
            frameDuration: 1.0 / 60,
            duration: fastTimeline.duration,
            sampleNeighborhood: cfr60Neighborhood
        )
        #expect(abs(fastStepSample - (1.0 + 1.0 / 120)) < 1e-9)

        // Seek timescale preserves distinct ticks for 120 fps at 8x clip speed (960 frames/s).
        let frameAt120fps8x = 1.0 / (120.0 * 8.0)
        let ticks = frameAt120fps8x * Double(StudioPlayback.seekTimescale)
        #expect(abs(ticks - ticks.rounded()) < 1e-9 && ticks >= 1)

        // Fallback without sample timing still scales by clip speed.
        let fastStepFallback = StudioPlayback.steppedEditorTime(
            from: 1.0,
            frames: 1,
            timeline: fastTimeline,
            frameDuration: 1.0 / 60,
            duration: fastTimeline.duration,
            sampleNeighborhood: nil
        )
        #expect(abs(fastStepFallback - (1.0 + 1.0 / 120)) < 1e-9)

        // Stepping across a cut (including an exact, frame-aligned sample at 1.0)
        // skips the removed gap cleanly forward and lands on the last retained
        // sample strictly before sourceEnd (0.9) when stepping backward.
        let cutSamples: [TimeInterval] = [0.0, 0.5, 0.9, 1.0, 2.0, 2.5]
        let cutNeighborhood: (TimeInterval) -> StudioSampleNeighborhood? = { time in
            StudioPlayback.sampleNeighborhood(in: cutSamples, at: time)
        }
        let cutTimeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0, speed: 1),
            RecordingClipSegment(sourceStart: 2.0, sourceEnd: 3.0, speed: 1),
        ])
        let acrossCut = StudioPlayback.steppedEditorTime(
            from: 0.9,
            frames: 1,
            timeline: cutTimeline,
            frameDuration: 0.5,
            duration: cutTimeline.duration,
            sampleNeighborhood: cutNeighborhood
        )
        #expect(abs(acrossCut - 1.0) < 1e-9)
        let backAcrossCut = StudioPlayback.steppedEditorTime(
            from: 1.0,
            frames: -1,
            timeline: cutTimeline,
            frameDuration: 0.5,
            duration: cutTimeline.duration,
            sampleNeighborhood: cutNeighborhood
        )
        #expect(abs(backAcrossCut - 0.9) < 1e-9)

        // Exact 60 fps frame-aligned split at 1.0 s: Previous Frame at the cut
        // lands on 59/60 (0.983333333 s), not 0.
        let split60Timeline = RecordingClipTimeline(segments: [
            RecordingClipSegment(sourceStart: 0, sourceEnd: 1.0, speed: 1),
            RecordingClipSegment(sourceStart: 1.0, sourceEnd: 2.0, speed: 1),
        ])
        let backAt60Split = StudioPlayback.steppedEditorTime(
            from: 1.0,
            frames: -1,
            timeline: split60Timeline,
            frameDuration: 1.0 / 60,
            duration: split60Timeline.duration,
            sampleNeighborhood: cfr60Neighborhood
        )
        #expect(abs(backAt60Split - (59.0 / 60.0)) < 1e-9)
        // Also stepping back from just past the cut (within the first frame of segment 2).
        let backFromJustPastSplit = StudioPlayback.steppedEditorTime(
            from: 1.005,
            frames: -1,
            timeline: split60Timeline,
            frameDuration: 1.0 / 60,
            duration: split60Timeline.duration,
            sampleNeighborhood: cfr60Neighborhood
        )
        #expect(abs(backFromJustPastSplit - (59.0 / 60.0)) < 1e-9)
    }

    @Test func frameStepMathAdvancesAndClampsToDuration() {
        let frame60 = StudioPlayback.frameDuration(nominalFrameRate: 60)
        #expect(abs(StudioPlayback.steppedTime(from: 1.0, frames: 1, frameDuration: frame60, duration: 10) - (1.0 + 1.0 / 60)) < 1e-12)
        #expect(abs(StudioPlayback.steppedTime(from: 1.0, frames: -1, frameDuration: frame60, duration: 10) - (1.0 - 1.0 / 60)) < 1e-12)
        #expect(abs(StudioPlayback.steppedTime(from: 2.0, frames: 60, frameDuration: frame60, duration: 10) - 3.0) < 1e-12)

        // Clamps to bounds.
        #expect(StudioPlayback.steppedTime(from: 0.005, frames: -1, frameDuration: frame60, duration: 10) == 0)
        #expect(StudioPlayback.steppedTime(from: 9.995, frames: 1, frameDuration: frame60, duration: 10) == 10)
        #expect(StudioPlayback.steppedTime(from: 0, frames: 1, frameDuration: frame60, duration: 0) == 0)

        // Falls back cleanly on invalid frameDuration.
        #expect(abs(StudioPlayback.steppedTime(from: 1.0, frames: 1, frameDuration: 0, duration: 10) - (1.0 + 1.0 / 30)) < 1e-12)
    }

    // MARK: - Shuttle rates and badges

    @Test func shuttleRateDoublesUpToEightXAndResetsOnDirectionChangeOrPause() {
        // Forward from pause: 1 -> 2 -> 4 -> 8 -> 8.
        var rate = StudioPlayback.nextShuttleRate(currentRate: 1, isPlaying: false, forward: true)
        #expect(rate == 1)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: true)
        #expect(rate == 2)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: true)
        #expect(rate == 4)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: true)
        #expect(rate == 8)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: true)
        #expect(rate == 8)

        // Turning around restarts at -1×, then doubles to -8×.
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: false)
        #expect(rate == -1)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: false)
        #expect(rate == -2)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: false)
        #expect(rate == -4)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: false)
        #expect(rate == -8)
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: false)
        #expect(rate == -8)

        // Turning forward again restarts at 1×.
        rate = StudioPlayback.nextShuttleRate(currentRate: rate, isPlaying: true, forward: true)
        #expect(rate == 1)

        // Reverse from pause starts at -1×.
        #expect(StudioPlayback.nextShuttleRate(currentRate: 4, isPlaying: false, forward: false) == -1)
    }

    @Test func shuttleTitlesFormatForwardAndReverseBadges() {
        #expect(StudioPlayback.shuttleTitle(1) == "1×")
        #expect(StudioPlayback.shuttleTitle(2) == "2×")
        #expect(StudioPlayback.shuttleTitle(4) == "4×")
        #expect(StudioPlayback.shuttleTitle(8) == "8×")
        #expect(StudioPlayback.shuttleTitle(-1) == "◀ 1×")
        #expect(StudioPlayback.shuttleTitle(-2) == "◀ 2×")
        #expect(StudioPlayback.shuttleTitle(-8) == "◀ 8×")
        #expect(RecordingClipSegment.speedTitle(1.5) == "1.5×")
        #expect(RecordingClipSegment.speedTitle(2.0) == "2×")
    }

    @Test func shuttleResolutionRespectsPlayerCapabilitiesAndReadiness() {
        let notReady = StudioPlaybackCapabilities(
            isReady: false,
            canPlayFastForward: true,
            canPlaySlowForward: true,
            canPlayReverse: true,
            canPlaySlowReverse: true,
            canPlayFastReverse: true
        )
        #expect(StudioPlayback.resolveShuttle(currentRate: 1, isPlaying: false, forward: true, capabilities: notReady) == .ignore)

        // Supports -1× reverse, lacks fast reverse: second J stays at -1× instead of promising -2×.
        let reverseOnly = StudioPlaybackCapabilities(
            isReady: true,
            canPlayFastForward: false,
            canPlaySlowForward: false,
            canPlayReverse: true,
            canPlaySlowReverse: false,
            canPlayFastReverse: false
        )
        #expect(StudioPlayback.resolveShuttle(currentRate: 1, isPlaying: false, forward: false, capabilities: reverseOnly) == .play(rate: -1))
        #expect(StudioPlayback.resolveShuttle(currentRate: -1, isPlaying: true, forward: false, capabilities: reverseOnly) == .play(rate: -1))

        // Forward without fast forward runs 1× and 2×, then caps at 2× instead of requesting 4×.
        #expect(StudioPlayback.resolveShuttle(currentRate: 1, isPlaying: false, forward: true, capabilities: reverseOnly) == .play(rate: 1))
        #expect(StudioPlayback.resolveShuttle(currentRate: 1, isPlaying: true, forward: true, capabilities: reverseOnly) == .play(rate: 2))
        #expect(StudioPlayback.resolveShuttle(currentRate: 2, isPlaying: true, forward: true, capabilities: reverseOnly) == .play(rate: 2))

        // Lacks reverse entirely: falls back to -1s seek and reports the action taken.
        let noReverse = StudioPlaybackCapabilities(
            isReady: true,
            canPlayFastForward: true,
            canPlaySlowForward: false,
            canPlayReverse: false,
            canPlaySlowReverse: false,
            canPlayFastReverse: false
        )
        #expect(StudioPlayback.resolveShuttle(currentRate: 1, isPlaying: false, forward: false, capabilities: noReverse) == .seekStep(-1, notice: "-1s"))

        // Camera capability check: clip speed × shuttleRate > 2 requires fast forward.
        #expect(reverseOnly.supports(rate: 2))
        #expect(!reverseOnly.supports(rate: 4))
        #expect(!reverseOnly.supports(rate: -2))
    }

    @Test func cameraResyncTriggersAcrossCutsAndBoundedDriftAtHighSpeed() {
        let segA = UUID()
        let segB = UUID()

        // Crossing a cut always resyncs, even if source drift is tiny.
        #expect(StudioPlayback.shouldResyncCamera(
            expected: 2.05,
            actual: 2.0,
            segmentID: segB,
            lastSegmentID: segA,
            shuttleRate: 8
        ))

        // A 0.8 s cut at 8× exceeds the bounded tolerance even if segment IDs match.
        #expect(StudioPlayback.shouldResyncCamera(
            expected: 5.8,
            actual: 5.0,
            segmentID: segA,
            lastSegmentID: segA,
            shuttleRate: 8
        ))

        // Small jitter inside the same segment stays within tolerance.
        #expect(!StudioPlayback.shouldResyncCamera(
            expected: 5.08,
            actual: 5.0,
            segmentID: segA,
            lastSegmentID: segA,
            shuttleRate: 1
        ))
    }

    @Test func cameraSeekCoordinatorKeepsOneSeekInFlightCoalescesAndInvalidates() throws {
        var coordinator = StudioCameraSeekCoordinator()

        // First request dispatches immediately.
        let firstRequest = coordinator.requestSeek(to: 1.0)
        let first = try #require(firstRequest)
        #expect(coordinator.isSeeking)

        // Later targets while in flight coalesce to the latest without starting concurrent seeks.
        #expect(coordinator.requestSeek(to: 2.0) == nil)
        #expect(coordinator.requestSeek(to: 3.5) == nil)
        #expect(coordinator.pendingTarget == 3.5)

        // Completing the first seek dispatches one coalesced seek to 3.5.
        let next = coordinator.completeSeek(generation: first.generation, finished: true)
        guard case .startCoalescedSeek(let secondGen, let secondTarget) = next else {
            Issue.record("Expected coalesced seek, got \(next)")
            return
        }
        #expect(secondTarget == 3.5)
        #expect(coordinator.isSeeking)

        // Completing the coalesced seek applies the playback rate.
        #expect(coordinator.completeSeek(generation: secondGen, finished: true) == .applyPlaybackRate)
        #expect(!coordinator.isSeeking)

        // Invalidating on pause or lead-in rejects stale completions and allows a fresh seek.
        let thirdRequest = coordinator.requestSeek(to: 5.0)
        let third = try #require(thirdRequest)
        coordinator.invalidate()
        #expect(!coordinator.isSeeking)
        #expect(coordinator.completeSeek(generation: third.generation, finished: true) == .ignore)

        // An interrupted seek with no pending target clears isSeeking without applying a rate.
        let fourthRequest = coordinator.requestSeek(to: 6.0)
        let fourth = try #require(fourthRequest)
        #expect(coordinator.completeSeek(generation: fourth.generation, finished: false) == .ignore)
        #expect(!coordinator.isSeeking)

        // Unsupported-rate fallback (e.g. -4× reverse): repeated observer ticks coalesce
        // into one follow-up seek at the newest target without cancelling the active seek.
        let fallbackRequest = coordinator.requestSeek(to: 10.0)
        let fallback1 = try #require(fallbackRequest)
        #expect(coordinator.requestSeek(to: 9.92) == nil)
        #expect(coordinator.requestSeek(to: 9.84) == nil)
        let coalesced = coordinator.completeSeek(generation: fallback1.generation, finished: true)
        guard case .startCoalescedSeek(let fallback2Gen, let fallback2Target) = coalesced else {
            Issue.record("Expected coalesced fallback seek, got \(coalesced)")
            return
        }
        #expect(fallback2Target == 9.84)
        #expect(coordinator.completeSeek(generation: fallback2Gen, finished: true) == .applyPlaybackRate)
        #expect(!coordinator.isSeeking)
    }

    @Test func studioNoticesGetFreshIdentityForRepeatedText() {
        let first = StudioNotice(text: "2×")
        let second = StudioNotice(text: "2×")
        #expect(first.text == second.text)
        #expect(first.id != second.id)
    }

    // MARK: - Playback end boundary

    @Test func reverseEndHandlerStopsAtZeroInEitherEventOrder() {
        // Order A: periodic zero callback arrives before didPlayToEndTimeNotification.
        var orderA = StudioPlaybackBoundaryState(isPlaying: true, shuttleRate: -2, currentTime: 4.5)
        #expect(StudioPlayback.resolvePlaybackEnd(state: &orderA, trigger: .periodic(seconds: 0), duration: 10) == 0)
        #expect(orderA == StudioPlaybackBoundaryState(isPlaying: false, shuttleRate: 1, currentTime: 0))
        // Late end notification must not overwrite currentTime with duration.
        #expect(StudioPlayback.resolvePlaybackEnd(
            state: &orderA,
            trigger: .itemDidPlayToEnd(isCurrentItem: true, itemSeconds: 0, reverseEnd: 0, forwardEnd: 10),
            duration: 10
        ) == nil)
        #expect(orderA == StudioPlaybackBoundaryState(isPlaying: false, shuttleRate: 1, currentTime: 0))

        // Order B: didPlayToEndTimeNotification arrives before periodic zero callback.
        var orderB = StudioPlaybackBoundaryState(isPlaying: true, shuttleRate: -4, currentTime: 4.5)
        #expect(StudioPlayback.resolvePlaybackEnd(
            state: &orderB,
            trigger: .itemDidPlayToEnd(isCurrentItem: true, itemSeconds: 0, reverseEnd: 0, forwardEnd: 10),
            duration: 10
        ) == 0)
        #expect(orderB == StudioPlaybackBoundaryState(isPlaying: false, shuttleRate: 1, currentTime: 0))
        #expect(StudioPlayback.resolvePlaybackEnd(state: &orderB, trigger: .periodic(seconds: 0), duration: 10) == nil)
        #expect(orderB == StudioPlaybackBoundaryState(isPlaying: false, shuttleRate: 1, currentTime: 0))

        // Forward boundary stops at duration in either order too.
        var forward = StudioPlaybackBoundaryState(isPlaying: true, shuttleRate: 2, currentTime: 9.9)
        #expect(StudioPlayback.resolvePlaybackEnd(
            state: &forward,
            trigger: .itemDidPlayToEnd(isCurrentItem: true, itemSeconds: 10, reverseEnd: 0, forwardEnd: 10),
            duration: 10
        ) == 10)
        #expect(forward == StudioPlaybackBoundaryState(isPlaying: false, shuttleRate: 1, currentTime: 10))
        #expect(StudioPlayback.resolvePlaybackEnd(state: &forward, trigger: .periodic(seconds: 10), duration: 10) == nil)

        // Delayed reverse notification arriving after L has started forward playback is ignored.
        var reversedThenForward = StudioPlaybackBoundaryState(isPlaying: true, shuttleRate: 1, currentTime: 0.02)
        #expect(StudioPlayback.resolvePlaybackEnd(
            state: &reversedThenForward,
            trigger: .itemDidPlayToEnd(isCurrentItem: true, itemSeconds: 0, reverseEnd: 0, forwardEnd: 10),
            duration: 10
        ) == nil)
        #expect(reversedThenForward == StudioPlaybackBoundaryState(isPlaying: true, shuttleRate: 1, currentTime: 0.02))

        // Notification from a non-current item is ignored even at the matching boundary.
        var staleItem = StudioPlaybackBoundaryState(isPlaying: true, shuttleRate: 1, currentTime: 10)
        #expect(StudioPlayback.resolvePlaybackEnd(
            state: &staleItem,
            trigger: .itemDidPlayToEnd(isCurrentItem: false, itemSeconds: 10, reverseEnd: 0, forwardEnd: 10),
            duration: 10
        ) == nil)
        #expect(staleItem.isPlaying)
    }

    // MARK: - Window key routing

    @Test func playbackKeyRoutingHandlesJKLArrowsAndHomeEndOnly() {
        #expect(StudioPlayback.keyAction(keyCode: 38, characters: "j", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .shuttle(forward: false))
        #expect(StudioPlayback.keyAction(keyCode: 37, characters: "l", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .shuttle(forward: true))
        #expect(StudioPlayback.keyAction(keyCode: 40, characters: "k", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .pauseAndHoldK)

        // Auto-repeat on bare J/L is swallowed without rocketing up speed; K+J/L repeats step frames.
        #expect(StudioPlayback.keyAction(keyCode: 37, characters: "l", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: true) == .consume)
        #expect(StudioPlayback.keyAction(keyCode: 38, characters: "j", hasShift: false, hasOtherModifiers: false, isKHeld: true, isARepeat: false) == .stepFrames(-1))
        #expect(StudioPlayback.keyAction(keyCode: 37, characters: "l", hasShift: false, hasOtherModifiers: false, isKHeld: true, isARepeat: true) == .stepFrames(1))

        // Only a fresh K press arms the chord; a K repeat (e.g. after leaving a text field) does not.
        #expect(StudioPlayback.keyAction(keyCode: 40, characters: "k", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: true) == .consume)
        // Reconciling clears a latched K when the physical key is no longer down (e.g. released in menu tracking).
        #expect(StudioPlayback.reconcileHeldKey(40, isPhysicallyDown: { _ in true }) == 40)
        #expect(StudioPlayback.reconcileHeldKey(40, isPhysicallyDown: { _ in false }) == nil)
        #expect(StudioPlayback.reconcileHeldKey(nil, isPhysicallyDown: { _ in true }) == nil)

        // Arrows and Home/End.
        #expect(StudioPlayback.keyAction(keyCode: 123, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepFrames(-1))
        #expect(StudioPlayback.keyAction(keyCode: 124, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepFrames(1))
        #expect(StudioPlayback.keyAction(keyCode: 123, characters: nil, hasShift: true, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepSeconds(-1))
        #expect(StudioPlayback.keyAction(keyCode: 124, characters: nil, hasShift: true, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepSeconds(1))
        #expect(StudioPlayback.keyAction(keyCode: 115, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .seekToStart)
        #expect(StudioPlayback.keyAction(keyCode: 119, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .seekToEnd)

        // Focused inspector controls (e.g. Audio › Volume scrub handle) keep Left/Right and Home/End.
        #expect(StudioPlayback.keyAction(keyCode: 123, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false, hasFocusedControl: true) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 124, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false, hasFocusedControl: true) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 124, characters: nil, hasShift: true, hasOtherModifiers: false, isKHeld: false, isARepeat: false, hasFocusedControl: true) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 115, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false, hasFocusedControl: true) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 119, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false, hasFocusedControl: true) == nil)

        // Scrubber focus is scoped to its owning window: a focused slider in window A
        // must not make window B yield Left/Right/Home/End.
        final class WindowToken {}
        let windowA = WindowToken()
        let windowB = WindowToken()
        let idA = ObjectIdentifier(windowA)
        let idB = ObjectIdentifier(windowB)
        let sliderID = UUID()
        var registry = StudioScrubberFocusRegistry()
        registry.setFocused(sliderID, in: idA, focused: true)
        #expect(registry.hasFocusedScrubber(in: idA))
        #expect(!registry.hasFocusedScrubber(in: idB))
        registry.remove(sliderID)
        #expect(!registry.hasFocusedScrubber(in: idA))

        // Modified letters and Sukusho's existing shortcuts pass through untouched.
        #expect(StudioPlayback.keyAction(keyCode: 37, characters: "l", hasShift: true, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 37, characters: "l", hasShift: false, hasOtherModifiers: true, isKHeld: false, isARepeat: false) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 49, characters: " ", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 11, characters: "b", hasShift: false, hasOtherModifiers: true, isKHeld: false, isARepeat: false) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 29, characters: "0", hasShift: false, hasOtherModifiers: true, isKHeld: false, isARepeat: false) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 6, characters: "z", hasShift: false, hasOtherModifiers: true, isKHeld: false, isARepeat: false) == nil)
        #expect(StudioPlayback.keyAction(keyCode: 51, characters: "\u{7f}", hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == nil)
    }
}
