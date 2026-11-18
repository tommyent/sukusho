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
@MainActor
final class ModifierTapMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = ModifierTapDetector()
    private var onTap: ((ModifierTapDetector.Tap) -> Void)?
    private var onStop: (() -> Void)?
    /// Bumped when events are missed, so a tap queued before then doesn't run.
    private var generation = 0
    /// Secure input (a password field) as the last event found it: macOS withholds keys from the tap while it's on.
    private var wasSecure = false
    private var activationObserver: NSObjectProtocol?

    /// Privacy & Security › Input Monitoring: `Privacy_ListenEvent` is that page's anchor in System Settings' own search
    /// (PrivacySecurity.searchTerms on macOS 26.5.1 and 27.3, read 2026-11-17).
    static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    /// False when macOS doesn't let Sukusho watch the keyboard; the caller says so and offers the setting. `onStop` runs
    /// if macOS turns the watching off later and it can't come back on.
    func start(onTap: @escaping (ModifierTapDetector.Tap) -> Void, onStop: @escaping () -> Void) -> Bool {
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
        ) { [weak self] _ in MainActor.assumeIsolated { self?.detector.interrupt() } }
        return true
    }

    /// Events were missed, or watching starts: no gesture begun before counts, no tap queued before runs, and a tap waits
    /// for the keyboard to show itself quiet.
    private func missEvents(at time: TimeInterval) {
        detector.quiet = ModifierTapDetector.quietTime()
        detector.eventsMissed(at: time)
        generation += 1
        wasSecure = IsSecureEventInputEnabled()
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
        activationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activationObserver = nil
    }

    private func stopForGood() {
        let onStop = onStop
        stop()
        // After the callback returns, like a tap.
        DispatchQueue.main.async { onStop?() }
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
            return stopForGood()
        case .tapDisabledByUserInput:
            // Turned off on the user's behalf: it stays off, and the shortcuts say so.
            return stopForGood()
        default:
            break
        }
        // The event's own time (NSEvent converts it to uptime): a busy main thread doesn't stretch a tap, and events still
        // queued from before the keyboard was seen quiet are judged by when they happened.
        let time = NSEvent(cgEvent: event)?.timestamp ?? now
        // Secure input came or went: keys typed meanwhile never reached the tap.
        if IsSecureEventInputEnabled() != wasSecure { missEvents(at: time) }
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
            // In a password field (secure input) other keys may not reach the tap, so a chord could look like a tap.
            guard !taps.isEmpty, !wasSecure else { return }
            // After the callback returns: a capture starting here shouldn't hold up the event tap. By then events may
            // have been missed, or a password field taken the keyboard.
            let queued = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == queued, !IsSecureEventInputEnabled() else { return }
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
