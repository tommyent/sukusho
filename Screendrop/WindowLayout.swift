import Carbon.HIToolbox
import CoreGraphics
import Foundation

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

    private(set) var entries: [Entry] = []

    /// Registers every window shortcut not already taken by `excluding` when `enabled` is true;
    /// unregisters everything and leaves zero registrations when `enabled` is false.
    func sync(
        enabled: Bool,
        excluding: [HotkeyShortcut] = [],
        nextID: () -> UInt32,
        register: (HotkeyShortcut, UInt32) -> Handle?,
        unregister: (Handle) -> Void
    ) {
        unregisterAll(unregister: unregister)
        guard enabled else { return }
        for action in WindowAction.allCases {
            let shortcut = action.hotkeyShortcut
            guard !excluding.contains(where: shortcut.overlaps) else { continue }
            let id = nextID()
            if let handle = register(shortcut, id) {
                entries.append(Entry(action: action, shortcut: shortcut, id: id, handle: handle))
            }
        }
    }

    func unregisterAll(unregister: (Handle) -> Void) {
        for entry in entries { unregister(entry.handle) }
        entries.removeAll()
    }

    func action(for id: UInt32) -> WindowAction? {
        entries.first { $0.id == id }?.action
    }
}
