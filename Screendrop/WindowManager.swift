import AppKit
import ApplicationServices

/// Moves and resizes the frontmost app's focused window via macOS Accessibility (`AXUIElement`),
/// ported from Unleash. Prompts for Accessibility permission only on first use, never at launch.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private static let axTimeout: Float = 0.5
    private static let enhancedUIAttr = "AXEnhancedUserInterface" as CFString
    private static let fullScreenAttr = "AXFullScreen" as CFString

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

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)
        guard let window = focusedWindow(of: axApp) else {
            NSSound.beep()
            return
        }
        AXUIElementSetMessagingTimeout(window, Self.axTimeout)

        // Leave full screen first if the window is currently full screen.
        if boolAttribute(Self.fullScreenAttr, on: window) {
            AXUIElementSetAttributeValue(window, Self.fullScreenAttr, kCFBooleanFalse)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                self?.apply(action, to: window, in: axApp)
            }
            return
        }

        apply(action, to: window, in: axApp)
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

    // MARK: - Other apps (AXUIElement)

    private func apply(_ action: WindowAction, to window: AXUIElement, in axApp: AXUIElement) {
        guard let current = readFrame(of: window) else {
            NSSound.beep()
            return
        }
        let screens = currentScreens()
        guard let target = WindowLayout.target(for: action, window: current, screens: screens) else {
            NSSound.beep()
            return
        }

        // Chromium/Electron apps fight or animate AX frame writes when AXEnhancedUserInterface
        // is enabled; toggle it off for the move and restore it afterwards.
        let restoreEnhancedUI = disableEnhancedUIIfNeeded(on: axApp)

        // Size first, then position, then read back and retry once (with best-effort clamp
        // when the app refuses a smaller size).
        let (sizeOK, posOK) = writeFrame(target.frame, to: window)
        if !sizeOK && !posOK {
            if restoreEnhancedUI { setEnhancedUI(true, on: axApp) }
            NSSound.beep()
            return
        }
        settle(window: window, target: target)

        // Cross-display moves can apply size late on macOS; re-apply after ~25 ms.
        if target.crossDisplay {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                guard let self else { return }
                _ = self.writeFrame(target.frame, to: window)
                self.settle(window: window, target: target)
                if restoreEnhancedUI { self.setEnhancedUI(true, on: axApp) }
            }
        } else if restoreEnhancedUI {
            setEnhancedUI(true, on: axApp)
        }
    }

    private func settle(window: AXUIElement, target: WindowLayout.Target) {
        guard let actual = readFrame(of: window) else { return }
        let tol = 2.0
        let needsRetry = abs(actual.x - target.frame.x) > tol
            || abs(actual.y - target.frame.y) > tol
            || abs(actual.width - target.frame.width) > tol
            || abs(actual.height - target.frame.height) > tol
        guard needsRetry else { return }

        // Retry size + best-effort clamped position once.
        let clamped = WindowLayout.clampedPosition(
            desired: target.frame, actualWidth: actual.width, actualHeight: actual.height,
            within: target.visibleFrame
        )
        var retry = target.frame
        retry.x = clamped.x
        retry.y = clamped.y
        _ = writeFrame(retry, to: window)

        // If the app still clamped its size, pull the position back inside visibleFrame.
        if let final = readFrame(of: window),
           final.maxX > target.visibleFrame.maxX + tol || final.maxY > target.visibleFrame.maxY + tol {
            let pos = WindowLayout.clampedPosition(
                desired: target.frame, actualWidth: final.width, actualHeight: final.height,
                within: target.visibleFrame
            )
            _ = writePosition(x: pos.x, y: pos.y, to: window)
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

    // MARK: - AX helpers

    private func disableEnhancedUIIfNeeded(on axApp: AXUIElement) -> Bool {
        guard boolAttribute(Self.enhancedUIAttr, on: axApp) else { return false }
        setEnhancedUI(false, on: axApp)
        return true
    }

    private func setEnhancedUI(_ enabled: Bool, on axApp: AXUIElement) {
        AXUIElementSetAttributeValue(axApp, Self.enhancedUIAttr, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func boolAttribute(_ attr: CFString, on element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let num = value as? NSNumber else { return false }
        return num.boolValue
    }

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr, &value) == .success, let value {
                if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    return (value as! AXUIElement)
                }
            }
        }
        return nil
    }

    private func readFrame(of window: AXUIElement) -> ScreenBounds? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        let posVal = posRef as! AXValue
        let sizeVal = sizeRef as! AXValue
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &pt),
              AXValueGetValue(sizeVal, .cgSize, &sz) else { return nil }
        return ScreenBounds(x: Double(pt.x), y: Double(pt.y), width: Double(sz.width), height: Double(sz.height))
    }

    @discardableResult
    private func writeFrame(_ frame: ScreenBounds, to window: AXUIElement) -> (sizeOK: Bool, posOK: Bool) {
        var sz = CGSize(width: frame.width, height: frame.height)
        let sizeOK = AXValueCreate(.cgSize, &sz).map {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, $0) == .success
        } ?? false
        let posOK = writePosition(x: frame.x, y: frame.y, to: window)
        return (sizeOK, posOK)
    }

    @discardableResult
    private func writePosition(x: Double, y: Double, to window: AXUIElement) -> Bool {
        var pt = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &pt).map {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, $0) == .success
        } ?? false
    }
}
