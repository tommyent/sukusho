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
import SwiftUI

struct StudioKeyCommands: NSViewRepresentable {
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
        /// K is down: J and L step a frame instead of playing.
        private var isKHeld = false

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
                    self?.isKHeld = false
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyUp {
                    if event.charactersIgnoringModifiers?.lowercased() == "k" {
                        self.isKHeld = false
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
            isKHeld = false
        }

        /// True when the key was one of the editor's playback keys and has been dealt with.
        private func handle(_ event: NSEvent) -> Bool {
            guard let model, model.isLoaded, !model.isRestoringDocument, !model.isEditingSourceRegion,
                  let window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return false }

            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let hasShift = modifiers.contains(.shift)
            let hasOtherModifiers = !modifiers.subtracting(.shift).isEmpty

            guard let action = StudioPlayback.keyAction(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                hasShift: hasShift,
                hasOtherModifiers: hasOtherModifiers,
                isKHeld: isKHeld,
                isARepeat: event.isARepeat
            ) else { return false }

            switch action {
            case .shuttle(let forward):
                model.shuttle(forward: forward)
            case .pauseAndHoldK:
                isKHeld = true
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
