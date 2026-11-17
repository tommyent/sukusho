import Foundation
import Testing

/// Fable live check E: the pointer anywhere on the preview stack holds every card, and each countdown resumes after.
struct PreviewAutoCloseClockTests {
    @Test func hoveringTheStackPausesEveryCountdown() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = PreviewAutoCloseClock<Int>()
        clock.start(1, seconds: 10, now: t0)
        clock.start(2, seconds: 10, now: t0.addingTimeInterval(4))
        #expect(clock.remaining(1, now: t0.addingTimeInterval(6)) == 4)

        // Pointer on the stack from 6 s to 20 s: card 1 would have closed at 10 s, card 2 at 14 s.
        clock.pause(now: t0.addingTimeInterval(6))
        #expect(clock.remaining(1, now: t0.addingTimeInterval(12)) == nil)
        clock.resume(now: t0.addingTimeInterval(20))
        #expect(clock.remaining(1, now: t0.addingTimeInterval(20)) == 4)
        #expect(clock.remaining(2, now: t0.addingTimeInterval(20)) == 8)
        #expect(clock.remaining(1, now: t0.addingTimeInterval(30)) == 0)

        // A card captured while the stack is hovered starts its full time when the pointer leaves.
        clock.pause(now: t0.addingTimeInterval(30))
        clock.start(3, seconds: 10, now: t0.addingTimeInterval(32))
        clock.resume(now: t0.addingTimeInterval(35))
        #expect(clock.remaining(3, now: t0.addingTimeInterval(35)) == 10)

        clock.forget(3)
        #expect(clock.remaining(3, now: t0.addingTimeInterval(35)) == nil)
    }
}
