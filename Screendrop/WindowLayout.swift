import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// A rectangle in screen coordinates. Unless named `*AppKit`, coordinates are in macOS
/// Accessibility / CoreGraphics space: origin at the primary display's top-left, Y growing down.
nonisolated struct ScreenBounds: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    /// Converts an AppKit rectangle (origin at primary display bottom-left, Y growing up) into
    /// Accessibility / CoreGraphics coordinates using the primary display's height.
    static func fromAppKit(
        x: Double, y: Double, width: Double, height: Double,
        primaryHeight: Double
    ) -> ScreenBounds {
        ScreenBounds(x: x, y: primaryHeight - (y + height), width: width, height: height)
    }

    /// Converts this Accessibility / CoreGraphics rectangle back into AppKit coordinates.
    func toAppKit(primaryHeight: Double) -> CGRect {
        CGRect(x: x, y: primaryHeight - (y + height), width: width, height: height)
    }

    func intersectionArea(with other: ScreenBounds) -> Double {
        let w = min(maxX, other.maxX) - max(minX, other.minX)
        let h = min(maxY, other.maxY) - max(minY, other.minY)
        return (w > 0 && h > 0) ? w * h : 0
    }
}

/// One display's full frame and usable visible frame (excluding menu bar and Dock), in AX coords.
nonisolated struct DisplayScreen: Equatable, Sendable {
    var frame: ScreenBounds
    var visibleFrame: ScreenBounds

    init(frame: ScreenBounds, visibleFrame: ScreenBounds) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    static func fromAppKit(
        frame: (x: Double, y: Double, width: Double, height: Double),
        visibleFrame: (x: Double, y: Double, width: Double, height: Double),
        primaryHeight: Double
    ) -> DisplayScreen {
        DisplayScreen(
            frame: .fromAppKit(x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                               primaryHeight: primaryHeight),
            visibleFrame: .fromAppKit(x: visibleFrame.x, y: visibleFrame.y, width: visibleFrame.width,
                                      height: visibleFrame.height, primaryHeight: primaryHeight)
        )
    }
}

/// Supported window management actions (halves, quarters, maximize, center, next display).
nonisolated enum WindowAction: String, CaseIterable, Hashable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
    case center
    case nextDisplay

    var itemID: String { "window.\(rawValue)" }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .maximize: "Maximize"
        case .center: "Center"
        case .nextDisplay: "Next Display"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .leftHalf: "⌃⌥⌘←"
        case .rightHalf: "⌃⌥⌘→"
        case .topHalf: "⌃⌥⌘↑"
        case .bottomHalf: "⌃⌥⌘↓"
        case .topLeft: "⌃⌥⇧←"
        case .topRight: "⌃⌥⇧↑"
        case .bottomLeft: "⌃⌥⇧↓"
        case .bottomRight: "⌃⌥⇧→"
        case .maximize: "⌃⌥⌘M"
        case .center: "⌃⌥⌘C"
        case .nextDisplay: "⌃⌥⌘N"
        }
    }

    var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay: "display.2"
        }
    }
}

extension WindowAction {
    /// Carbon shortcut matching Unleash's 11 window management bindings.
    var hotkeyShortcut: HotkeyShortcut {
        let halfMods: HotkeyShortcut.Modifiers = [.control, .option, .command]
        let quarterMods: HotkeyShortcut.Modifiers = [.control, .option, .shift]
        switch self {
        case .leftHalf: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_LeftArrow))
        case .rightHalf: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_RightArrow))
        case .topHalf: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_UpArrow))
        case .bottomHalf: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_DownArrow))
        case .topLeft: return HotkeyShortcut(modifiers: quarterMods, keyCode: Int(kVK_LeftArrow))
        case .topRight: return HotkeyShortcut(modifiers: quarterMods, keyCode: Int(kVK_UpArrow))
        case .bottomLeft: return HotkeyShortcut(modifiers: quarterMods, keyCode: Int(kVK_DownArrow))
        case .bottomRight: return HotkeyShortcut(modifiers: quarterMods, keyCode: Int(kVK_RightArrow))
        case .maximize: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_ANSI_M))
        case .center: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_ANSI_C))
        case .nextDisplay: return HotkeyShortcut(modifiers: halfMods, keyCode: Int(kVK_ANSI_N))
        }
    }
}

/// Pure window placement maths: screen detection, target frames, and clamped best-effort reposition.
nonisolated enum WindowLayout {
    struct Target: Equatable, Sendable {
        var frame: ScreenBounds
        var visibleFrame: ScreenBounds
        var crossDisplay: Bool
    }

    /// Picks the screen with the largest overlap with `window`; falls back to the nearest screen center.
    static func screenIndex(for window: ScreenBounds, in screens: [DisplayScreen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var bestIdx = 0
        var bestArea = -1.0
        for (i, s) in screens.enumerated() {
            let area = window.intersectionArea(with: s.frame)
            if area > bestArea {
                bestArea = area
                bestIdx = i
            }
        }
        if bestArea > 0 { return bestIdx }
        // Completely off-screen: choose the display whose center is closest.
        var nearestIdx = 0
        var nearestDist = Double.infinity
        for (i, s) in screens.enumerated() {
            let dx = window.midX - s.frame.midX
            let dy = window.midY - s.frame.midY
            let dist = dx * dx + dy * dy
            if dist < nearestDist {
                nearestDist = dist
                nearestIdx = i
            }
        }
        return nearestIdx
    }

    /// Computes the target AX frame for `action` on `window`. Returns nil if no screen exists or
    /// `nextDisplay` is invoked with only one display.
    static func target(
        for action: WindowAction,
        window: ScreenBounds,
        screens: [DisplayScreen]
    ) -> Target? {
        guard let idx = screenIndex(for: window, in: screens) else { return nil }
        let current = screens[idx].visibleFrame
        let halfW = floor(current.width / 2)
        let rightW = current.width - halfW
        let halfH = floor(current.height / 2)
        let bottomH = current.height - halfH

        switch action {
        case .leftHalf:
            return Target(frame: ScreenBounds(x: current.x, y: current.y, width: halfW, height: current.height),
                          visibleFrame: current, crossDisplay: false)
        case .rightHalf:
            return Target(frame: ScreenBounds(x: current.x + halfW, y: current.y, width: rightW, height: current.height),
                          visibleFrame: current, crossDisplay: false)
        case .topHalf:
            return Target(frame: ScreenBounds(x: current.x, y: current.y, width: current.width, height: halfH),
                          visibleFrame: current, crossDisplay: false)
        case .bottomHalf:
            return Target(frame: ScreenBounds(x: current.x, y: current.y + halfH, width: current.width, height: bottomH),
                          visibleFrame: current, crossDisplay: false)
        case .topLeft:
            return Target(frame: ScreenBounds(x: current.x, y: current.y, width: halfW, height: halfH),
                          visibleFrame: current, crossDisplay: false)
        case .topRight:
            return Target(frame: ScreenBounds(x: current.x + halfW, y: current.y, width: rightW, height: halfH),
                          visibleFrame: current, crossDisplay: false)
        case .bottomLeft:
            return Target(frame: ScreenBounds(x: current.x, y: current.y + halfH, width: halfW, height: bottomH),
                          visibleFrame: current, crossDisplay: false)
        case .bottomRight:
            return Target(frame: ScreenBounds(x: current.x + halfW, y: current.y + halfH, width: rightW, height: bottomH),
                          visibleFrame: current, crossDisplay: false)
        case .maximize:
            return Target(frame: current, visibleFrame: current, crossDisplay: false)
        case .center:
            let w = min(window.width, current.width)
            let h = min(window.height, current.height)
            let x = current.x + floor((current.width - w) / 2)
            let y = current.y + floor((current.height - h) / 2)
            return Target(frame: ScreenBounds(x: x, y: y, width: w, height: h),
                          visibleFrame: current, crossDisplay: false)
        case .nextDisplay:
            guard screens.count > 1 else { return nil }
            let next = screens[(idx + 1) % screens.count].visibleFrame
            let w = window.width >= current.width * 0.95 ? next.width : min(window.width, next.width)
            let h = window.height >= current.height * 0.95 ? next.height : min(window.height, next.height)
            let availOldW = max(1, current.width - window.width)
            let availOldH = max(1, current.height - window.height)
            let relX = min(1, max(0, (window.x - current.x) / availOldW))
            let relY = min(1, max(0, (window.y - current.y) / availOldH))
            let x = next.x + floor(relX * max(0, next.width - w))
            let y = next.y + floor(relY * max(0, next.height - h))
            return Target(frame: ScreenBounds(x: x, y: y, width: w, height: h),
                          visibleFrame: next, crossDisplay: true)
        }
    }

    /// Best-effort reposition after an app clamps a requested resize (e.g. minimum width/height),
    /// ensuring the window stays inside `visible` rather than overhanging off-screen or under the Dock.
    static func clampedPosition(
        desired: ScreenBounds,
        actualWidth: Double,
        actualHeight: Double,
        within visible: ScreenBounds
    ) -> (x: Double, y: Double) {
        let maxX = max(visible.x, visible.maxX - actualWidth)
        let maxY = max(visible.y, visible.maxY - actualHeight)
        let x = min(max(desired.x, visible.x), maxX)
        let y = min(max(desired.y, visible.y), maxY)
        return (x, y)
    }

    static func framesMatch(_ actual: ScreenBounds, _ desired: ScreenBounds, tolerance: Double = 2.0) -> Bool {
        abs(actual.x - desired.x) <= tolerance
            && abs(actual.y - desired.y) <= tolerance
            && abs(actual.width - desired.width) <= tolerance
            && abs(actual.height - desired.height) <= tolerance
    }

    /// Computes the clamped expected origin from `actual`'s size and returns it if either coordinate
    /// differs by more than `tolerance` (catches right/bottom overhang, left/top encroachment, and wrong-half placement).
    static func finalOriginCorrection(
        actual: ScreenBounds,
        target: Target,
        tolerance: Double = 2.0
    ) -> (x: Double, y: Double)? {
        let expected = clampedPosition(
            desired: target.frame,
            actualWidth: actual.width,
            actualHeight: actual.height,
            within: target.visibleFrame
        )
        if abs(actual.x - expected.x) > tolerance || abs(actual.y - expected.y) > tolerance {
            return expected
        }
        return nil
    }

    /// Retries the requested frame first when the initial read disagrees, then computes the final
    /// origin from the post-retry actual size and corrects either coordinate if off.
    /// Rechecks `shouldContinue` before every write so cancellation never issues a stale write.
    static func settle(
        target: Target,
        tolerance: Double = 2.0,
        shouldContinue: () -> Bool = { true },
        readFrame: () -> ScreenBounds?,
        writeFrame: (ScreenBounds) -> Bool,
        writePosition: (Double, Double) -> Void
    ) {
        guard let actual = readFrame(), !framesMatch(actual, target.frame, tolerance: tolerance) else { return }
        guard shouldContinue() else { return }
        guard writeFrame(target.frame), let afterRetry = readFrame() else { return }
        guard shouldContinue() else { return }
        if let corrected = finalOriginCorrection(actual: afterRetry, target: target, tolerance: tolerance) {
            writePosition(corrected.x, corrected.y)
        }
    }
}

/// Registration outcome for one of the 11 window management shortcuts.
nonisolated enum WindowHotkeyStatus: Equatable, Sendable {
    case registered
    case yielded(to: String)
    case refused
}

/// Manages active registrations for the 11 window management hotkeys.
/// Parameterized by `Handle` so tests verify registration/unregistration without Carbon.
final class WindowHotkeyRegistry<Handle> {
    struct Entry {
        let action: WindowAction
        let shortcut: HotkeyShortcut
        let id: UInt32
        let handle: Handle
    }

    struct Claim {
        let shortcut: HotkeyShortcut
        let owner: String
    }

    private(set) var entries: [Entry] = []
    private(set) var statuses: [WindowAction: WindowHotkeyStatus] = [:]

    /// Registers every window shortcut not already taken by `excluding` when `enabled` is true;
    /// unregisters everything and leaves zero registrations when `enabled` is false.
    func sync(
        enabled: Bool,
        excluding: [Claim] = [],
        nextID: () -> UInt32,
        register: (HotkeyShortcut, UInt32) -> Handle?,
        unregister: (Handle) -> Void
    ) {
        unregisterAll(unregister: unregister, clearStatuses: true)
        guard enabled else { return }
        for action in WindowAction.allCases {
            let shortcut = action.hotkeyShortcut
            if let claim = excluding.first(where: { $0.shortcut.overlaps(shortcut) }) {
                statuses[action] = .yielded(to: claim.owner)
                continue
            }
            let id = nextID()
            if let handle = register(shortcut, id) {
                entries.append(Entry(action: action, shortcut: shortcut, id: id, handle: handle))
                statuses[action] = .registered
            } else {
                statuses[action] = .refused
            }
        }
    }

    func unregisterAll(unregister: (Handle) -> Void, clearStatuses: Bool = false) {
        for entry in entries { unregister(entry.handle) }
        entries.removeAll()
        if clearStatuses { statuses.removeAll() }
    }

    func action(for id: UInt32) -> WindowAction? {
        entries.first { $0.id == id }?.action
    }

    /// Returns the shortcut label only when this action's binding is actively registered.
    func activeShortcutLabel(for action: WindowAction) -> String? {
        statuses[action] == .registered ? action.shortcutLabel : nil
    }

    /// Human-readable reasons for any window shortcut that yielded to a capture shortcut or was refused by Carbon.
    var issueMessages: [String] {
        Self.issueMessages(from: statuses)
    }

    static func issueMessages(from statuses: [WindowAction: WindowHotkeyStatus]) -> [String] {
        WindowAction.allCases.compactMap { action in
            switch statuses[action] {
            case .yielded(let owner):
                "\(action.title) (\(action.shortcutLabel)) is inactive because \(owner) uses that shortcut. Still available in Apps."
            case .refused:
                "\(action.title) (\(action.shortcutLabel)) couldn’t be registered — it may be used by another app. Still available in Apps."
            case .registered, nil:
                nil
            }
        }
    }
}

/// Pure AX error classification: messaging timeouts and dead/disabled targets abort immediately
/// instead of stacking additional timed-out IPC calls.
nonisolated enum WindowAXPolicy {
    static func shouldAbort(_ error: AXError) -> Bool {
        switch error {
        case .cannotComplete, .apiDisabled, .invalidUIElement:
            true
        default:
            false
        }
    }
}

/// Pure resolution of a window target captured before opening the Apps popup.
/// An explicit capture never falls back to a different app or window if the original disappears.
nonisolated enum WindowTargetState<OwnWindow: Equatable, ExternalWindow: Equatable>: Equatable {
    case own(OwnWindow?)
    case external(isTerminated: Bool, window: ExternalWindow?)
    case externalNeedsAccessibility(isTrustedNow: Bool)
    case unavailable

    enum Resolution: Equatable {
        case moveOwn(OwnWindow)
        case moveExternal(ExternalWindow)
        case needsAccessibility
        case reopenAfterGrant(String)
        case gone(String)
    }

    static var goneMessage: String { "The window you opened Apps from is no longer open." }
    static var unavailableMessage: String { "No movable window was active when Apps opened." }
    static var reopenAfterGrantMessage: String { "Accessibility is now allowed. Reopen Apps to move this window." }

    func resolve(ownIsVisible: (OwnWindow) -> Bool) -> Resolution {
        switch self {
        case .own(let window):
            guard let window, ownIsVisible(window) else {
                return .gone(Self.goneMessage)
            }
            return .moveOwn(window)
        case .external(let isTerminated, let window):
            guard !isTerminated, let window else {
                return .gone(Self.goneMessage)
            }
            return .moveExternal(window)
        case .externalNeedsAccessibility(let isTrustedNow):
            return isTrustedNow ? .reopenAfterGrant(Self.reopenAfterGrantMessage) : .needsAccessibility
        case .unavailable:
            return .gone(Self.unavailableMessage)
        }
    }
}

/// Two-phase execution for an Apps command on a captured external window:
/// validates the window, waits for the main actor to confirm it closed the originating popup session,
/// and starts placement only after that confirmation.
nonisolated enum WindowCapturedExecution {
    enum Outcome: Equatable, Sendable {
        case moved
        case gone
        case sessionEnded
        case cancelled
        case failed
    }

    static func run(
        isCurrent: () -> Bool,
        validateWindow: () -> Bool,
        confirmCloseOriginatingPopup: () -> Bool,
        place: () -> Bool
    ) -> Outcome {
        guard isCurrent() else { return .cancelled }
        guard validateWindow() else { return .gone }
        guard isCurrent() else { return .cancelled }
        guard confirmCloseOriginatingPopup() else { return .sessionEnded }
        guard isCurrent() else { return .cancelled }
        let ok = place()
        if !isCurrent() { return .cancelled }
        return ok ? .moved : .failed
    }
}

/// Thread-safe generation and cancellation gate for serialized window operations.
/// Starting a newer command (`begin()`) or disabling Window Management (`cancelAll()`)
/// immediately supersedes and wakes any sleeping retry or full-screen wait.
nonisolated final class WindowOperationGate: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var waiters: [DispatchSemaphore] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin() -> UInt64 {
        let (gen, toWake): (UInt64, [DispatchSemaphore]) = state.withLock { s in
            s.generation &+= 1
            let w = s.waiters
            s.waiters.removeAll()
            return (s.generation, w)
        }
        for sem in toWake { sem.signal() }
        return gen
    }

    func cancelAll() {
        let toWake: [DispatchSemaphore] = state.withLock { s in
            s.generation &+= 1
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for sem in toWake { sem.signal() }
    }

    func isCurrent(_ token: UInt64) -> Bool {
        state.withLock { $0.generation == token }
    }

    /// Waits up to `duration` on a background executor, waking immediately when `token` is superseded or cancelled.
    /// Returns `true` if `token` is still current after waiting, `false` otherwise.
    func wait(token: UInt64, duration: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let shouldWait: Bool = state.withLock { s in
            guard s.generation == token else { return false }
            s.waiters.append(sem)
            return true
        }
        guard shouldWait else { return false }
        _ = sem.wait(timeout: .now() + duration)
        return state.withLock { s in
            s.waiters.removeAll { $0 === sem }
            return s.generation == token
        }
    }
}

/// Result of reading `AXFullScreen` during an exit-confirmation poll.
/// Only an explicit `.success` read of Boolean `false` confirms exit; transient read failures
/// (`.noValue`, `.failure`, non-Boolean values) during the transition keep polling instead of placing early.
nonisolated enum WindowFullScreenPoll: Equatable, Sendable {
    case fullScreen
    case exited
    case transientFailure
    case abort

    static func from(error: AXError, boolValue: Bool?) -> Self {
        if error == .success, let boolValue {
            return boolValue ? .fullScreen : .exited
        }
        if WindowAXPolicy.shouldAbort(error) { return .abort }
        return .transientFailure
    }
}

/// Bounded confirmation loop for exiting full screen before placing an external AX window.
nonisolated enum WindowFullScreenExit {
    enum Outcome: Equatable, Sendable {
        case exited
        case writeFailed
        case timedOut
        case cancelled
        case readFailed
    }

    static func exitAndConfirm(
        maxPolls: Int = 40,
        shouldContinue: () -> Bool = { true },
        requestExit: () -> AXError,
        pollFullScreen: () -> WindowFullScreenPoll,
        waitStep: () -> Bool
    ) -> Outcome {
        guard shouldContinue() else { return .cancelled }
        guard requestExit() == .success else { return .writeFailed }
        for _ in 0..<maxPolls {
            guard waitStep() else { return .cancelled }
            switch pollFullScreen() {
            case .exited:
                return .exited
            case .fullScreen, .transientFailure:
                continue
            case .abort:
                return .readFailed
            }
        }
        return .timedOut
    }
}

/// Pure decision for an explicit user action requiring macOS Accessibility permission:
/// first attempt triggers macOS's prompt, subsequent explicit attempts open Privacy & Security › Accessibility.
nonisolated enum AccessibilityPermissionFlow {
    enum Action: Equatable, Sendable {
        case granted
        case promptSystem
        case openSettings
    }

    static func decide(isTrusted: Bool, hasPromptedBefore: Bool) -> Action {
        if isTrusted { return .granted }
        return hasPromptedBefore ? .openSettings : .promptSystem
    }
}
