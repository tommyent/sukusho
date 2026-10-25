import CoreGraphics
import Foundation
import Testing

struct RecordingPressCopiesTests {
    private struct Press: Equatable {
        let uptime: TimeInterval
        let point: CGPoint
        let isDown: Bool
    }

    private func appended(_ incoming: [Press]) -> [Press] {
        var presses: [Press] = []
        for press in incoming where !RecordingPressCopies.isCopy(press, of: presses, window: 0.05, uptime: \.uptime, matches: {
            $0.isDown == $1.isDown && $0.point == $1.point
        }) {
            presses.append(press)
        }
        return presses
    }

    @Test func aMonitorCopyArrivingAfterTheReleaseIsDropped() {
        let at = CGPoint(x: 100, y: 200)
        // The tap's down and up, then the monitors' late copies of both (sd-k0g0).
        let kept = appended([
            Press(uptime: 8.549, point: at, isDown: true), Press(uptime: 8.560, point: at, isDown: false),
            Press(uptime: 8.549, point: at, isDown: true), Press(uptime: 8.560, point: at, isDown: false),
        ])
        #expect(kept.count == 2)
    }

    @Test func aRealDoubleClickStaysTwoClicks() {
        let at = CGPoint(x: 40, y: 40)
        let kept = appended([
            Press(uptime: 1.0, point: at, isDown: true), Press(uptime: 1.08, point: at, isDown: false),
            Press(uptime: 1.0, point: at, isDown: true),
            Press(uptime: 1.16, point: at, isDown: true), Press(uptime: 1.24, point: at, isDown: false),
        ])
        #expect(kept.map(\.uptime) == [1.0, 1.08, 1.16, 1.24])
    }
}
