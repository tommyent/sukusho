import Foundation
import Testing

struct StudioPlaybackTests {
    // MARK: - Timecode parser

    @Test func timecodeParserAcceptsSecondsMinutesHoursAndDecimals() {
        #expect(StudioPlayback.seconds(from: "0") == 0)
        #expect(StudioPlayback.seconds(from: "12") == 12)
        #expect(StudioPlayback.seconds(from: "12.5") == 12.5)
        #expect(StudioPlayback.seconds(from: ".25") == 0.25)
        #expect(StudioPlayback.seconds(from: "1:05") == 65)
        #expect(StudioPlayback.seconds(from: "01:05.5") == 65.5)
        #expect(StudioPlayback.seconds(from: "1:02:03") == 3723)
        #expect(StudioPlayback.seconds(from: "1:02:03.25") == 3723.25)
        #expect(StudioPlayback.seconds(from: "  00:12.4\n") == 12.4)
    }

    @Test func timecodeParserRejectsMalformedInputs() {
        let invalid = [
            "",
            "   ",
            ":",
            ":5",
            "5:",
            "1::5",
            "1:2:3:4",
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

    // MARK: - Frame duration and stepping

    @Test func frameDurationUsesNominalFrameRateWithThirtyFpsFallback() {
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 60) - (1.0 / 60)) < 1e-12)
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 24) - (1.0 / 24)) < 1e-12)
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 120) - (1.0 / 120)) < 1e-12)
        #expect(abs(StudioPlayback.frameDuration(nominalFrameRate: 29.97) - (1.0 / Double(Float(29.97)))) < 1e-12)

        for invalidRate: Float in [0, -30, 0.5, .nan, .infinity, -.infinity] {
            #expect(StudioPlayback.frameDuration(nominalFrameRate: invalidRate) == StudioPlayback.defaultFrameDuration)
        }
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

    @Test func studioNoticesGetFreshIdentityForRepeatedText() {
        let first = StudioNotice(text: "2×")
        let second = StudioNotice(text: "2×")
        #expect(first.text == second.text)
        #expect(first.id != second.id)
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

        // Arrows and Home/End.
        #expect(StudioPlayback.keyAction(keyCode: 123, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepFrames(-1))
        #expect(StudioPlayback.keyAction(keyCode: 124, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepFrames(1))
        #expect(StudioPlayback.keyAction(keyCode: 123, characters: nil, hasShift: true, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepSeconds(-1))
        #expect(StudioPlayback.keyAction(keyCode: 124, characters: nil, hasShift: true, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .stepSeconds(1))
        #expect(StudioPlayback.keyAction(keyCode: 115, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .seekToStart)
        #expect(StudioPlayback.keyAction(keyCode: 119, characters: nil, hasShift: false, hasOtherModifiers: false, isKHeld: false, isARepeat: false) == .seekToEnd)

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
