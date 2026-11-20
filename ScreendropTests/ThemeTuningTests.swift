import AppKit
import Testing

/// The Theme Tuner's values (the owner's builds only; this target compiles them with THEME_TUNER). Pure: nothing here
/// touches the saved defaults, which other tests' theme lookups read in parallel.
struct ThemeTuningTests {
    @Test func untouchedValuesAreTheBuiltInChip() {
        var tuning = ThemeTuning()
        tuning.on = true
        // Reset's values lay Chip over itself exactly, and the copied lines are today's source lines.
        #expect(tuning.applied(to: .chipLight) == .chipLight)
        #expect(tuning.applied(to: .chipDark) == .chipDark)
        #expect(tuning.swift == """
            card.recipe = .flat(edge: .rgb(0x000000, opacity: 0.3))
            card.pictureEdge = .white(opacity: 0.35)
            card.shadow = classic.isDark ? 0.65 : 0.18
            card.shadowBlur = 1
            card.shadowOffset = 1
            card.paper = 0.35
            """)
    }

    @Test func tunedValuesReachOnlyChipAndOnlyWhileOn() {
        var tuning = ThemeTuning()
        tuning.dark.line = 0xD9D9D9
        tuning.dark.lineSolid = true
        tuning.light.edgeOpacity = 0.5
        tuning.light.shadowBlur = 1.5
        tuning.dark.paper = 0
        for theme in AppTheme.builtIns { #expect(tuning.applied(to: theme) == theme, "off: \(theme.id)") }
        tuning.on = true
        #expect(tuning.applied(to: .classicLight) == .classicLight && tuning.applied(to: .classicDark) == .classicDark)
        let dark = tuning.applied(to: .chipDark), light = tuning.applied(to: .chipLight)
        #expect(dark.card.pictureEdge == .rgb(0xD9D9D9) && dark.card.paper == 0)
        #expect(light.card.recipe.flatEdge == .rgb(0x000000, opacity: 0.5) && light.card.shadowBlur == 1.5)
        #expect(light.card.pictureEdge == AppTheme.chipLight.card.pictureEdge && light.card.paper == 0.35)
        // Light and Dark apart where they differ, in the form `chip(_:id:name:)` takes them.
        let lines = tuning.swift.split(separator: "\n")
        #expect(lines.contains("card.recipe = .flat(edge: classic.isDark ? .rgb(0x000000, opacity: 0.3) : .rgb(0x000000, opacity: 0.5))"))
        #expect(lines.contains("card.pictureEdge = classic.isDark ? .rgb(0xD9D9D9) : .white(opacity: 0.35)"))
        #expect(lines.contains("card.shadowBlur = classic.isDark ? 1 : 1.5"))
        #expect(lines.contains("card.paper = classic.isDark ? 0 : 0.35"))
    }

    @Test func savedValuesComeBackAndBadOnesReadAsBuiltIn() {
        var tuning = ThemeTuning()
        tuning.on = true
        tuning.light.line = 0xC4C4C4
        #expect(ThemeTuning(tuning.data) == tuning)
        #expect(ThemeTuning(nil) == ThemeTuning() && ThemeTuning(Data("{}".utf8)) == ThemeTuning())
    }

    @Test func pickedColoursKeepTheirHex() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0xD9D9D9, 0x1D9E4A, 0x777576] {
            #expect(ThemeTuning.hex(ThemeColor.rgb(hex).color) == hex, "\(String(hex, radix: 16))")
        }
    }
}
