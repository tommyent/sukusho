//
//  ModifierTapMonitor.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox

/// Watches for shortcuts that are a modifier key on its own (Right ⌥, ⌥ ⌥), which Carbon hot keys can't be. A
/// listen-only event tap reads which modifiers go down and up, and only that some other key, click or scroll happened,
/// never which key: nothing typed is read, logged or kept. macOS gives such a tap modifier and key events only with
/// Input Monitoring (or Accessibility), so it runs only while some action has such a shortcut.
@MainActor
final class ModifierTapMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = ModifierTapDetector()
    private var onTap: ((ModifierTapDetector.Tap) -> Void)?

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
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
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
        return true
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
    }

    /// A Carbon shortcut fired: the modifier held for it isn't a tap.
    func interrupt() {
        detector.interrupt()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            detector.interrupt()
        case .flagsChanged:
            detector.interval = NSEvent.doubleClickInterval
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
            guard !taps.isEmpty, !IsSecureEventInputEnabled() else { return }
            // After the callback returns: a capture starting here shouldn't hold up the event tap.
            DispatchQueue.main.async { [weak self] in taps.forEach { self?.onTap?($0) } }
        default:
            detector.interrupt()
        }
    }
}
