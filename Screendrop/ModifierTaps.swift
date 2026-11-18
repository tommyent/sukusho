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

/// Turns modifier key changes into taps. A tap is a modifier pressed and released on its own within `interval`, with no
/// other key, click or scroll meanwhile (`interrupt`); two taps of one pair, the second pressed within `interval` of the
/// first's release, are also a double tap. It is fed key codes and flags only, so nothing typed passes through it.
struct ModifierTapDetector {
    enum Tap: Equatable {
        case once(keyCode: Int)
        /// The pair's left key, whichever keys were tapped.
        case twice(keyCode: Int)
    }

    /// The longest tap and the longest gap between two taps: the callers pass the system's double-click interval.
    var interval: TimeInterval = 0.5

    private var held: Set<Int> = []
    private var pressed: (keyCode: Int, at: TimeInterval)?
    private var lastTap: (keyCode: Int, releasedAt: TimeInterval)?

    /// Something else happened (a key, a click, a scroll, a shortcut): neither the modifier held now nor a first tap counts.
    mutating func interrupt() {
        pressed = nil
        lastTap = nil
    }

    /// One flags-changed event: the key that changed and the flags after it. Returns the taps it completes.
    mutating func flagsChanged(keyCode: Int, flags: UInt64, at time: TimeInterval) -> [Tap] {
        let families = HotkeyShortcut.Modifiers(from: NSEvent.ModifierFlags(rawValue: UInt(flags & 0xFFFF_0000)))
        // A pair whose flag is off has no key down, even if a release was missed.
        held = held.filter { ModifierKeys.keys[$0].map { families.contains($0.family) } ?? false }
        guard let key = ModifierKeys.keys[keyCode] else {
            interrupt()  // fn or Caps Lock
            return []
        }
        // Without device bits (some keyboards and synthetic events) only the pair's flag says whether it's down.
        let isDown = flags & ModifierKeys.deviceBits != 0 ? flags & key.deviceBit != 0 : families.contains(key.family)

        if isDown {
            guard !held.contains(keyCode) else { return [] }
            if held.isEmpty {
                pressed = (keyCode, time)
            } else {
                interrupt()  // a second modifier: a chord, not a tap
            }
            held.insert(keyCode)
            return []
        }

        held.remove(keyCode)
        guard held.isEmpty, let press = pressed, press.keyCode == keyCode, time - press.at <= interval else {
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

extension HotkeyShortcut {
    /// The shortcut a tap is: once, that key; twice, its pair.
    init(_ tap: ModifierTapDetector.Tap) {
        switch tap {
        case .once(let keyCode): self.init(modifiers: [], keyCode: keyCode, taps: 1)
        case .twice(let keyCode): self.init(modifiers: [], keyCode: keyCode, taps: 2)
        }
    }
}
