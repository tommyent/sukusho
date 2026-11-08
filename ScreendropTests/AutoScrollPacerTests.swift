import Testing

@Suite struct AutoScrollPacerTests {
    /// A pacer whose first step was posted at t = 10 s, 100 px per step.
    private func pacer() -> AutoScrollPacer { AutoScrollPacer(stepPixels: 100, height: 1000, now: 10) }

    @Test("Nothing happens until a frame shown after the step reaches the engine")
    func waitsForFreshFrame() {
        var p = pacer()
        // Stitched height may already include rows from frames shown before the step.
        #expect(p.update(height: 1100, lastFrameTime: 9.9, now: 10.2) == .wait)
        #expect(p.update(height: 1100, lastFrameTime: 10.05, now: 10.2) == .step)
        // The next step waits again for a frame after it.
        #expect(p.update(height: 1300, lastFrameTime: 10.05, now: 10.25) == .wait)
    }

    @Test("A full step stitched posts the next at once, without waiting to settle")
    func fullStep() {
        var p = pacer()
        #expect(p.update(height: 1050, lastFrameTime: 10.1, now: 10.12) == .wait)
        #expect(p.update(height: 1100, lastFrameTime: 10.15, now: 10.17) == .step)
    }

    @Test("After the view settles, any part of a step carries on: only steps that moved nothing end the page")
    func partialSteps() {
        var most = pacer()
        #expect(most.update(height: 1060, lastFrameTime: 10.1, now: 10.3) == .wait)
        #expect(most.update(height: 1060, lastFrameTime: 10.1, now: 10.1 + AutoScrollPacer.settleTime) == .step)
        // The last of the page: a short step is progress, then three steps move nothing, each at another point.
        var end = pacer()
        #expect(end.update(height: 1030, lastFrameTime: 10.1, now: 10.5) == .step)
        #expect(end.update(height: 1030, lastFrameTime: 10.1, now: 10.5 + AutoScrollPacer.responseTime) == .stepElsewhere)
        #expect(end.update(height: 1030, lastFrameTime: 10.1, now: 10.5 + 2 * AutoScrollPacer.responseTime) == .stepElsewhere)
        #expect(end.update(height: 1030, lastFrameTime: 10.1, now: 10.5 + 3 * AutoScrollPacer.responseTime) == .endOfPage)
    }

    @Test("A step that changes nothing on screen is retried at the region's other points, then ends the page")
    func unanswered() {
        var p = pacer()
        #expect(p.update(height: 1000, lastFrameTime: 9, now: 10.5) == .wait)
        #expect(p.update(height: 1000, lastFrameTime: 9, now: 10 + AutoScrollPacer.responseTime) == .stepElsewhere)
        let retried = 10 + AutoScrollPacer.responseTime
        #expect(p.update(height: 1000, lastFrameTime: 9, now: retried + 0.5) == .wait)
        #expect(p.update(height: 1000, lastFrameTime: 9, now: retried + AutoScrollPacer.responseTime) == .stepElsewhere)
        #expect(p.update(height: 1000, lastFrameTime: 9, now: retried + 2 * AutoScrollPacer.responseTime) == .endOfPage)
    }

    @Test("A step at another point that moves the page is progress: the next goes where it went")
    func innerScrollerHandsOver() {
        // An inner scroller under the first point takes the step: its frames are placed without moving.
        var p = pacer()
        #expect(p.update(height: 1000, lastFrameTime: 10.1, now: 10.1 + AutoScrollPacer.settleTime) == .stepElsewhere)
        // There the page moves a full step.
        #expect(p.update(height: 1100, lastFrameTime: 10.6, now: 10.62) == .step)
        // The budget starts over: two more steps without progress still go elsewhere before the end.
        #expect(p.update(height: 1100, lastFrameTime: 10.6, now: 10.62 + AutoScrollPacer.responseTime) == .stepElsewhere)
    }

    @Test("A view that keeps changing with nothing stitched (a video, or rows already kept) stops after a few steps")
    func unstitched() {
        var p = pacer()
        var now = 10.0
        var actions: [AutoScrollPacer.Action] = []
        for _ in 0..<AutoScrollPacer.maximumStepsWithoutProgress {
            // A frame just now, so the view never settles; the step times out.
            now += AutoScrollPacer.stepTimeout
            actions.append(p.update(height: 1000, lastFrameTime: now - 0.01, now: now))
        }
        #expect(actions == Array(repeating: .stepElsewhere, count: AutoScrollPacer.maximumStepsWithoutProgress - 1) + [.endOfPage])
    }

    @Test("Changed and still steps share one budget: never more than three steps since the last progress")
    func mixedNoProgress() {
        // Sol's review case: the first step changes the view with nothing
        // stitched, the second changes nothing. Separate counters let a fourth
        // step through.
        var p = pacer()
        #expect(p.update(height: 1000, lastFrameTime: 10.1, now: 10.6) == .stepElsewhere)
        #expect(p.update(height: 1000, lastFrameTime: 10.1, now: 11.7) == .stepElsewhere)
        #expect(p.update(height: 1000, lastFrameTime: 10.1, now: 12.8) == .endOfPage)
        // The other order: unanswered first, then a changed view with nothing stitched.
        var q = pacer()
        #expect(q.update(height: 1000, lastFrameTime: 9, now: 11) == .stepElsewhere)
        #expect(q.update(height: 1000, lastFrameTime: 11.1, now: 11.6) == .stepElsewhere)
        #expect(q.update(height: 1000, lastFrameTime: 11.1, now: 12.7) == .endOfPage)
    }

    @Test("A pause with no new frame for the response time has lost track; one with frames coming hasn't")
    func lostTrack() {
        #expect(!AutoScrollPacer.hasLostTrack(lastFrameTime: 10, now: 10.5))
        #expect(AutoScrollPacer.hasLostTrack(lastFrameTime: 10, now: 10 + AutoScrollPacer.responseTime))
    }

    @Test("Stitching again after re-covering kept rows resets the allowance")
    func recoversAfterUnstitched() {
        var p = pacer()
        var now = 10.0
        for _ in 0..<(AutoScrollPacer.maximumStepsWithoutProgress - 1) {
            now += AutoScrollPacer.stepTimeout
            #expect(p.update(height: 1000, lastFrameTime: now - 0.01, now: now) == .stepElsewhere)
        }
        now += 0.5
        #expect(p.update(height: 1100, lastFrameTime: now - 0.25, now: now) == .step)
        for _ in 0..<(AutoScrollPacer.maximumStepsWithoutProgress - 1) {
            now += AutoScrollPacer.stepTimeout
            #expect(p.update(height: 1100, lastFrameTime: now - 0.25, now: now) == .stepElsewhere)
        }
    }
}
