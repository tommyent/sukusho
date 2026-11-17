//
//  DockProgressPacer.swift
//  Screendrop
//

/// DockProgress (5.1.0) eases its Dock bar toward each new value over one second, timed by a counter it resets only
/// when the bar reaches the value. A value that keeps moving for longer, as a slow export's does, pushes the counter
/// past 1 and stops a Debug build at the library's `0...1` assertion (Studio Export crash on m1, 2026-11-17). So a new
/// value goes in only when the bar shows the last one; until then the latest one waits.
nonisolated struct DockProgressPacer: Equatable {
    private(set) var held: Double?

    /// The value to hand DockProgress now, or nil while its bar is still easing (`shown` short of `target`).
    mutating func offer(_ value: Double, shown: Double, target: Double) -> Double? {
        guard shown == target else {
            held = value
            return nil
        }
        held = nil
        return value
    }

    /// The bar shows its target and nothing waits: what was handed over is on screen.
    func isSettled(shown: Double, target: Double) -> Bool {
        shown == target && held == nil
    }

    /// The value that waited, once the bar shows its target.
    mutating func release(shown: Double, target: Double) -> Double? {
        guard shown == target, let value = held else { return nil }
        held = nil
        return value
    }
}
