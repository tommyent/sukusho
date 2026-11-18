//
//  HotkeyShortcutRecorder.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox
import Observation

/// Records a shortcut in Settings: keys with any modifier, a function key alone, or a modifier key tapped once (that key,
/// such as Right ⌥) or twice (⌥ ⌥). A single tap is kept after the double-click interval passes without a second one.
/// It watches Sukusho's own events only, so recording needs no permission.
@MainActor
@Observable
final class HotkeyShortcutRecorder {
    private(set) var isRecording = false
    /// Why the last keys were turned down; cleared when recording starts,
    /// stops or succeeds.
    private(set) var rejection: String?
    /// Whether a modifier tap can be recorded yet: not until the keyboard has been seen quiet, with no other key down.
    private(set) var canRecordTaps = false

    @ObservationIgnored private var monitor: Any?
    /// Settings stopped being the key window (another window or app came forward): the recording ends there.
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var taps = ModifierTapDetector()
    @ObservationIgnored private var pendingTap: Task<Void, Never>?
    @ObservationIgnored private let arming = ModifierTapArming()
    @ObservationIgnored var onShortcutRecorded: ((HotkeyShortcut) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        resignObserver.map(NotificationCenter.default.removeObserver)
    }

    func start() {
        stop()
        isRecording = true
        rejection = nil
        // Like the event tap: a key held since before Record was clicked was never seen going down (Sol's re-review).
        taps = .startingAt(ProcessInfo.processInfo.systemUptime)
        canRecordTaps = false
        arming.start({ [weak self] in self?.taps }, arm: { [weak self] time in
            self?.taps.arm(at: time)
            self?.canRecordTaps = true
        })
        HotkeyManager.shared.pauseForRecording { [weak self] in self?.stop() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }

        let types: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        isRecording = false
        rejection = nil
        pendingTap?.cancel()
        pendingTap = nil
        arming.stop()
        canRecordTaps = false

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        resignObserver.map(NotificationCenter.default.removeObserver)
        resignObserver = nil
        HotkeyManager.shared.resumeAfterRecording()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        pendingTap?.cancel()
        pendingTap = nil

        switch event.type {
        case .flagsChanged:
            taps.interval = NSEvent.doubleClickInterval
            let found = taps.flagsChanged(
                keyCode: Int(event.keyCode), flags: UInt64(event.modifierFlags.rawValue), at: event.timestamp
            )
            // As in other apps (ModifierTapMonitor): a modifier pressed or released with a mouse button down is part of a
            // drag or a click.
            if NSEvent.pressedMouseButtons != 0 {
                taps.interrupt()
                return event
            }
            if let double = found.first(where: { if case .twice = $0 { true } else { false } }) {
                finish(with: HotkeyShortcut(double))
            } else if let single = found.first {
                // Kept unless a second tap follows within the interval.
                let interval = taps.interval
                pendingTap = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let self, self.isRecording else { return }
                    self.finish(with: HotkeyShortcut(single))
                }
            }
            return event
        case .keyDown:
            taps.keyDown(isRepeat: event.isARepeat, at: event.timestamp)
            if event.keyCode == UInt16(kVK_Escape) {
                cancel()
                return nil
            }
            let shortcut = HotkeyShortcut(
                modifiers: HotkeyShortcut.Modifiers(from: event.modifierFlags),
                keyCode: Int(event.keyCode)
            )
            if let refusal = shortcut.refusal {
                NSSound.beep()
                rejection = refusal
                return nil
            }
            finish(with: shortcut)
            return nil
        case .keyUp:
            taps.keyUp(at: event.timestamp)
            return event
        default:
            // A click or a scroll isn't part of a shortcut, and ends a tap; it still does what it does.
            taps.interrupt()
            return event
        }
    }

    private func finish(with shortcut: HotkeyShortcut) {
        onShortcutRecorded?(shortcut)
        stop()
    }

    private func cancel() {
        guard isRecording else { return }
        onCancel?()
        stop()
    }
}
