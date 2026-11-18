import AppKit
import Carbon.HIToolbox
import Testing

/// The owner, 2026-11-17 (beta 1): "You should not be required to use three keys." Two keys, a function key alone, a
/// modifier key tapped on its own (Right ⌥) and a double tap of one (⌥ ⌥, ⌘ ⌘) are all shortcuts now.
struct FlexibleShortcutsTests {
    private let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
    private let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
    private let rightOptionBit: UInt64 = 0x40
    private let leftOptionBit: UInt64 = 0x20
    private let leftCommandBit: UInt64 = 0x08

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "FlexibleShortcutsTests-\(UUID().uuidString)")!
    }

    private func chord(_ modifiers: HotkeyShortcut.Modifiers, _ keyCode: Int) -> HotkeyShortcut {
        HotkeyShortcut(modifiers: modifiers, keyCode: keyCode)
    }

    // MARK: - Keys with modifiers, and keys alone

    @Test func oneModifierAndAKeyRecords() {
        for shortcut in [chord([.command], kVK_ANSI_K), chord([.option], kVK_ANSI_1), chord([.control], kVK_ANSI_X),
                         chord([.shift], kVK_ANSI_A)] {
            #expect(shortcut.refusal == nil, "\(shortcut.displayString)")
            #expect(shortcut.isValid)
        }
        #expect(chord([.command], kVK_ANSI_K).displayString == "⌘ K")
    }

    @Test func keysThatAlsoTypeAreWarnedAboutNotRefused() {
        #expect(chord([.option], kVK_ANSI_1).typingWarning == "⌥ 1 also types a character. While it’s Sukusho’s shortcut, you can’t type it.")
        #expect(chord([.shift, .option], kVK_ANSI_A).typingWarning?.contains("types a character") == true)
        #expect(chord([.shift], kVK_LeftArrow).typingWarning == "⇧ ← also works in text fields. While it’s Sukusho’s shortcut, no app gets it.")
        #expect(chord([.command], kVK_ANSI_K).typingWarning == nil)
        #expect(chord([.control], kVK_ANSI_X).typingWarning == nil)
        #expect(chord([.option, .command], kVK_ANSI_1).typingWarning == nil)
        #expect(chord([.option], kVK_F5).typingWarning == nil, "a function key types nothing")
    }

    @Test func aFunctionKeyAloneRecordsAndAnyOtherKeyAloneIsRefused() {
        for keyCode in [kVK_F1, kVK_F5, kVK_F12, kVK_F13, kVK_F20] {
            let alone = chord([], keyCode)
            #expect(alone.refusal == nil)
            #expect(alone.isValid)
            #expect(alone.typingWarning == nil)
        }
        #expect(chord([], kVK_F13).displayString == "F13")
        #expect(chord([], kVK_ANSI_A).refusal == "A on its own would stop working in every app. Add ⌘, ⌥, ⌃ or ⇧, or use F1 to F20.")
        #expect(chord([], kVK_Space).refusal != nil)
        #expect(!chord([], kVK_ANSI_A).isValid, "a stored lone letter falls back to the default")
    }

    // MARK: - Modifier keys on their own

    @Test func tapsShowTheirSideAndDoubleTapsTheirPair() {
        #expect(HotkeyShortcut(.once(keyCode: kVK_RightOption)).displayString == "Right ⌥")
        #expect(HotkeyShortcut(.once(keyCode: kVK_Command)).displayString == "Left ⌘")
        #expect(HotkeyShortcut(.once(keyCode: kVK_RightControl)).displayTokens == ["Right ⌃"])
        #expect(HotkeyShortcut(.twice(keyCode: kVK_Option)).displayString == "⌥ ⌥")
        #expect(HotkeyShortcut(.twice(keyCode: kVK_Command)).displayTokens == ["⌘ ⌘"])
        #expect(HotkeyShortcut(.twice(keyCode: kVK_Shift)).displayTokens.joined() == "⇧ ⇧")
        #expect(HotkeyShortcut(.once(keyCode: kVK_RightOption)) != HotkeyShortcut(.once(keyCode: kVK_Option)))
        for tap in [ModifierTapDetector.Tap.once(keyCode: kVK_RightShift), .twice(keyCode: kVK_Control)] {
            #expect(HotkeyShortcut(tap).isValid)
            #expect(HotkeyShortcut(tap).refusal == nil)
            #expect(HotkeyShortcut(tap).typingWarning == nil)
        }
        #expect(!HotkeyShortcut(modifiers: [], keyCode: kVK_ANSI_A, taps: 1).isValid, "only modifier keys tap")
        #expect(!HotkeyShortcut(modifiers: [], keyCode: kVK_Option, taps: 3).isValid)
    }

    @Test func aTapIsOneModifierPressedAndReleasedAlone() {
        var detector = ModifierTapDetector()
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 10).isEmpty)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 10.1) == [.once(keyCode: kVK_RightOption)])
        #expect(detector.flagsChanged(keyCode: kVK_Option, flags: option | leftOptionBit, at: 20).isEmpty)
        #expect(detector.flagsChanged(keyCode: kVK_Option, flags: 0, at: 20.1) == [.once(keyCode: kVK_Option)], "left is its own key")
    }

    @Test func aChordNeverTaps() {
        var detector = ModifierTapDetector()
        // ⌥ held while a key is typed: the key interrupts.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1)
        detector.interrupt()
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.1).isEmpty)
        // ⌥ and ⌘ together, released in either order.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 2)
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: option | command | rightOptionBit | leftCommandBit, at: 2.05)
        #expect(detector.flagsChanged(keyCode: kVK_Command, flags: option | rightOptionBit, at: 2.1).isEmpty)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 2.15).isEmpty)
        // Both ⌥ keys.
        _ = detector.flagsChanged(keyCode: kVK_Option, flags: option | leftOptionBit, at: 3)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | leftOptionBit | rightOptionBit, at: 3.05)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: option | leftOptionBit, at: 3.1).isEmpty)
        #expect(detector.flagsChanged(keyCode: kVK_Option, flags: 0, at: 3.15).isEmpty)
        // fn pressed while ⌥ is held.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 4)
        _ = detector.flagsChanged(keyCode: kVK_Function, flags: option | rightOptionBit | UInt64(NSEvent.ModifierFlags.function.rawValue), at: 4.05)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 4.1).isEmpty)
    }

    @Test func aHoldLongerThanTheIntervalIsNoTap() {
        var detector = ModifierTapDetector()
        detector.interval = 0.5
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.6).isEmpty)
    }

    @Test func twoTapsWithinTheIntervalAreADoubleTapOfEitherKey() {
        var detector = ModifierTapDetector()
        detector.interval = 0.5
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.08) == [.once(keyCode: kVK_RightOption)])
        _ = detector.flagsChanged(keyCode: kVK_Option, flags: option | leftOptionBit, at: 1.5)   // 0.42 s after the release
        #expect(detector.flagsChanged(keyCode: kVK_Option, flags: 0, at: 1.58)
            == [.once(keyCode: kVK_Option), .twice(keyCode: kVK_Option)])
        // A third tap starts a new pair rather than making a second double tap.
        _ = detector.flagsChanged(keyCode: kVK_Option, flags: option | leftOptionBit, at: 1.7)
        #expect(detector.flagsChanged(keyCode: kVK_Option, flags: 0, at: 1.78) == [.once(keyCode: kVK_Option)])
    }

    @Test func slowSpoiltOrMixedTapsAreNoDoubleTap() {
        var detector = ModifierTapDetector()
        detector.interval = 0.3
        func tap(_ keyCode: Int, _ flags: UInt64, at time: TimeInterval) -> [ModifierTapDetector.Tap] {
            _ = detector.flagsChanged(keyCode: keyCode, flags: flags, at: time)
            return detector.flagsChanged(keyCode: keyCode, flags: 0, at: time + 0.05)
        }
        _ = tap(kVK_Command, command | leftCommandBit, at: 1)
        #expect(tap(kVK_Command, command | leftCommandBit, at: 1.45) == [.once(keyCode: kVK_Command)], "0.4 s gap, interval 0.3")
        _ = tap(kVK_Command, command | leftCommandBit, at: 2)
        detector.interrupt()   // a click between the taps
        #expect(tap(kVK_Command, command | leftCommandBit, at: 2.15) == [.once(keyCode: kVK_Command)])
        _ = tap(kVK_Option, option | leftOptionBit, at: 3)
        #expect(tap(kVK_Command, command | leftCommandBit, at: 3.15) == [.once(keyCode: kVK_Command)], "⌥ then ⌘ isn't a pair")
    }

    /// Sol's review, blocker 1: a modifier held since before the detector saw it go down, or fn, which it never tracks,
    /// still shows in the event's flags, so the tap is no tap.
    @Test func aModifierHeldFromBeforeIsSeenInTheFlags() {
        let fn = UInt64(NSEvent.ModifierFlags.function.rawValue)
        var detector = ModifierTapDetector()
        // Left ⌘ went down before; its event never came.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: command | option | leftCommandBit | rightOptionBit, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: command | leftCommandBit, at: 1.1).isEmpty)
        // The same without device bits.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: command | option, at: 2)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: command, at: 2.1).isEmpty)
        // fn held.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: fn | option | rightOptionBit, at: 3)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: fn, at: 3.1).isEmpty)
        // The other ⌥ held, with and without device bits.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | leftOptionBit | rightOptionBit, at: 4)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: option | leftOptionBit, at: 4.1).isEmpty)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option, at: 5)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: option, at: 5.1).isEmpty)
        // ⌘ pressed after ⌥ but released before it: the release still carries ⌥ alone, but the tap was spoilt.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 6)
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: option | command | rightOptionBit | leftCommandBit, at: 6.05)
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: option | rightOptionBit, at: 6.1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 6.15).isEmpty)
        // And nothing left over: a clean tap still taps.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 7)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 7.1) == [.once(keyCode: kVK_RightOption)])
    }

    /// Sol's review, blocker 2: E held through the whole tap, released after it or during it.
    @Test func aKeyHeldAcrossTheTapStopsIt() {
        var detector = ModifierTapDetector()
        detector.keyDown(isRepeat: false, at: 0.9)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.1).isEmpty)
        detector.keyUp(at: 1.2)

        detector.keyDown(isRepeat: false, at: 1.9)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 2)
        detector.keyUp(at: 2.05)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 2.1).isEmpty)

        // Two keys down, one up: one is still held.
        detector.keyDown(isRepeat: false, at: 2.8)
        detector.keyDown(isRepeat: false, at: 2.85)
        detector.keyUp(at: 2.9)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 3)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 3.1).isEmpty)
        detector.keyUp(at: 3.2)

        // Every key up: the next tap taps.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 4)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 4.1) == [.once(keyCode: kVK_RightOption)])
    }

    /// A key held since before watching started shows only by repeating; its release brings taps back.
    @Test func aRepeatingKeyCountsAsHeld() {
        var detector = ModifierTapDetector()
        detector.keyDown(isRepeat: true, at: 0.8)
        detector.keyDown(isRepeat: true, at: 0.9)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.1).isEmpty)
        detector.keyUp(at: 1.2)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 2)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 2.1) == [.once(keyCode: kVK_RightOption)])
    }

    /// Sol's re-review, blocker 1: watching starts while E is held, Sukusho is busy, and Right ⌥ goes down and up, then E
    /// up, before the callbacks catch up. Judged in the events' own order and times, the ⌥ press came before the keyboard
    /// was seen quiet, so it isn't a tap, whatever the keyboard is like by the time it's processed.
    @Test func eventsQueuedBeforeTheKeyboardWasSeenQuietNeverTap() {
        var detector = ModifierTapDetector()
        detector.quiet = 0.7
        detector.eventsMissed(at: 10)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 10.1)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 10.2).isEmpty)
        detector.keyUp(at: 10.3)   // E, never seen going down
        // E repeating instead: it shows within the quiet stretch, so a later press doesn't count either.
        detector.eventsMissed(at: 20)
        detector.keyDown(isRepeat: true, at: 20.5)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 20.8)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 20.9).isEmpty)
        detector.keyUp(at: 21)
        // Quiet for less than the stretch since E came up: still nothing.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 21.4)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 21.5).isEmpty)
        // Quiet for the stretch: taps again.
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 21.8)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 21.9) == [.once(keyCode: kVK_RightOption)])
        #expect(!detector.isUnsure)
    }

    /// After missed events a press before them doesn't finish a tap, a first tap before them doesn't pair with one after,
    /// and with nothing held the first tap after the quiet stretch counts.
    @Test func afterMissedEventsTheKeyboardMustBeSeenQuiet() {
        var detector = ModifierTapDetector()
        detector.quiet = 0.7
        detector.keyDown(isRepeat: false, at: 0.9)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1)
        detector.eventsMissed(at: 1.05)
        #expect(detector.isUnsure)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.1).isEmpty, "the press came before the gap")
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 1.5)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 1.6).isEmpty, "not quiet long enough yet")
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 3)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 3.1) == [.once(keyCode: kVK_RightOption)],
                "the key seen going down before the gap, whose release was missed, no longer counts")
        // A short stretch, so the next press is within the double-tap interval of that tap: it still doesn't pair.
        detector.quiet = 0.1
        detector.eventsMissed(at: 3.15)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 3.3)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 3.35) == [.once(keyCode: kVK_RightOption)],
                "no double tap across the gap")
    }

    /// Sol's re-review, 2: Settings' recorder starts knowing nothing too. E held since before Record was clicked: a
    /// Right ⌥ tap before the keyboard is seen quiet isn't recorded, nor one after E has repeated. With key repeat off E
    /// sends nothing at all, so a tap after the stretch is recorded: no event can show that E is down.
    @Test func theRecorderStartsWithoutKnowingWhatsDown() {
        var detector = ModifierTapDetector.startingAt(5, quiet: 0.7)
        #expect(detector.isUnsure)
        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 5.3)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 5.4).isEmpty)

        var repeating = ModifierTapDetector.startingAt(5, quiet: 0.7)
        repeating.keyDown(isRepeat: true, at: 5.5)
        _ = repeating.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 5.8)
        #expect(repeating.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 5.9).isEmpty)

        _ = detector.flagsChanged(keyCode: kVK_RightOption, flags: option | rightOptionBit, at: 5.8)
        #expect(detector.flagsChanged(keyCode: kVK_RightOption, flags: 0, at: 5.9) == [.once(keyCode: kVK_RightOption)])
    }

    /// Sol's re-review, 4: secure input found on, or found off again, at the next event (with no callback in between)
    /// drops the gesture under way, and the keyboard must be seen quiet again; while it's on nothing taps. A secure
    /// stretch that starts and ends between two events is invisible to the sample, so it isn't claimed.
    @Test func secureInputComingOrGoingIsAGap() {
        var detector = ModifierTapDetector()
        detector.quiet = 0.7
        let offFromTheStart = detector.secureInput(false, at: 1)
        #expect(!offFromTheStart)
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: command | leftCommandBit, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_Command, flags: 0, at: 1.05) == [.once(keyCode: kVK_Command)])
        let cameOn = detector.secureInput(true, at: 1.2)
        #expect(cameOn)
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: command | leftCommandBit, at: 1.2)
        #expect(detector.flagsChanged(keyCode: kVK_Command, flags: 0, at: 1.25).isEmpty, "secure input on")
        let wentOff = detector.secureInput(false, at: 1.3)
        #expect(wentOff)
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: command | leftCommandBit, at: 1.3)
        #expect(detector.flagsChanged(keyCode: kVK_Command, flags: 0, at: 1.35).isEmpty, "no ⌘ ⌘ with the first tap")
        _ = detector.flagsChanged(keyCode: kVK_Command, flags: command | leftCommandBit, at: 2.2)
        #expect(detector.flagsChanged(keyCode: kVK_Command, flags: 0, at: 2.25) == [.once(keyCode: kVK_Command)])
        let stillOff = detector.secureInput(false, at: 3)
        #expect(!stillOff)
    }

    /// The stretch is the key-repeat delay and two repeats, so a held key has repeated by then; with key repeat off (or
    /// nearly) it's 2.5 s.
    @Test func theQuietStretchFollowsKeyRepeat() {
        #expect(abs(ModifierTapDetector.quietTime(repeatDelay: 0.5, repeatInterval: 1.0 / 12) - 0.6667) < 0.001)
        #expect(abs(ModifierTapDetector.quietTime(repeatDelay: 0.225, repeatInterval: 0.03) - 0.285) < 0.001)
        #expect(ModifierTapDetector.quietTime(repeatDelay: 4500, repeatInterval: 4500) == 2.5)
    }

    @Test func keyboardsWithoutDeviceBitsStillTap() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: kVK_RightCommand, flags: command, at: 1)
        #expect(detector.flagsChanged(keyCode: kVK_RightCommand, flags: 0, at: 1.1) == [.once(keyCode: kVK_RightCommand)])
    }

    // MARK: - Clashes between kinds

    @Test func aTapAndADoubleTapOfOnePairOverlap() {
        let rightOption = HotkeyShortcut(.once(keyCode: kVK_RightOption))
        let leftOption = HotkeyShortcut(.once(keyCode: kVK_Option))
        let optionTwice = HotkeyShortcut(.twice(keyCode: kVK_Option))
        let commandTwice = HotkeyShortcut(.twice(keyCode: kVK_Command))
        #expect(optionTwice.overlaps(rightOption))
        #expect(rightOption.overlaps(optionTwice))
        #expect(leftOption.overlaps(optionTwice))
        #expect(optionTwice.overlaps(optionTwice))
        #expect(!rightOption.overlaps(leftOption))
        #expect(!optionTwice.overlaps(commandTwice))
        #expect(!optionTwice.overlaps(chord([.option], kVK_ANSI_1)))
        #expect(chord([.command], kVK_ANSI_K).overlaps(chord([.command], kVK_ANSI_K)))
        #expect(!chord([.command], kVK_ANSI_K).overlaps(chord([.option], kVK_ANSI_K)))
    }

    @Test func conflictsAreFoundAcrossKinds() {
        let defaults = suite()
        CaptureHotkeyPreferences.saveShortcut(HotkeyShortcut(.once(keyCode: kVK_RightOption)), for: .library, defaults: defaults)
        #expect(CaptureHotkeyPreferences.conflictingAction(for: HotkeyShortcut(.twice(keyCode: kVK_Option)), excluding: .area,
                                                           defaults: defaults) == .library)
        #expect(CaptureHotkeyPreferences.conflictingAction(for: HotkeyShortcut(.once(keyCode: kVK_Option)), excluding: .area,
                                                           defaults: defaults) == nil)
        #expect(CaptureHotkeyPreferences.conflictingAction(for: HotkeyShortcut(.twice(keyCode: kVK_Option)), excluding: .library,
                                                           defaults: defaults) == nil, "an action doesn't clash with itself")
        #expect(CaptureHotkeyPreferences.conflictingAction(for: CaptureHotkeyAction.window.defaultShortcut, excluding: .area,
                                                           defaults: defaults) == .window)
    }

    // MARK: - Dictation

    /// VM, macOS 27.2.1: ⌃ ⌃ on Fullscreen also opened Dictation, whose shortcut there was Press Control Key Twice
    /// (entry 164, type modifier, 262144). The ⌘ variants are read by their ⌘ flag, whatever else the value holds.
    @Test func aDoubleTapThatIsDictationsShortcutIsFound() {
        func entry(_ parameters: [Int], type: String = "modifier", enabled: Bool = true) -> [String: Any] {
            let value: [String: Any] = ["type": type, "parameters": parameters.map { NSNumber(value: $0) }]
            return ["164": ["enabled": enabled, "value": value] as [String: Any]]
        }
        let control = 262_144, command = 1_048_576
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([65535, 65535, control])) == HotkeyShortcut(.twice(keyCode: kVK_Control)))
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([control])) == HotkeyShortcut(.twice(keyCode: kVK_Control)))
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([65535, 65535, command])) == HotkeyShortcut(.twice(keyCode: kVK_Command)))
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([65535, 65535, command | 0x10])) == HotkeyShortcut(.twice(keyCode: kVK_Command)),
                "a right-⌘-only value still clashes with ⌘ ⌘, which either ⌘ fires")
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([65535, 65535, control], enabled: false)) == nil)
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([65535, 65535, 8_388_608])) == nil, "fn twice")
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: entry([65535, 65535, 0], type: "standard", enabled: false)) == nil,
                "this Mac's: off")
        #expect(SystemScreenshotShortcuts.dictationDoubleTap(in: [:]) == nil)
        #expect(SystemScreenshotShortcuts.dictationWarning(HotkeyShortcut(.twice(keyCode: kVK_Control)))
            == "⌃ ⌃ also starts macOS Dictation. Pick another shortcut, or change Dictation’s in System Settings › Keyboard › Dictation.")
    }

    // MARK: - Input Monitoring

    /// Round 2 (VM, 27.2.1): macOS applies a new Input Monitoring grant only when Sukusho next opens, so a grant this run
    /// can see but not use asks for a relaunch, not for the grant again.
    @Test func inputMonitoringAsksForWhatIsMissing() {
        #expect(InputMonitoringNeed.of(hasTapShortcuts: false, watching: false, granted: false) == .none)
        #expect(InputMonitoringNeed.of(hasTapShortcuts: true, watching: true, granted: false) == .none, "Accessibility can be enough")
        #expect(InputMonitoringNeed.of(hasTapShortcuts: true, watching: false, granted: false) == .grant)
        #expect(InputMonitoringNeed.of(hasTapShortcuts: true, watching: false, granted: true) == .relaunch)
    }

    // MARK: - Menus

    /// Round 2 (VM, 27.2.1): a subtitle given inside a Label never showed, so a shortcut the menu's shortcut column
    /// can't show goes after the title.
    @Test func aMenuTitleCarriesAShortcutItsColumnCantShow() {
        #expect(HotkeyShortcut.menuTitle("Capture Area", adding: HotkeyShortcut(.once(keyCode: kVK_RightOption)))
            == "Capture Area (Right ⌥)")
        #expect(HotkeyShortcut.menuTitle("Capture Window", adding: HotkeyShortcut(.twice(keyCode: kVK_Command)))
            == "Capture Window (⌘ ⌘)")
        #expect(HotkeyShortcut.menuTitle("Show Library", adding: chord([], kVK_F5)) == "Show Library (F5)")
        #expect(HotkeyShortcut.menuTitle("Capture Area", adding: nil) == "Capture Area")
    }

    // MARK: - Saved shortcuts

    @Test func shortcutsSavedByBeta1LoadUnchanged() throws {
        let defaults = suite()
        // Exactly as beta 1 writes them: ⌥⇧⌘U for Capture Text (an older rule allowed ⌥⇧ chords too), ⌥⇧A for Area.
        defaults.set(Data(#"{"modifiers":11,"keyCode":32}"#.utf8), forKey: CaptureHotkeyAction.textCapture.preferencesKey)
        defaults.set(Data(#"{"keyCode":0,"modifiers":10}"#.utf8), forKey: CaptureHotkeyAction.area.preferencesKey)
        CaptureHotkeyPreferences.saveShortcut(nil, for: .window, defaults: defaults)
        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)

        #expect(CaptureHotkeyPreferences.shortcut(for: .textCapture, defaults: defaults) == chord([.option, .shift, .command], kVK_ANSI_U))
        #expect(CaptureHotkeyPreferences.shortcut(for: .area, defaults: defaults) == chord([.option, .shift], kVK_ANSI_A))
        #expect(CaptureHotkeyPreferences.shortcut(for: .window, defaults: defaults) == nil)
        #expect(CaptureHotkeyPreferences.shortcut(for: .fullscreen, defaults: defaults) == CaptureHotkeyAction.fullscreen.defaultShortcut)
        #expect(CaptureHotkeyPreferences.shortcut(for: .textCapture, defaults: defaults)?.taps == nil)

        // Saved again, a key chord's JSON has beta 1's two keys and no others.
        CaptureHotkeyPreferences.saveShortcut(chord([.option], kVK_ANSI_1), for: .area, defaults: defaults)
        let data = try #require(defaults.data(forKey: CaptureHotkeyAction.area.preferencesKey))
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["modifiers", "keyCode"])
    }

    @Test func eachKindSavesAndLoads() {
        let defaults = suite()
        let kinds: [CaptureHotkeyAction: HotkeyShortcut] = [
            .area: HotkeyShortcut(.once(keyCode: kVK_RightOption)),
            .window: HotkeyShortcut(.twice(keyCode: kVK_Command)),
            .fullscreen: chord([], kVK_F5),
            .library: chord([.option], kVK_ANSI_1),
        ]
        for (action, shortcut) in kinds { CaptureHotkeyPreferences.saveShortcut(shortcut, for: action, defaults: defaults) }
        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        for (action, shortcut) in kinds {
            #expect(CaptureHotkeyPreferences.shortcut(for: action, defaults: defaults) == shortcut)
            #expect(!CaptureHotkeyPreferences.isDefault(action, defaults: defaults))
            CaptureHotkeyPreferences.resetToDefault(action, defaults: defaults)
            #expect(CaptureHotkeyPreferences.shortcut(for: action, defaults: defaults) == action.defaultShortcut)
        }
    }

    /// Sol's review, blocker 3: saved in this build, through beta 1's launch cleanup and back, every kind is still there,
    /// and beta 1 shows the kinds it can't read as None rather than taking their default.
    @Test func aTripThroughBeta1KeepsEveryKind() {
        let defaults = suite()
        let saved: [CaptureHotkeyAction: HotkeyShortcut?] = [
            .area: HotkeyShortcut(.once(keyCode: kVK_RightOption)),
            .window: HotkeyShortcut(.twice(keyCode: kVK_Command)),
            .library: chord([], kVK_F5),
            .fullscreen: chord([.command], kVK_ANSI_K),
            .textCapture: nil,
        ]
        for (action, shortcut) in saved { CaptureHotkeyPreferences.saveShortcut(shortcut, for: action, defaults: defaults) }

        Beta1CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        for action in [CaptureHotkeyAction.area, .window, .library, .textCapture] {
            #expect(Beta1CaptureHotkeyPreferences.shortcut(for: action, defaults: defaults) == nil, "\(action)")
        }
        #expect(Beta1CaptureHotkeyPreferences.shortcut(for: .fullscreen, defaults: defaults)
            == Beta1HotkeyShortcut(chord([.command], kVK_ANSI_K)))
        #expect(Beta1CaptureHotkeyPreferences.shortcut(for: .scrollingCapture, defaults: defaults)
            == CaptureHotkeyAction.scrollingCapture.beta1DefaultShortcut)

        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        for (action, shortcut) in saved {
            #expect(CaptureHotkeyPreferences.shortcut(for: action, defaults: defaults) == shortcut, "\(action)")
        }
        #expect(CaptureHotkeyPreferences.isDefault(.scrollingCapture, defaults: defaults))
    }

    /// A row beta 1 changes keeps beta 1's change: a shortcut recorded there, or Reset. Clear changes nothing, since beta 1
    /// already showed that row as None.
    @Test func aRowBeta1ChangesKeepsBeta1sChange() {
        let defaults = suite()
        CaptureHotkeyPreferences.saveShortcut(HotkeyShortcut(.once(keyCode: kVK_RightOption)), for: .area, defaults: defaults)
        CaptureHotkeyPreferences.saveShortcut(HotkeyShortcut(.twice(keyCode: kVK_Option)), for: .window, defaults: defaults)
        CaptureHotkeyPreferences.saveShortcut(chord([], kVK_F5), for: .library, defaults: defaults)

        Beta1CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        Beta1CaptureHotkeyPreferences.saveShortcut(Beta1HotkeyShortcut(chord([.command, .shift], kVK_ANSI_7)), for: .area, defaults: defaults)
        Beta1CaptureHotkeyPreferences.resetToDefault(.window, defaults: defaults)
        Beta1CaptureHotkeyPreferences.saveShortcut(nil, for: .library, defaults: defaults)

        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: .area, defaults: defaults) == chord([.command, .shift], kVK_ANSI_7))
        #expect(CaptureHotkeyPreferences.shortcut(for: .window, defaults: defaults) == CaptureHotkeyAction.window.defaultShortcut)
        #expect(CaptureHotkeyPreferences.isDefault(.window, defaults: defaults))
        #expect(CaptureHotkeyPreferences.shortcut(for: .library, defaults: defaults) == chord([], kVK_F5))
        // Cleared here later, the row stays cleared: no old tap comes back.
        CaptureHotkeyPreferences.saveShortcut(nil, for: .library, defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: .library, defaults: defaults) == nil)
    }

    /// Earlier builds of this branch (the Dev zips) kept a tap in the action's own key; the first launch of this build
    /// moves it, so a trip through beta 1 keeps it too.
    @Test func aTapAnEarlierBuildSavedMovesWhereBeta1CantLoseIt() {
        let defaults = suite()
        defaults.set(Data(#"{"modifiers":0,"keyCode":61,"taps":1}"#.utf8), forKey: CaptureHotkeyAction.area.preferencesKey)
        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        Beta1CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: .area, defaults: defaults) == HotkeyShortcut(.once(keyCode: kVK_RightOption)))
    }
}
