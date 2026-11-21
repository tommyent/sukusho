import AppKit
import ApplicationServices
import OSLog

/// Weak reference to an AppKit window captured before the clipboard popup becomes key.
@MainActor
final class WeakWindowBox {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}

/// Snapshot of the exact window that was frontmost before the Apps popup opened.
@MainActor
enum CapturedWindowTarget {
    case own(WeakWindowBox)
    case external(app: NSRunningApplication, captureID: UInt64)
    case externalNeedsAccessibility(NSRunningApplication)
    case unavailable

    var captureID: UInt64? {
        if case .external(_, let id) = self { return id }
        return nil
    }
}

/// Moves and resizes the frontmost app's focused window via macOS Accessibility (`AXUIElement`),
/// ported from Unleash. Prompts for Accessibility permission only on first use, never at launch.
/// All external `AXUIElement` IPC runs on a serial background queue so a hung app can never freeze Sukusho.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let gate = WindowOperationGate()
    private lazy var axWorker = WindowAXWorker(gate: gate)
    private var nextCaptureID: UInt64 = 0
    private var didPromptAccessibility = false
    private var fullScreenExitObserver: NSObjectProtocol?
    private var fullScreenExitTimeout: DispatchWorkItem?

    private init() {}

    /// Cancels any pending window move (full-screen exit wait or cross-display settle), e.g. when
    /// the user turns Window Management off. Any already-disabled `AXEnhancedUserInterface` is still restored.
    func cancelPending() {
        gate.cancelAll()
        clearPendingOwnFullScreenObserver()
    }

    private func clearPendingOwnFullScreenObserver() {
        if let observer = fullScreenExitObserver {
            NotificationCenter.default.removeObserver(observer)
            fullScreenExitObserver = nil
        }
        fullScreenExitTimeout?.cancel()
        fullScreenExitTimeout = nil
    }

    // MARK: - Capturing a target before opening the popup

    /// Captures the actual window that is active right before the clipboard popup becomes key.
    /// External AX lookup runs asynchronously on the serial AX queue so opening the popup never blocks.
    func captureTargetBeforePopup() -> CapturedWindowTarget {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return .unavailable
        }
        if front == NSRunningApplication.current {
            guard let window = ownActiveWindow() else { return .unavailable }
            return .own(WeakWindowBox(window))
        }
        guard AXIsProcessTrusted() else {
            return .externalNeedsAccessibility(front)
        }
        nextCaptureID &+= 1
        let captureID = nextCaptureID
        axWorker.captureFocusedWindow(pid: front.processIdentifier, captureID: captureID)
        return .external(app: front, captureID: captureID)
    }

    func releaseCapturedTarget(_ target: CapturedWindowTarget?) {
        if let captureID = target?.captureID {
            axWorker.clearCapturedWindow(captureID: captureID)
        }
    }

    // MARK: - Performing actions

    /// Global shortcut path: resolves the live frontmost app and its focused window.
    func perform(_ action: WindowAction) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            NSSound.beep()
            return
        }

        clearPendingOwnFullScreenObserver()
        let token = gate.begin()
        if app == NSRunningApplication.current {
            guard let window = ownActiveWindow() else {
                NSSound.beep()
                return
            }
            perform(action, onOwnWindow: window, token: token)
            return
        }

        guard AXIsProcessTrusted() else {
            promptAccessibilityOnce()
            NSSound.beep()
            return
        }

        let screens = currentScreens()
        guard !screens.isEmpty else {
            NSSound.beep()
            return
        }

        let pid = app.processIdentifier
        axWorker.performFrontmost(action, pid: pid, screens: screens, token: token) { ok in
            if !ok {
                Task { @MainActor in NSSound.beep() }
            }
        }
    }

    /// Apps command path: moves only the exact window captured before the popup opened.
    /// Never falls back to another app or window if the captured target disappeared.
    func perform(
        _ action: WindowAction,
        on captured: CapturedWindowTarget,
        onWillMove: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        switch captured {
        case .own(let box):
            switch WindowTargetState<NSWindow, Int>.own(box.window).resolve(ownIsVisible: { $0.isVisible }) {
            case .moveOwn(let window):
                let token = gate.begin()
                onWillMove()
                perform(action, onOwnWindow: window, token: token)
            case .gone(let message):
                NSSound.beep()
                onFailure(message)
            case .moveExternal, .needsAccessibility:
                break
            }

        case .unavailable:
            NSSound.beep()
            onFailure(WindowTargetState<Int, Int>.unavailableMessage)

        case .externalNeedsAccessibility(let app):
            if app.isTerminated {
                NSSound.beep()
                onFailure(WindowTargetState<Int, Int>.goneMessage)
                return
            }
            guard AXIsProcessTrusted() else {
                promptAccessibilityOnce()
                NSSound.beep()
                onFailure("Allow Sukusho in Accessibility to move windows.")
                return
            }
            // Permission was granted while the popup was open; capture wasn't possible earlier.
            let screens = currentScreens()
            guard !screens.isEmpty else {
                NSSound.beep()
                onFailure("Couldn’t read display layout.")
                return
            }
            let token = gate.begin()
            onWillMove()
            axWorker.performFrontmost(action, pid: app.processIdentifier, screens: screens, token: token) { ok in
                if !ok {
                    Task { @MainActor in NSSound.beep() }
                }
            }

        case .external(let app, let captureID):
            guard !app.isTerminated else {
                axWorker.clearCapturedWindow(captureID: captureID)
                NSSound.beep()
                onFailure(WindowTargetState<Int, Int>.goneMessage)
                return
            }
            guard AXIsProcessTrusted() else {
                promptAccessibilityOnce()
                NSSound.beep()
                onFailure("Allow Sukusho in Accessibility to move windows.")
                return
            }
            let screens = currentScreens()
            guard !screens.isEmpty else {
                NSSound.beep()
                onFailure("Couldn’t read display layout.")
                return
            }
            let token = gate.begin()
            axWorker.performCaptured(
                action,
                captureID: captureID,
                screens: screens,
                token: token,
                onValidated: {
                    Task { @MainActor in onWillMove() }
                },
                completion: { outcome in
                    Task { @MainActor in
                        switch outcome {
                        case .moved, .cancelled:
                            break
                        case .gone:
                            NSSound.beep()
                            onFailure(WindowTargetState<Int, Int>.goneMessage)
                        case .failed:
                            NSSound.beep()
                        }
                    }
                }
            )
        }
    }

    private func promptAccessibilityOnce() {
        guard !didPromptAccessibility else { return }
        didPromptAccessibility = true
        // kAXTrustedCheckOptionPrompt's value, spelled out: the imported constant is a mutable global.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Own windows (AppKit)

    private func perform(_ action: WindowAction, onOwnWindow window: NSWindow, token: UInt64) {
        clearPendingOwnFullScreenObserver()
        if window.styleMask.contains(.fullScreen) {
            fullScreenExitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearPendingOwnFullScreenObserver()
                    guard self.gate.isCurrent(token), let window, window.isVisible,
                          !window.styleMask.contains(.fullScreen) else { return }
                    self.apply(action, toOwnWindow: window)
                }
            }
            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.clearPendingOwnFullScreenObserver() }
            }
            fullScreenExitTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
            window.toggleFullScreen(nil)
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

    private func ownActiveWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
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
    enum CapturedOutcome: Sendable {
        case moved
        case cancelled
        case gone
        case failed
    }

    private struct CapturedAX {
        let captureID: UInt64
        let app: AXUIElement
        let window: AXUIElement
    }

    private static let axTimeout: Float = 0.5
    private static let enhancedUIAttr = "AXEnhancedUserInterface" as CFString
    private static let fullScreenAttr = "AXFullScreen" as CFString

    private let gate: WindowOperationGate
    private let queue = DispatchQueue(label: "com.tommyent.Sukusho.window-ax", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "WindowManager")
    private var captured: CapturedAX?

    init(gate: WindowOperationGate) {
        self.gate = gate
    }

    func captureFocusedWindow(pid: pid_t, captureID: UInt64) {
        queue.async {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)
            guard let window = self.focusedWindow(of: axApp) else {
                if self.captured?.captureID != captureID { self.captured = nil }
                return
            }
            AXUIElementSetMessagingTimeout(window, Self.axTimeout)
            self.captured = CapturedAX(captureID: captureID, app: axApp, window: window)
        }
    }

    func clearCapturedWindow(captureID: UInt64) {
        queue.async {
            if self.captured?.captureID == captureID {
                self.captured = nil
            }
        }
    }

    func performFrontmost(
        _ action: WindowAction,
        pid: pid_t,
        screens: [DisplayScreen],
        token: UInt64,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async {
            guard self.gate.isCurrent(token) else { return }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)
            guard let window = self.focusedWindow(of: axApp) else {
                completion(false)
                return
            }
            AXUIElementSetMessagingTimeout(window, Self.axTimeout)
            let ok = self.performSerialized(action, window: window, in: axApp, screens: screens, token: token)
            if self.gate.isCurrent(token) {
                completion(ok)
            }
        }
    }

    func performCaptured(
        _ action: WindowAction,
        captureID: UInt64,
        screens: [DisplayScreen],
        token: UInt64,
        onValidated: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (CapturedOutcome) -> Void
    ) {
        queue.async {
            guard self.gate.isCurrent(token) else {
                completion(.cancelled)
                return
            }
            guard let entry = self.captured, entry.captureID == captureID else {
                completion(.gone)
                return
            }
            guard self.readFrame(of: entry.window) != nil else {
                self.captured = nil
                completion(.gone)
                return
            }
            self.captured = nil
            onValidated()
            let ok = self.performSerialized(action, window: entry.window, in: entry.app, screens: screens, token: token)
            if !self.gate.isCurrent(token) {
                completion(.cancelled)
            } else {
                completion(ok ? .moved : .failed)
            }
        }
    }

    /// Runs full-screen exit, placement, cross-display settle, and `AXEnhancedUserInterface` restoration
    /// inside a single serialized queue step so a newer command or disable cancels retries cleanly
    /// while still restoring `AXEnhancedUserInterface` if this command disabled it.
    private func performSerialized(
        _ action: WindowAction,
        window: AXUIElement,
        in axApp: AXUIElement,
        screens: [DisplayScreen],
        token: UInt64
    ) -> Bool {
        guard let isFullScreen = boolAttribute(Self.fullScreenAttr, on: window) else { return false }
        if isFullScreen {
            let exitOutcome = WindowFullScreenExit.exitAndConfirm(
                maxPolls: 40,
                requestExit: {
                    AXUIElementSetAttributeValue(window, Self.fullScreenAttr, kCFBooleanFalse)
                },
                readIsFullScreen: {
                    self.boolAttribute(Self.fullScreenAttr, on: window)
                },
                waitStep: {
                    self.gate.wait(token: token, duration: 0.05)
                }
            )
            guard exitOutcome == .exited else { return false }
        }
        guard gate.isCurrent(token) else { return false }
        return apply(action, to: window, in: axApp, screens: screens, token: token)
    }

    private func apply(
        _ action: WindowAction,
        to window: AXUIElement,
        in axApp: AXUIElement,
        screens: [DisplayScreen],
        token: UInt64
    ) -> Bool {
        guard let current = readFrame(of: window) else { return false }
        guard let target = WindowLayout.target(for: action, window: current, screens: screens) else {
            return false
        }

        // Chromium/Electron apps fight or animate AX frame writes when AXEnhancedUserInterface
        // is enabled; toggle it off only when the write succeeds and always restore it before
        // releasing the serial queue (even if a newer command or disable cancels a delayed retry).
        let restoreEnhancedUI = disableEnhancedUIIfNeeded(on: axApp)
        var restored = !restoreEnhancedUI
        func restoreIfNeeded() -> Bool {
            guard !restored else { return true }
            restored = true
            let err = setEnhancedUI(true, on: axApp)
            if err != .success {
                logger.error("Failed to restore AXEnhancedUserInterface (AXError \(err.rawValue))")
                return false
            }
            return true
        }
        defer { _ = restoreIfNeeded() }

        let (sizeErr, posErr) = writeFrame(target.frame, to: window)
        if WindowAXPolicy.shouldAbort(sizeErr) || WindowAXPolicy.shouldAbort(posErr)
            || (sizeErr != .success && posErr != .success) {
            return false
        }
        settle(window: window, target: target)

        // Cross-display moves can apply size late on macOS; wait inside this serialized operation
        // so a superseding command or disable wakes immediately and never races with our retry.
        if target.crossDisplay {
            guard gate.wait(token: token, duration: 0.025) else { return false }
            let (retrySizeErr, retryPosErr) = writeFrame(target.frame, to: window)
            if !WindowAXPolicy.shouldAbort(retrySizeErr) && !WindowAXPolicy.shouldAbort(retryPosErr) {
                settle(window: window, target: target)
            }
        }
        return restoreIfNeeded()
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
        return setEnhancedUI(false, on: axApp) == .success
    }

    @discardableResult
    private func setEnhancedUI(_ enabled: Bool, on axApp: AXUIElement) -> AXError {
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
