//
//  ModifierTaps.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox

/// The modifier keys a shortcut can be on its own, by virtual key code. Tapped once, a shortcut is that one key (Right ⌥
/// isn't Left ⌥); tapped twice, it is either key of the pair, stored as the left one.
enum ModifierKeys {
    struct Key {
        let family: HotkeyShortcut.Modifiers
        let isRight: Bool
        /// IOKit's device-dependent flag bit for the key (NX_DEVICE…KEYMASK in IOLLEvent.h), which tells left from right.
        let deviceBit: UInt64
    }

    static let keys: [Int: Key] = [
        kVK_Control: Key(family: .control, isRight: false, deviceBit: 0x0001),
        kVK_RightControl: Key(family: .control, isRight: true, deviceBit: 0x2000),
        kVK_Shift: Key(family: .shift, isRight: false, deviceBit: 0x0002),
        kVK_RightShift: Key(family: .shift, isRight: true, deviceBit: 0x0004),
        kVK_Command: Key(family: .command, isRight: false, deviceBit: 0x0008),
        kVK_RightCommand: Key(family: .command, isRight: true, deviceBit: 0x0010),
        kVK_Option: Key(family: .option, isRight: false, deviceBit: 0x0020),
        kVK_RightOption: Key(family: .option, isRight: true, deviceBit: 0x0040),
    ]

    static let deviceBits = keys.values.reduce(UInt64(0)) { $0 | $1.deviceBit }

    static func leftKeyCode(of family: HotkeyShortcut.Modifiers) -> Int? {
        keys.first { $0.value.family == family && !$0.value.isRight }?.key
    }
}

/// Turns modifier key changes into taps. A tap is a modifier pressed and released on its own within `interval`: at both
/// edges the event's own flags show no other modifier and no fn down, no other key is down (`keyDown` and `keyUp` count
/// them, never saying which), and no key, click or scroll comes in between (`interrupt`). Two taps of one pair, the
/// second pressed within `interval` of the first's release, are also a double tap. It is fed key codes and flags only,
/// so nothing typed passes through it.
struct ModifierTapDetector {
    enum Tap: Equatable {
        case once(keyCode: Int)
        /// The pair's left key, whichever keys were tapped.
        case twice(keyCode: Int)
    }

    /// The longest tap and the longest gap between two taps: the callers pass the system's double-click interval.
    var interval: TimeInterval = 0.5

    private var pressed: (keyCode: Int, at: TimeInterval)?
    private var lastTap: (keyCode: Int, releasedAt: TimeInterval)?
    /// How many other keys are down, from their down and up events: a count, never which keys.
    private var keysDown = 0
    /// After events were missed (watching just started, or macOS withheld some), a key can be down that was never seen
    /// going down. Nothing taps until the events themselves have shown the keyboard quiet: no key down, repeat or up for
    /// `quiet`, counted in the events' own times, so events still queued from before that point never count.
    private(set) var isUnsure = false
    /// Long enough for a key held through missed events to show itself by repeating (`quietTime`).
    var quiet: TimeInterval = 0.7
    private var lastKeyEvent: TimeInterval = 0
    /// Secure input (a password field) as the last event found it: while it's on, macOS withholds other keys.
    private(set) var isSecure = false

    /// The key-repeat delay and two repeats (0.67 s at macOS's defaults), at most 2.5 s. With key repeat off a held key
    /// sends nothing at all, which no event can show; then it's the 2.5 s.
    static func quietTime(repeatDelay: TimeInterval = NSEvent.keyRepeatDelay,
                          repeatInterval: TimeInterval = NSEvent.keyRepeatInterval) -> TimeInterval {
        min(repeatDelay + 2 * repeatInterval, 2.5)
    }

    /// Watching from `time`, with nothing known of what's down: how the event tap and the Settings recorder both start.
    static func startingAt(_ time: TimeInterval, quiet: TimeInterval = quietTime()) -> ModifierTapDetector {
        var detector = ModifierTapDetector()
        detector.quiet = quiet
        detector.eventsMissed(at: time)
        return detector
    }

    /// Something else happened (a key, a click, a scroll, a shortcut): neither the modifier held now nor a first tap counts.
    mutating func interrupt() {
        pressed = nil
        lastTap = nil
    }

    /// Events were missed, or watching starts now (`time`): nothing seen before counts, and what's down isn't known.
    mutating func eventsMissed(at time: TimeInterval) {
        interrupt()
        keysDown = 0
        isUnsure = true
        lastKeyEvent = time
    }

    /// Secure input as this event finds it. A change either way means keys were withheld meanwhile: events missed.
    /// Returns whether it changed. It's a sample, so a password field that takes the keyboard and lets it go between two
    /// events can't be seen.
    mutating func secureInput(_ isOn: Bool, at time: TimeInterval) -> Bool {
        guard isOn != isSecure else { return false }
        isSecure = isOn
        eventsMissed(at: time)
        return true
    }

    /// Some other key went down. A repeat means one is held, even if it went down before watching started.
    mutating func keyDown(isRepeat: Bool, at time: TimeInterval) {
        interrupt()
        keysDown = isRepeat ? max(keysDown, 1) : keysDown + 1
        lastKeyEvent = time
    }

    mutating func keyUp(at time: TimeInterval) {
        interrupt()
        keysDown = max(keysDown - 1, 0)
        lastKeyEvent = time
    }

    /// One flags-changed event: the key that changed and the flags after it. Returns the taps it completes.
    mutating func flagsChanged(keyCode: Int, flags: UInt64, at time: TimeInterval) -> [Tap] {
        if isUnsure, keysDown == 0, time - lastKeyEvent >= quiet { isUnsure = false }
        // fn or Caps Lock; or secure input, where other keys may not arrive, so a chord could look like a tap.
        guard let key = ModifierKeys.keys[keyCode], !isSecure else {
            interrupt()
            return []
        }
        let families = HotkeyShortcut.Modifiers(from: NSEvent.ModifierFlags(rawValue: UInt(flags & 0xFFFF_0000)))
        let fn = flags & UInt64(NSEvent.ModifierFlags.function.rawValue) != 0
        let devices = flags & ModifierKeys.deviceBits
        // Without device bits (some keyboards and synthetic events) only the pair's flag says whether it's down.
        let isDown = devices != 0 ? devices & key.deviceBit != 0 : families.contains(key.family)
        // From the event's flags, not from what was seen going down: a modifier held since before watching started counts.
        let nothingElseDown = keysDown == 0 && !isUnsure && !fn

        if isDown {
            if pressed == nil, nothingElseDown, families == key.family, devices == 0 || devices == key.deviceBit {
                pressed = (keyCode, time)
            } else {
                interrupt()  // with another modifier or key down: a chord, not a tap
            }
            return []
        }

        guard nothingElseDown, families.isEmpty, devices == 0, let press = pressed, press.keyCode == keyCode,
              time - press.at <= interval else {
            interrupt()
            return []
        }
        pressed = nil
        if let last = lastTap, ModifierKeys.keys[last.keyCode]?.family == key.family, press.at - last.releasedAt <= interval,
           let left = ModifierKeys.leftKeyCode(of: key.family) {
            lastTap = nil
            return [.once(keyCode: keyCode), .twice(keyCode: left)]
        }
        lastTap = (keyCode, time)
        return [.once(keyCode: keyCode)]
    }
}

/// What a shortcut on a modifier key alone still needs from macOS, for Settings to say.
enum InputMonitoringNeed: Equatable {
    case none
    /// Not granted: Sukusho has to be turned on in Privacy & Security › Input Monitoring.
    case grant
    /// Granted, but this run of Sukusho can't watch yet: macOS applies Input Monitoring when an app next opens.
    case relaunch

    static func of(hasTapShortcuts: Bool, watching: Bool, granted: Bool) -> Self {
        guard hasTapShortcuts, !watching else { return .none }
        return granted ? .relaunch : .grant
    }
}

extension HotkeyShortcut {
    /// The shortcut a tap is: once, that key; twice, its pair.
    init(_ tap: ModifierTapDetector.Tap) {
        switch tap {
        case .once(let keyCode): self.init(modifiers: [], keyCode: keyCode, taps: 1)
        case .twice(let keyCode): self.init(modifiers: [], keyCode: keyCode, taps: 2)
        }
    }
}
