//
//  ModifierTapMonitor.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox

/// Watches for shortcuts that are a modifier key on its own (Right ⌥, ⌥ ⌥), which Carbon hot keys can't be. A
/// listen-only event tap reads which modifiers go down and up, and only that some other key went down, repeated or went
/// up, or a click or scroll happened, never which key. Nothing typed is read, logged or kept. macOS gives such a tap
/// modifier and key events only with Input Monitoring (or Accessibility), so it runs only while some action has such a
/// shortcut.
/// Arms a detector after missed events: once its events show the keyboard quiet for the stretch, one reading of
/// whether any other key is down (`ModifierTapDetector.otherKeyDown`); when none is, gestures pressed after that reading
/// count. While a key is down it reads again a quarter of a second later.
@MainActor
final class ModifierTapArming {
    private var task: Task<Void, Never>?

    /// `detector` gives the detector as it is now (nil when its owner is gone); `arm` arms it at the reading's time.
    func start(_ detector: @escaping () -> ModifierTapDetector?, arm: @escaping (TimeInterval) -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled, let current = detector(), current.isUnsure {
                let now = ProcessInfo.processInfo.systemUptime
                guard current.canArm(at: now) else {
                    try? await Task.sleep(for: .seconds(max(current.quietEnds - now, 0.1)))
                    continue
                }
                guard ModifierTapDetector.otherKeyDown() else { return arm(now) }
                try? await Task.sleep(for: .seconds(0.25))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class ModifierTapMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = ModifierTapDetector()
    private var onTap: ((ModifierTapDetector.Tap) -> Void)?
    /// True when it may come back on (a timeout it couldn't recover from), false when it was turned off for the user.
    private var onStop: ((_ retryable: Bool) -> Void)?
    /// Bumped at every break in the events, so a tap queued before it doesn't run.
    private var generation = 0
    private var activationObserver: NSObjectProtocol?
    private let arming = ModifierTapArming()

    /// Privacy & Security › Input Monitoring: `Privacy_ListenEvent` is that page's anchor in System Settings' own search
    /// (PrivacySecurity.searchTerms on macOS 26.5.1 and 27.3, read 2026-11-17).
    static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    /// False when macOS doesn't let Sukusho watch the keyboard; the caller says so and offers the setting. `onStop` runs
    /// if macOS turns the watching off later and it can't come back on.
    func start(onTap: @escaping (ModifierTapDetector.Tap) -> Void, onStop: @escaping (_ retryable: Bool) -> Void) -> Bool {
        self.onTap = onTap
        self.onStop = onStop
        if tap != nil { return true }
        // Without either permission, creating the tap would raise macOS's prompt at launch; it's asked for on recording.
        guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<ModifierTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        // Without access tapCreate can still return a port that never delivers (RecordingPointerCapture saw this).
        guard CGEvent.tapIsEnabled(tap: port) else {
            CFMachPortInvalidate(port)
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        self.source = source
        detector = ModifierTapDetector()
        missEvents(at: ProcessInfo.processInfo.systemUptime)
        // Another app came to the front without a key or click Sukusho saw: a first tap before it doesn't pair with one
        // after.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
        return true
    }

    /// Events were missed, or watching starts: no gesture begun before counts, no tap queued before runs, and a tap waits
    /// for the keyboard to show itself quiet.
    private func missEvents(at time: TimeInterval) {
        detector.quiet = ModifierTapDetector.quietTime()
        detector.eventsMissed(at: time)
        generation += 1
        armWhenQuiet()
    }

    /// Secure input found changed, at an event or when a queued tap runs: keys were withheld meanwhile, so it's missed
    /// events either way, and a first tap before it can't pair with one after.
    private func sampleSecureInput(at time: TimeInterval) -> Bool {
        guard detector.secureInput(IsSecureEventInputEnabled(), at: time) else { return false }
        generation += 1
        armWhenQuiet()
        return true
    }

    private func armWhenQuiet() {
        arming.start({ [weak self] in self?.detector }, arm: { [weak self] in self?.detector.arm(at: $0) })
    }

    /// Something broke the gesture without events being missed (another app came forward): what was under way and what
    /// was queued both go.
    private func invalidate() {
        detector.interrupt()
        generation += 1
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        onTap = nil
        onStop = nil
        generation += 1
        arming.stop()
        activationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activationObserver = nil
    }

    private func stopForGood(retryable: Bool) {
        let onStop = onStop
        stop()
        // After the callback returns, like a tap.
        DispatchQueue.main.async { onStop?(retryable) }
    }

    /// A Carbon shortcut fired: the modifier held for it isn't a tap.
    func interrupt() {
        detector.interrupt()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout:
            // Sukusho took too long over an event: on again while macOS still allows it, else stopped and said so.
            missEvents(at: now)
            if let tap, CGPreflightListenEventAccess() || AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
            return stopForGood(retryable: true)
        case .tapDisabledByUserInput:
            // Turned off on the user's behalf: it stays off until Sukusho relaunches, and the shortcuts say so.
            return stopForGood(retryable: false)
        default:
            break
        }
        // The event's own time (NSEvent converts it to uptime): a busy main thread doesn't stretch a tap, and events still
        // queued from before the keyboard was seen quiet are judged by when they happened.
        let time = NSEvent(cgEvent: event)?.timestamp ?? now
        // Secure input came or went: keys typed meanwhile never reached the tap.
        _ = sampleSecureInput(at: time)
        switch type {
        case .flagsChanged:
            detector.interval = NSEvent.doubleClickInterval
            var taps = detector.flagsChanged(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue, at: time
            )
            // A modifier pressed or released with a mouse button down is part of a drag or a click.
            if NSEvent.pressedMouseButtons != 0 {
                detector.interrupt()
                taps = []
            }
            guard !taps.isEmpty else { return }
            // After the callback returns: a capture starting here shouldn't hold up the event tap. By then events may
            // have been missed, or a password field taken the keyboard.
            let queued = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == queued,
                      !self.sampleSecureInput(at: ProcessInfo.processInfo.systemUptime) else { return }
                taps.forEach { self.onTap?($0) }
            }
        case .keyDown:
            detector.keyDown(isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, at: time)
        case .keyUp:
            detector.keyUp(at: time)
        default:
            detector.interrupt()
        }
    }
}
