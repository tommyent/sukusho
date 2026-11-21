//
//  StudioKeyCommands.swift
//  Screendrop
//
//  Window-level playback keys for the Studio editor. They work wherever focus
//  sits in the Studio window, and stand aside while a text field is being
//  edited, a sheet is open, or crop or redaction picking is active.
//
//    J  K  L      play backward / pause / play forward; again to go faster
//    K + J / L    hold K and tap J or L to step a frame
//    ←  →         one frame; with ⇧, one second
//    Home  End    start / end
//

import AppKit
import CoreGraphics
import SwiftUI

struct StudioKeyCommands: NSViewRepresentable {
    /// Inspector scrub handles currently focused via SwiftUI `@FocusState`,
    /// scoped by owning window so a retained focus in one window (such as the
    /// annotation editor or another Studio window) never makes another Studio
    /// window yield arrow or navigation keys.
    private static var inspectorScrubberFocus = StudioScrubberFocusRegistry()

    static func isInspectorScrubberFocused(in window: NSWindow) -> Bool {
        inspectorScrubberFocus.hasFocusedScrubber(in: ObjectIdentifier(window))
    }

    static func setInspectorScrubberFocused(_ id: UUID, in window: NSWindow?, focused: Bool) {
        if focused, let window {
            inspectorScrubberFocus.setFocused(id, in: ObjectIdentifier(window), focused: true)
        } else {
            inspectorScrubberFocus.remove(id, from: window.map(ObjectIdentifier.init))
        }
    }

    let model: RecordingStudioModel

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.model = model
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        weak var model: RecordingStudioModel?
        private var monitor: Any?
        private var resignKeyObserver: NSObjectProtocol?
        private var menuTrackingObserver: NSObjectProtocol?
        /// Physical key code of K while held: J and L step a frame instead of playing.
        private var heldKKeyCode: UInt16?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let window else { return }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.heldKKeyCode = nil
                }
            }
            menuTrackingObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.heldKKeyCode = nil
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyUp {
                    if event.keyCode == self.heldKKeyCode
                        || event.charactersIgnoringModifiers?.lowercased() == "k" {
                        self.heldKKeyCode = nil
                    }
                    return event
                }
                return self.handle(event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            resignKeyObserver = nil
            if let menuTrackingObserver { NotificationCenter.default.removeObserver(menuTrackingObserver) }
            menuTrackingObserver = nil
            heldKKeyCode = nil
        }

        /// True when the key was one of the editor's playback keys and has been dealt with.
        private func handle(_ event: NSEvent) -> Bool {
            guard let model, model.isLoaded, !model.isRestoringDocument, !model.isEditingSourceRegion,
                  let window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return false }

            // Reconcile against live key state in case menu tracking or another
            // modal loop swallowed K's key-up while the window stayed key.
            heldKKeyCode = StudioPlayback.reconcileHeldKey(heldKKeyCode) { code in
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
            }

            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let hasShift = modifiers.contains(.shift)
            let hasOtherModifiers = !modifiers.subtracting(.shift).isEmpty

            let hasFocusedControl = (window.firstResponder is NSControl)
                || StudioKeyCommands.isInspectorScrubberFocused(in: window)

            guard let action = StudioPlayback.keyAction(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                hasShift: hasShift,
                hasOtherModifiers: hasOtherModifiers,
                isKHeld: heldKKeyCode != nil,
                isARepeat: event.isARepeat,
                hasFocusedControl: hasFocusedControl
            ) else { return false }

            switch action {
            case .shuttle(let forward):
                model.shuttle(forward: forward)
            case .pauseAndHoldK:
                heldKKeyCode = event.keyCode
                model.pause()
            case .stepFrames(let count):
                model.stepFrames(count)
            case .stepSeconds(let delta):
                model.pause()
                model.seek(to: model.currentTime + delta)
            case .seekToStart:
                model.pause()
                model.seek(to: 0)
            case .seekToEnd:
                model.pause()
                model.seek(to: model.duration)
            case .consume:
                break
            }
            return true
        }
    }
}
