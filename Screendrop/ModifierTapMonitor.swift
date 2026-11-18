//
//  ModifierTapMonitor.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox

/// Watches for shortcuts that are a modifier key on its own (Right ⌥, ⌥ ⌥), which Carbon hot keys can't be. A
/// listen-only event tap reads which modifiers go down and up, and only that some other key went down or up, or a click
/// or scroll happened, never which key; when it can't tell from those (it just started, or missed events), it asks
/// macOS whether any other key is down, a yes or no. Nothing typed is read, logged or kept. macOS gives such a tap
/// modifier and key events only with Input Monitoring (or Accessibility), so it runs only while some action has such a
/// shortcut.
@MainActor
final class ModifierTapMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = ModifierTapDetector()
    private var onTap: ((ModifierTapDetector.Tap) -> Void)?
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

    /// False when macOS doesn't let Sukusho watch the keyboard; the caller says so and offers the setting.
    func start(onTap: @escaping (ModifierTapDetector.Tap) -> Void) -> Bool {
        self.onTap = onTap
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
        missEvents()
        // Another app came to the front without a key or click Sukusho saw: a first tap before it doesn't pair with one
        // after.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.detector.interrupt() } }
        return true
    }

    /// Events were missed, or watching starts: no gesture begun before counts, and no tap queued before runs.
    private func missEvents() {
        detector.eventsMissed()
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
        generation += 1
        activationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activationObserver = nil
    }

    /// A Carbon shortcut fired: the modifier held for it isn't a tap.
    func interrupt() {
        detector.interrupt()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // Secure input came or went: keys typed meanwhile never reached the tap.
        if IsSecureEventInputEnabled() != wasSecure { missEvents() }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            missEvents()
        case .flagsChanged:
            detector.interval = NSEvent.doubleClickInterval
            if detector.isUnsure, !Self.otherKeyDown() { detector.noKeysDown() }
            // The event's own time (NSEvent converts it to uptime), so a busy main thread doesn't stretch a tap.
            var taps = detector.flagsChanged(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags.rawValue, at: NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime
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
            detector.keyDown(isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            detector.keyUp()
        default:
            detector.interrupt()
        }
    }

    /// Whether a key other than a modifier is down, for when the detector can't know from the events it saw. Only the
    /// answer is used: which key is never kept.
    private static func otherKeyDown() -> Bool {
        (0..<128).contains { code in
            ModifierKeys.keys[code] == nil && code != kVK_Function && code != kVK_CapsLock
                && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
    }
}
