//
//  PreviewAutoCloseClock.swift
//  Screendrop
//

import Foundation

/// Each preview card's auto-close countdown. The pointer anywhere on the stack pauses every countdown, and leaving
/// resumes each with the time it had left (Fable live check E, 2026-11-17: only the card under the pointer was held,
/// so older cards vanished while being reached for).
nonisolated struct PreviewAutoCloseClock<ID: Hashable> {
    private var due: [ID: Date] = [:]
    private var pausedAt: Date?

    var isPaused: Bool { pausedAt != nil }

    mutating func start(_ id: ID, seconds: TimeInterval, now: Date) {
        due[id] = (pausedAt ?? now).addingTimeInterval(seconds)
    }

    mutating func forget(_ id: ID) {
        due[id] = nil
    }

    mutating func pause(now: Date) {
        if pausedAt == nil { pausedAt = now }
    }

    /// Every countdown moves on by the time the stack was hovered.
    mutating func resume(now: Date) {
        guard let pausedAt else { return }
        let held = now.timeIntervalSince(pausedAt)
        due = due.mapValues { $0.addingTimeInterval(held) }
        self.pausedAt = nil
    }

    /// Seconds left before `id` may close: nil while paused or for a card without a countdown, 0 once it's due.
    func remaining(_ id: ID, now: Date) -> TimeInterval? {
        guard pausedAt == nil, let date = due[id] else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
