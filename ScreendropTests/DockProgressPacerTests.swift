import Testing

/// Studio Export crash on m1 (2026-11-17): DockProgress asserted when its value kept moving while the bar eased.
struct DockProgressPacerTests {
    @Test func aValueGoesInOnlyOnceTheBarShowsTheLastOne() {
        var pacer = DockProgressPacer()
        #expect(pacer.offer(0.1, shown: 0, target: 0) == 0.1)
        // Easing from 0 toward 0.1: newer values wait, and only the latest is kept.
        #expect(pacer.offer(0.2, shown: 0.04, target: 0.1) == nil)
        #expect(pacer.offer(0.3, shown: 0.07, target: 0.1) == nil)
        #expect(pacer.held == 0.3)
        #expect(pacer.release(shown: 0.09, target: 0.1) == nil)
        #expect(pacer.release(shown: 0.1, target: 0.1) == 0.3)
        #expect(pacer.held == nil)
        #expect(pacer.release(shown: 0.3, target: 0.3) == nil)
    }

    /// Astra: start, 0.2, 1, finish showed 0, 0.2, 0. A finished export's 1 waits its turn and is on the bar before reset.
    @Test func aFinishedExportFillsTheBarBeforeItClears() {
        var pacer = DockProgressPacer()
        #expect(pacer.offer(0.2, shown: 0, target: 0) == 0.2)
        #expect(pacer.offer(1, shown: 0.05, target: 0.2) == nil)
        #expect(!pacer.isSettled(shown: 0.2, target: 0.2))
        #expect(pacer.release(shown: 0.2, target: 0.2) == 1)
        #expect(!pacer.isSettled(shown: 0.6, target: 1))
        #expect(pacer.isSettled(shown: 1, target: 1))
    }
}
