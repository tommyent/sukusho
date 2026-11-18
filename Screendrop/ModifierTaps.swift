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
    /// going down. Nothing taps until the caller arms it (`arm`): once the events show the keyboard quiet for `quiet`
    /// (`canArm`), it asks macOS once whether any other key is down, a yes or no (`otherKeyDown`), and arms at that
    /// moment when none is. Only gestures pressed after it count, so events still queued from before never do.
    private(set) var isUnsure = false
    /// Long enough for a key held through missed events to show itself by repeating (`quietTime`).
    var quiet: TimeInterval = 0.7
    private var armedAt: TimeInterval = -.infinity
    /// The last arming read, from when it started to when it ended. An ordinary key event stamped inside it, arriving
    /// later, means a key changed while the keys were being read, so the read may have missed one (Sol's round 8
    /// rollover: A read as up, then A down and E up, then E read as up), and that arming is void.
    private var armingRead: ClosedRange<TimeInterval>?
    /// When events were last missed: a key event stamped earlier, delivered late, is from before the gap and never
    /// moves the quiet stretch (Sol's round 7 probe: a key-up stamped 9.00 after a reset at 10.00).
    private var missedAt: TimeInterval = -.infinity
    private var lastKeyEvent: TimeInterval = -.infinity
    /// Secure input (a password field) as the last event found it: while it's on, macOS withholds other keys.
    private(set) var isSecure = false

    /// The key-repeat delay and two repeats (0.67 s at macOS's defaults), at most 2.5 s. With key repeat off a held key
    /// sends nothing at all; the reading before arming is what sees it then.
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

    /// When the events will have shown the keyboard quiet for the stretch, if no other key event comes first.
    var quietEnds: TimeInterval { lastKeyEvent + quiet }

    /// Whether the events show the keyboard quiet for the stretch by `time`, with no key known to be down: then the
    /// caller asks macOS (`otherKeyDown`) before arming. Never while secure input is on: the keys aren't read then, and
    /// watching stays passive until it ends.
    func canArm(at time: TimeInterval) -> Bool {
        isUnsure && !isSecure && keysDown == 0 && time >= quietEnds
    }

    /// The read from `start` to `end` found no other key down: gestures pressed after `end`, when the read was complete,
    /// count again, unless a key event from inside the read turns up (`keyDown`, `keyUp`).
    mutating func arm(readFrom start: TimeInterval, to end: TimeInterval) {
        isUnsure = false
        armedAt = end
        armingRead = start...end
    }

    /// True when the event voids the last arming: it's stamped inside that read.
    private mutating func voidsArming(_ time: TimeInterval) -> Bool {
        guard let read = armingRead, read.contains(time) else { return false }
        armingRead = nil
        isUnsure = true
        return true
    }

    /// One reading of whether any key other than a modifier is down, reduced at once to a yes or no: which key is never
    /// kept, logged or used. Read only to arm (desk-lead, 2026-11-18: one yes-or-no reading at the end of the quiet
    /// stretch, since with key repeat off a held key sends no event at all).
    static func otherKeyDown() -> Bool {
        (0..<128).contains { code in
            ModifierKeys.keys[code] == nil && code != kVK_Function && code != kVK_CapsLock
                && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
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
        missedAt = time
        lastKeyEvent = time
        armingRead = nil
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

    /// Some other key went down. A repeat means one is held, even if it went down before watching started. Returns true
    /// when it voided the last arming, so the caller arms again.
    @discardableResult
    mutating func keyDown(isRepeat: Bool, at time: TimeInterval) -> Bool {
        interrupt()
        guard time >= missedAt else { return false }
        keysDown = isRepeat ? max(keysDown, 1) : keysDown + 1
        lastKeyEvent = max(lastKeyEvent, time)
        return voidsArming(time)
    }

    @discardableResult
    mutating func keyUp(at time: TimeInterval) -> Bool {
        interrupt()
        guard time >= missedAt else { return false }
        keysDown = max(keysDown - 1, 0)
        lastKeyEvent = max(lastKeyEvent, time)
        return voidsArming(time)
    }

    /// One flags-changed event: the key that changed and the flags after it. Returns the taps it completes.
    mutating func flagsChanged(keyCode: Int, flags: UInt64, at time: TimeInterval) -> [Tap] {
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
            if pressed == nil, nothingElseDown, time > armedAt, families == key.family, devices == 0 || devices == key.deviceBit {
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
    /// macOS turned the watching off on the user's behalf: off until Sukusho relaunches.
    case turnedOff

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
