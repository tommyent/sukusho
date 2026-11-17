import Foundation
import Testing

/// Owner, 2026-11-17: Settings › Shortcuts showed Reset on rows already at their default, because an older build had
/// stored the default itself.
struct CaptureHotkeyDefaultsTests {
    private func suite() -> UserDefaults {
        let name = "CaptureHotkeyDefaultsTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func aStoredDefaultIsTheDefaultAndIsDroppedAtLaunch() throws {
        let defaults = suite()
        // As the older build stored them on the owner's Air: Fullscreen at its own default, Capture Text changed.
        let fullscreen = try JSONEncoder().encode(CaptureHotkeyAction.fullscreen.defaultShortcut)
        defaults.set(fullscreen, forKey: CaptureHotkeyAction.fullscreen.preferencesKey)
        let changed = HotkeyShortcut(modifiers: [.command, .shift], keyCode: 32)   // ⇧⌘U, not any default
        defaults.set(try JSONEncoder().encode(changed), forKey: CaptureHotkeyAction.textCapture.preferencesKey)
        CaptureHotkeyPreferences.saveShortcut(nil, for: .window, defaults: defaults)

        #expect(CaptureHotkeyPreferences.isDefault(.fullscreen, defaults: defaults))
        #expect(!CaptureHotkeyPreferences.isDefault(.textCapture, defaults: defaults))
        #expect(!CaptureHotkeyPreferences.isDefault(.window, defaults: defaults), "a cleared shortcut isn't the default")
        #expect(CaptureHotkeyPreferences.isDefault(.library, defaults: defaults))

        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        #expect(defaults.object(forKey: CaptureHotkeyAction.fullscreen.preferencesKey) == nil)
        #expect(CaptureHotkeyPreferences.shortcut(for: .textCapture, defaults: defaults) == changed)
        #expect(CaptureHotkeyPreferences.shortcut(for: .window, defaults: defaults) == nil)

        // Restore Defaults leaves every row at its default.
        for action in CaptureHotkeyAction.allCases { CaptureHotkeyPreferences.resetToDefault(action, defaults: defaults) }
        #expect(CaptureHotkeyAction.allCases.allSatisfy { CaptureHotkeyPreferences.isDefault($0, defaults: defaults) })
    }

    /// Beta 1 changed two defaults (the owner's set): Recording ⇧⌘6 → ⇧⌘5, Capture Text ⇧⌘5 → ⇧⌘O. The old defaults an
    /// older build stored are forgotten, so they follow the new ones instead of colliding on ⇧⌘5; a shortcut someone
    /// chose stays.
    @Test func theOldDefaultsAnOlderBuildStoredFollowTheNewOnes() throws {
        let defaults = suite()
        let shift5 = HotkeyShortcut(modifiers: [.command, .shift], keyCode: 23)
        let shift6 = HotkeyShortcut(modifiers: [.command, .shift], keyCode: 22)
        defaults.set(try JSONEncoder().encode(shift5), forKey: CaptureHotkeyAction.textCapture.preferencesKey)
        defaults.set(try JSONEncoder().encode(shift6), forKey: CaptureHotkeyAction.screenRecording.preferencesKey)
        // Area on ⇧⌘6 by choice: not an old default for Area, so it stays.
        defaults.set(try JSONEncoder().encode(shift6), forKey: CaptureHotkeyAction.area.preferencesKey)

        CaptureHotkeyPreferences.dropStoredDefaults(defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: .textCapture, defaults: defaults) == CaptureHotkeyAction.textCapture.defaultShortcut)
        #expect(CaptureHotkeyPreferences.shortcut(for: .screenRecording, defaults: defaults) == shift5)
        #expect(CaptureHotkeyPreferences.shortcut(for: .area, defaults: defaults) == shift6)
    }
}
