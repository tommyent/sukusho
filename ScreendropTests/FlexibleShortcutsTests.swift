import AppKit
import Carbon.HIToolbox
import Testing

/// The owner, 2026-11-17 (beta 1): "You should not be required to use three keys." Any modifier with a key, and a
/// function key alone, are shortcuts now.
struct FlexibleShortcutsTests {
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

        // Saved again, a key chord's JSON has beta 1's two keys and no others.
        CaptureHotkeyPreferences.saveShortcut(chord([.option], kVK_ANSI_1), for: .area, defaults: defaults)
        let data = try #require(defaults.data(forKey: CaptureHotkeyAction.area.preferencesKey))
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["modifiers", "keyCode"])
    }

    @Test func eachKindSavesAndLoads() {
        let defaults = suite()
        let kinds: [CaptureHotkeyAction: HotkeyShortcut] = [
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

    /// Going back to beta 1: it reads a function key's JSON as a shortcut with no modifiers, which it treats as invalid, so the
    /// action falls back to its default rather than to a key alone.
    @Test func beta1ReadsANewShortcutAsNoShortcut() throws {
        struct Beta1Shortcut: Decodable { let modifiers: Int; let keyCode: Int }
        for shortcut in [chord([], kVK_F5)] {
            let old = try JSONDecoder().decode(Beta1Shortcut.self, from: try JSONEncoder().encode(shortcut))
            #expect(old.modifiers == 0)
        }
    }
}
