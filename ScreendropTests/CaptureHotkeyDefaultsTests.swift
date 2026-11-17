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
        let changed = HotkeyShortcut(modifiers: [.command, .shift], keyCode: 31)
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
}
