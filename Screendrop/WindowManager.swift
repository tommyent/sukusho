import AppKit
import ApplicationServices
import os
import OSLog

/// Shared macOS Accessibility check and explicit-action recovery flow (reused by window management
/// and auto-scroll): never prompts at launch; first explicit use asks macOS to prompt, repeat
/// explicit use opens Privacy & Security › Accessibility.
@MainActor
enum AccessibilityPermission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let windowGuidance = "Allow Sukusho in Accessibility to move windows."
    private static var hasPrompted = false

    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Checks Accessibility on an explicit user action. Returns `true` if granted; otherwise triggers
    /// macOS's prompt once and opens Privacy & Security › Accessibility on subsequent explicit attempts.
    @discardableResult
    static func ensureGrantedOnUserAction() -> Bool {
        switch AccessibilityPermissionFlow.decide(isTrusted: AXIsProcessTrusted(), hasPromptedBefore: hasPrompted) {
        case .granted:
            return true
        case .promptSystem:
            hasPrompted = true
            // kAXTrustedCheckOptionPrompt's value, spelled out: the imported constant is a mutable global.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return false
        case .openSettings:
            openSettings()
            return false
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

/// Weak reference to an AppKit window captured before the clipboard popup becomes key.
@MainActor
final class WeakWindowBox {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}

/// Sendable wrapper for an immutable `AXUIElement` handle captured off-main before opening Apps.
nonisolated final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// Snapshot of the exact window that was frontmost before the Apps popup opened.
@MainActor
enum CapturedWindowTarget {
    case own(WeakWindowBox)
    case external(app: NSRunningApplication, axApp: AXElementBox, window: AXElementBox)
    case externalNeedsAccessibility(NSRunningApplication)
    case unavailable
}

/// Moves and resizes the frontmost app's focused window via macOS Accessibility (`AXUIElement`),
/// ported from Unleash. Prompts for Accessibility permission only on first use, never at launch.
/// All external `AXUIElement` IPC runs on a serial background queue so a hung app can never freeze Sukusho.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let gate = WindowOperationGate()
    private lazy var axWorker = WindowAXWorker(gate: gate)
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

    /// Captures the exact window that is active BEFORE the clipboard popup becomes key.
    /// External AX lookup runs off-main with a bounded timeout so it finishes before `makeKeyAndOrderFront`
    /// without stalling the main thread behind a hung app or behind an in-flight move.
    func captureTargetBeforePopup(for front: NSRunningApplication?) async -> CapturedWindowTarget {
        guard let front else { return .unavailable }
        if front == NSRunningApplication.current {
            guard let window = ownActiveWindow() else { return .unavailable }
            return .own(WeakWindowBox(window))
        }
        guard AXIsProcessTrusted() else {
            return .externalNeedsAccessibility(front)
        }
        let pid = front.processIdentifier
        guard let captured = await WindowAXWorker.captureFocusedWindowBounded(pid: pid, timeout: 0.25) else {
            return .unavailable
        }
        return .external(app: front, axApp: captured.app, window: captured.window)
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

        guard AccessibilityPermission.ensureGrantedOnUserAction() else {
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
    /// `confirmClose` runs on `@MainActor` and returns `true` only if it closed the originating popup
    /// session; placement starts only after that acknowledgement, and stale callbacks never touch a newer popup.
    func perform(
        _ action: WindowAction,
        on captured: CapturedWindowTarget,
        confirmClose: @escaping @MainActor () -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        switch captured {
        case .own(let box):
            switch WindowTargetState<NSWindow, Int>.own(box.window).resolve(ownIsVisible: { $0.isVisible }) {
            case .moveOwn(let window):
                guard confirmClose() else { return }
                let token = gate.begin()
                perform(action, onOwnWindow: window, token: token)
            case .gone(let message):
                onFailure(message)
            case .moveExternal, .needsAccessibility, .reopenAfterGrant:
                break
            }

        case .unavailable:
            onFailure(WindowTargetState<Int, Int>.unavailableMessage)

        case .externalNeedsAccessibility(let app):
            if app.isTerminated {
                onFailure(WindowTargetState<Int, Int>.goneMessage)
                return
            }
            // No fresh-lookup fallback: if Accessibility was missing when Apps opened, no window
            // handle was captured for this session. After granting permission, ask the user to reopen Apps.
            let granted = AccessibilityPermission.ensureGrantedOnUserAction()
            switch WindowTargetState<Int, Int>.externalNeedsAccessibility(isTrustedNow: granted).resolve(ownIsVisible: { _ in false }) {
            case .needsAccessibility:
                onFailure(AccessibilityPermission.windowGuidance)
            case .reopenAfterGrant(let message):
                onFailure(message)
            case .moveOwn, .moveExternal, .gone:
                break
            }

        case .external(let app, let axApp, let window):
            guard !app.isTerminated else {
                onFailure(WindowTargetState<Int, Int>.goneMessage)
                return
            }
            guard AccessibilityPermission.ensureGrantedOnUserAction() else {
                onFailure(AccessibilityPermission.windowGuidance)
                return
            }
            let screens = currentScreens()
            guard !screens.isEmpty else {
                onFailure("Couldn’t read display layout.")
                return
            }
            let token = gate.begin()
            let gate = self.gate
            axWorker.performCaptured(
                action,
                axApp: axApp,
                window: window,
                screens: screens,
                token: token,
                confirmCloseOnMain: {
                    // Called from the serial AX background queue; main actor never waits on the AX queue.
                    // The handshake checks `token` on main before closing and expires if the wait times out.
                    let handshake = WindowCloseHandshake(token: token, gate: gate)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = handshake.deliverOnMain(closePopup: confirmClose)
                        }
                    }
                    return handshake.wait(timeout: 2.0)
                },
                completion: { outcome in
                    Task { @MainActor in
                        switch outcome {
                        case .moved, .cancelled, .sessionEnded:
                            break
                        case .gone:
                            onFailure(WindowTargetState<Int, Int>.goneMessage)
                        case .failed:
                            NSSound.beep()
                        }
                    }
                }
            )
        }
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
                    self.apply(action, toOwnWindow: window, token: token)
                }
            }
            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.clearPendingOwnFullScreenObserver() }
            }
            fullScreenExitTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
            guard gate.isCurrent(token) else {
                clearPendingOwnFullScreenObserver()
                return
            }
            window.toggleFullScreen(nil)
            return
        }
        apply(action, toOwnWindow: window, token: token)
    }

    private func apply(_ action: WindowAction, toOwnWindow window: NSWindow, token: UInt64) {
        guard gate.isCurrent(token), let primaryHeight = NSScreen.screens.first?.frame.height else {
            if gate.isCurrent(token) { NSSound.beep() }
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
        guard gate.isCurrent(token) else { return }
        window.setFrame(target.frame.toAppKit(primaryHeight: Double(primaryHeight)), display: true, animate: false)
        let after = window.frame
        let actual = ScreenBounds.fromAppKit(
            x: Double(after.origin.x), y: Double(after.origin.y),
            width: Double(after.width), height: Double(after.height),
            primaryHeight: Double(primaryHeight)
        )
        guard gate.isCurrent(token) else { return }
        if let pos = WindowLayout.finalOriginCorrection(actual: actual, target: target) {
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
    private static let axTimeout: Float = 0.5
    private static let enhancedUIAttr = "AXEnhancedUserInterface" as CFString
    private static let fullScreenAttr = "AXFullScreen" as CFString

    private let gate: WindowOperationGate
    private let queue = DispatchQueue(label: "com.tommyent.Sukusho.window-ax", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.tommyent.Sukusho", category: "WindowManager")

    init(gate: WindowOperationGate) {
        self.gate = gate
    }

    /// Runs a bounded off-main focused-window lookup on a dedicated lookup queue so opening the Apps
    /// popup finishes capturing the target window before becoming key and never queues behind a slow move.
    static func captureFocusedWindowBounded(
        pid: pid_t,
        timeout: TimeInterval
    ) async -> (app: AXElementBox, window: AXElementBox)? {
        await withCheckedContinuation { continuation in
            let settled = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: (app: AXElementBox, window: AXElementBox)?) {
                let shouldResume = settled.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume { continuation.resume(returning: result) }
            }

            DispatchQueue.global(qos: .userInteractive).async {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, Float(timeout))
                guard let window = Self.lookupFocusedWindow(of: axApp) else {
                    finish(nil)
                    return
                }
                AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)
                AXUIElementSetMessagingTimeout(window, Self.axTimeout)
                finish((AXElementBox(axApp), AXElementBox(window)))
            }

            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
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
            guard let window = Self.lookupFocusedWindow(of: axApp) else {
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
        axApp: AXElementBox,
        window: AXElementBox,
        screens: [DisplayScreen],
        token: UInt64,
        confirmCloseOnMain: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WindowCapturedExecution.Outcome) -> Void
    ) {
        queue.async {
            let outcome = WindowCapturedExecution.run(
                isCurrent: { self.gate.isCurrent(token) },
                validateWindow: { self.readFrame(of: window.element) != nil },
                confirmCloseOriginatingPopup: confirmCloseOnMain,
                place: {
                    self.performSerialized(action, window: window.element, in: axApp.element, screens: screens, token: token)
                }
            )
            completion(outcome)
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
        guard gate.isCurrent(token), let isFullScreen = boolAttribute(Self.fullScreenAttr, on: window) else { return false }
        if isFullScreen {
            let exitOutcome = WindowFullScreenExit.exitAndConfirm(
                maxPolls: 40,
                shouldContinue: { self.gate.isCurrent(token) },
                requestExit: {
                    AXUIElementSetAttributeValue(window, Self.fullScreenAttr, kCFBooleanFalse)
                },
                pollFullScreen: {
                    self.pollFullScreen(on: window)
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
        guard gate.isCurrent(token), let current = readFrame(of: window) else { return false }
        guard gate.isCurrent(token), let target = WindowLayout.target(for: action, window: current, screens: screens) else {
            return false
        }

        // Chromium/Electron apps fight or animate AX frame writes when AXEnhancedUserInterface
        // is enabled; toggle it off only when the write succeeds and always restore it before
        // releasing the serial queue (even if the token became stale mid-move).
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

        guard gate.isCurrent(token) else { return false }
        let (sizeErr, posErr) = writeFrame(target.frame, to: window, token: token)
        if !gate.isCurrent(token)
            || WindowAXPolicy.shouldAbort(sizeErr) || WindowAXPolicy.shouldAbort(posErr)
            || (sizeErr != .success && posErr != .success) {
            return false
        }
        settle(window: window, target: target, token: token)

        // Cross-display moves can apply size late on macOS; wait inside this serialized operation
        // so a superseding command or disable wakes immediately and never races with our retry.
        if target.crossDisplay {
            guard gate.wait(token: token, duration: 0.025) else { return false }
            let (retrySizeErr, retryPosErr) = writeFrame(target.frame, to: window, token: token)
            if gate.isCurrent(token),
               !WindowAXPolicy.shouldAbort(retrySizeErr), !WindowAXPolicy.shouldAbort(retryPosErr) {
                settle(window: window, target: target, token: token)
            }
        }
        return restoreIfNeeded()
    }

    private func settle(window: AXUIElement, target: WindowLayout.Target, token: UInt64) {
        WindowLayout.settle(
            target: target,
            shouldContinue: { self.gate.isCurrent(token) },
            readFrame: { self.readFrame(of: window) },
            writeFrame: { frame in
                let (sizeErr, posErr) = self.writeFrame(frame, to: window, token: token)
                return self.gate.isCurrent(token)
                    && !WindowAXPolicy.shouldAbort(sizeErr)
                    && !WindowAXPolicy.shouldAbort(posErr)
            },
            writePosition: { x, y in
                _ = self.writePosition(x: x, y: y, to: window, token: token)
            }
        )
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

    /// Strict poll for `AXFullScreen` exit: only `.success` with Boolean `false` confirms exit.
    private func pollFullScreen(on window: AXUIElement) -> WindowFullScreenPoll {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window, Self.fullScreenAttr, &value)
        let boolValue = (err == .success) ? (value as? NSNumber)?.boolValue : nil
        return WindowFullScreenPoll.from(error: err, boolValue: boolValue)
    }

    private static func lookupFocusedWindow(of app: AXUIElement) -> AXUIElement? {
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

    private func writeFrame(_ frame: ScreenBounds, to window: AXUIElement, token: UInt64) -> (sizeErr: AXError, posErr: AXError) {
        guard gate.isCurrent(token) else { return (.failure, .failure) }
        var sz = CGSize(width: frame.width, height: frame.height)
        let sizeErr: AXError = AXValueCreate(.cgSize, &sz).map {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, $0)
        } ?? .failure
        if WindowAXPolicy.shouldAbort(sizeErr) {
            return (sizeErr, sizeErr)
        }
        let posErr = writePosition(x: frame.x, y: frame.y, to: window, token: token)
        return (sizeErr, posErr)
    }

    private func writePosition(x: Double, y: Double, to window: AXUIElement, token: UInt64) -> AXError {
        guard gate.isCurrent(token) else { return .failure }
        var pt = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &pt).map {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, $0)
        } ?? .failure
    }
}
