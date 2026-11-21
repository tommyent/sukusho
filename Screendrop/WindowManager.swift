import AppKit
import ApplicationServices

/// Moves and resizes the frontmost app's focused window via macOS Accessibility (`AXUIElement`),
/// ported from Unleash. Prompts for Accessibility permission only on first use, never at launch.
/// All external `AXUIElement` IPC runs on a serial background queue so a hung app can never freeze Sukusho.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let axWorker = WindowAXWorker()
    private var didPromptAccessibility = false

    private init() {}

    /// Applies `action` to `targetApp`'s focused window (or the current frontmost app if nil).
    func perform(_ action: WindowAction, targetApp: NSRunningApplication? = nil) {
        let liveTarget = targetApp.flatMap { $0.isTerminated ? nil : $0 }
        guard let app = liveTarget ?? NSWorkspace.shared.frontmostApplication else {
            NSSound.beep()
            return
        }

        // Calling synchronous AX IPC on our own process from the main thread deadlocks until
        // axTimeout; snap Sukusho's own standard windows directly through AppKit instead.
        if app == NSRunningApplication.current {
            performOnOwnWindow(action)
            return
        }

        // Reuse Sukusho's Accessibility check and one-time prompt flow (same TCC permission as
        // clipboard paste and auto-scroll).
        guard AXIsProcessTrusted() else {
            if !didPromptAccessibility {
                didPromptAccessibility = true
                // kAXTrustedCheckOptionPrompt's value, spelled out: the imported constant is a mutable global.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            NSSound.beep()
            return
        }

        let screens = currentScreens()
        guard !screens.isEmpty else {
            NSSound.beep()
            return
        }

        let pid = app.processIdentifier
        axWorker.perform(action, pid: pid, screens: screens) { ok in
            if !ok {
                Task { @MainActor in NSSound.beep() }
            }
        }
    }

    // MARK: - Own windows (AppKit)

    private func performOnOwnWindow(_ action: WindowAction) {
        guard let window = movableOwnWindow() else {
            NSSound.beep()
            return
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(action, toOwnWindow: window)
            }
            return
        }
        apply(action, toOwnWindow: window)
    }

    private func apply(_ action: WindowAction, toOwnWindow window: NSWindow) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            NSSound.beep()
            return
        }
        let screens = currentScreens()
        let f = window.frame
        let current = ScreenBounds.fromAppKit(
            x: Double(f.origin.x), y: Double(f.origin.y),
            width: Double(f.width), height: Double(f.height),
            primaryHeight: Double(primaryHeight)
        )
        guard let target = WindowLayout.target(for: action, window: current, screens: screens) else {
            NSSound.beep()
            return
        }
        window.setFrame(target.frame.toAppKit(primaryHeight: Double(primaryHeight)), display: true, animate: false)
        let after = window.frame
        let actual = ScreenBounds.fromAppKit(
            x: Double(after.origin.x), y: Double(after.origin.y),
            width: Double(after.width), height: Double(after.height),
            primaryHeight: Double(primaryHeight)
        )
        let tol = 2.0
        if actual.maxX > target.visibleFrame.maxX + tol || actual.maxY > target.visibleFrame.maxY + tol {
            let pos = WindowLayout.clampedPosition(
                desired: target.frame, actualWidth: actual.width, actualHeight: actual.height,
                within: target.visibleFrame
            )
            let clamped = ScreenBounds(x: pos.x, y: pos.y, width: actual.width, height: actual.height)
            window.setFrameOrigin(clamped.toAppKit(primaryHeight: Double(primaryHeight)).origin)
        }
    }

    private func movableOwnWindow() -> NSWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        return candidates.first { window in
            window.isVisible && window.canBecomeMain && !(window is ClipboardPopupPanel)
        }
    }

    private func currentScreens() -> [DisplayScreen] {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return [] }
        return screens.map { s in
            let f = s.frame, v = s.visibleFrame
            return DisplayScreen.fromAppKit(
                frame: (Double(f.origin.x), Double(f.origin.y), Double(f.width), Double(f.height)),
                visibleFrame: (Double(v.origin.x), Double(v.origin.y), Double(v.width), Double(v.height)),
                primaryHeight: Double(primaryHeight)
            )
        }
    }
}

/// Runs external `AXUIElement` calls on a dedicated serial background queue so an unresponsive
/// foreground app never stalls Sukusho's main thread.
private nonisolated final class WindowAXWorker: @unchecked Sendable {
    private static let axTimeout: Float = 0.5
    private static let enhancedUIAttr = "AXEnhancedUserInterface" as CFString
    private static let fullScreenAttr = "AXFullScreen" as CFString

    private let queue = DispatchQueue(label: "com.tommyent.Sukusho.window-ax", qos: .userInteractive)

    func perform(
        _ action: WindowAction,
        pid: pid_t,
        screens: [DisplayScreen],
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)
            guard let window = self.focusedWindow(of: axApp) else {
                completion(false)
                return
            }
            AXUIElementSetMessagingTimeout(window, Self.axTimeout)

            if self.boolAttribute(Self.fullScreenAttr, on: window) == true {
                AXUIElementSetAttributeValue(window, Self.fullScreenAttr, kCFBooleanFalse)
                self.queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                    let ok = self.apply(action, to: window, in: axApp, screens: screens)
                    completion(ok)
                }
                return
            }

            let ok = self.apply(action, to: window, in: axApp, screens: screens)
            completion(ok)
        }
    }

    private func apply(
        _ action: WindowAction,
        to window: AXUIElement,
        in axApp: AXUIElement,
        screens: [DisplayScreen]
    ) -> Bool {
        guard let current = readFrame(of: window) else { return false }
        guard let target = WindowLayout.target(for: action, window: current, screens: screens) else {
            return false
        }

        // Chromium/Electron apps fight or animate AX frame writes when AXEnhancedUserInterface
        // is enabled; toggle it off for the move and restore it afterwards.
        let restoreEnhancedUI = disableEnhancedUIIfNeeded(on: axApp)

        let (sizeErr, posErr) = writeFrame(target.frame, to: window)
        if WindowAXPolicy.shouldAbort(sizeErr) || WindowAXPolicy.shouldAbort(posErr)
            || (sizeErr != .success && posErr != .success) {
            if restoreEnhancedUI { setEnhancedUI(true, on: axApp) }
            return false
        }
        settle(window: window, target: target)

        if target.crossDisplay {
            queue.asyncAfter(deadline: .now() + .milliseconds(25)) {
                _ = self.writeFrame(target.frame, to: window)
                self.settle(window: window, target: target)
                if restoreEnhancedUI { self.setEnhancedUI(true, on: axApp) }
            }
        } else if restoreEnhancedUI {
            setEnhancedUI(true, on: axApp)
        }
        return true
    }

    private func settle(window: AXUIElement, target: WindowLayout.Target) {
        guard let actual = readFrame(of: window) else { return }
        let tol = 2.0
        let needsRetry = abs(actual.x - target.frame.x) > tol
            || abs(actual.y - target.frame.y) > tol
            || abs(actual.width - target.frame.width) > tol
            || abs(actual.height - target.frame.height) > tol
        guard needsRetry else { return }

        let clamped = WindowLayout.clampedPosition(
            desired: target.frame, actualWidth: actual.width, actualHeight: actual.height,
            within: target.visibleFrame
        )
        var retry = target.frame
        retry.x = clamped.x
        retry.y = clamped.y
        let (sizeErr, posErr) = writeFrame(retry, to: window)
        if WindowAXPolicy.shouldAbort(sizeErr) || WindowAXPolicy.shouldAbort(posErr) { return }

        if let final = readFrame(of: window),
           final.maxX > target.visibleFrame.maxX + tol || final.maxY > target.visibleFrame.maxY + tol {
            let pos = WindowLayout.clampedPosition(
                desired: target.frame, actualWidth: final.width, actualHeight: final.height,
                within: target.visibleFrame
            )
            _ = writePosition(x: pos.x, y: pos.y, to: window)
        }
    }

    // MARK: - AX helpers

    private func disableEnhancedUIIfNeeded(on axApp: AXUIElement) -> Bool {
        guard boolAttribute(Self.enhancedUIAttr, on: axApp) == true else { return false }
        setEnhancedUI(false, on: axApp)
        return true
    }

    private func setEnhancedUI(_ enabled: Bool, on axApp: AXUIElement) {
        AXUIElementSetAttributeValue(axApp, Self.enhancedUIAttr, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func boolAttribute(_ attr: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &value)
        if WindowAXPolicy.shouldAbort(err) { return nil }
        guard err == .success, let num = value as? NSNumber else { return false }
        return num.boolValue
    }

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, attr, &value)
            if err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
            // Return immediately on messaging timeout or dead/disabled target instead of stacking another timeout.
            if WindowAXPolicy.shouldAbort(err) { return nil }
        }
        return nil
    }

    private func readFrame(of window: AXUIElement) -> ScreenBounds? {
        var posRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        guard posErr == .success, let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() else { return nil }

        var sizeRef: CFTypeRef?
        let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard sizeErr == .success, let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        let posVal = posRef as! AXValue
        let sizeVal = sizeRef as! AXValue
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &pt),
              AXValueGetValue(sizeVal, .cgSize, &sz) else { return nil }
        return ScreenBounds(x: Double(pt.x), y: Double(pt.y), width: Double(sz.width), height: Double(sz.height))
    }

    private func writeFrame(_ frame: ScreenBounds, to window: AXUIElement) -> (sizeErr: AXError, posErr: AXError) {
        var sz = CGSize(width: frame.width, height: frame.height)
        let sizeErr: AXError = AXValueCreate(.cgSize, &sz).map {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, $0)
        } ?? .failure
        if WindowAXPolicy.shouldAbort(sizeErr) {
            return (sizeErr, sizeErr)
        }
        let posErr = writePosition(x: frame.x, y: frame.y, to: window)
        return (sizeErr, posErr)
    }

    private func writePosition(x: Double, y: Double, to window: AXUIElement) -> AXError {
        var pt = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &pt).map {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, $0)
        } ?? .failure
    }
}
