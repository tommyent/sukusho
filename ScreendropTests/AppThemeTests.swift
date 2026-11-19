import AppKit
import Testing

/// Settings › Appearance's slots and the built-in themes' own values (the theme plan's step 1).
struct AppThemeTests {
    @Test func aSlotDrawsItsChoiceOnlyWhenItExistsAndFits() {
        for theme in AppTheme.builtIns {
            #expect(AppTheme.named(theme.id, dark: theme.isDark) == theme)
            // A dark theme saved in the light slot, or the reverse, draws that slot's Classic.
            #expect(AppTheme.named(theme.id, dark: !theme.isDark) == (theme.isDark ? .classicLight : .classicDark))
        }
        for id in [nil, "", "no-such-theme"] as [String?] {
            #expect(AppTheme.named(id, dark: false) == .classicLight)
            #expect(AppTheme.named(id, dark: true) == .classicDark)
        }
        #expect(Set(AppTheme.builtIns.map(\.id)).count == AppTheme.builtIns.count)
        #expect(Set(AppTheme.builtIns.map(\.name)).count == AppTheme.builtIns.count)
        #expect(AppTheme.classicLight.card.paper == 0 && AppTheme.classicDark.card.paper == 0)
    }

    @Test func everyBuiltInHasALightAndADarkLook() {
        #expect(AppTheme.builtIns.contains { !$0.isDark } && AppTheme.builtIns.contains { $0.isDark })
    }

    /// The plan's bar for built-ins: text on what it's drawn on reads at 4.5:1.
    @Test func markInkReadsOnItsFill() throws {
        for theme in AppTheme.builtIns {
            let ratio = try contrast(theme.marks.ink, on: theme.marks.fill)
            #expect(ratio >= 4.5, "\(theme.id): \(ratio)")
        }
    }

    /// Chip (sd-ygmk): square and flat, the picture edge to edge at every slider size, the caption on its own 11 pt gutter.
    @Test func chipPicturesReachTheCardsEdges() {
        for theme in [AppTheme.chipLight, .chipDark] {
            #expect(theme.card.recipe.flatEdge != nil, "\(theme.id)")
            #expect(theme.card.gutter == 11)
            #expect(theme.card.paper == 0.35, "\(theme.id)")
            for width: CGFloat in [140, 192, 220, 320] {
                let density = LibraryCardDensity(width: width, inset: theme.card.inset, radius: theme.card.radius)
                #expect(density.pictureInset == 0 && density.cornerRadius == 0 && density.pictureRadius == 0, "\(theme.id) \(width)")
            }
        }
    }

    /// The owner, 2026-11-19: "I would keep the colours the same." Chip changes the card's shape only, so every colour it
    /// shares with Classic is Classic's: ink, chrome, ground, the face behind the label, the wells and the marks; and,
    /// "The chips are missing the shadow", Classic's drop shadow.
    @Test func chipKeepsClassicsColours() {
        for (chip, classic) in [(AppTheme.chipLight, AppTheme.classicLight), (.chipDark, .classicDark)] {
            #expect(chip.isDark == classic.isDark)
            #expect(chip.ink == classic.ink, "\(chip.id)")
            #expect(chip.chrome == classic.chrome, "\(chip.id)")
            #expect(chip.ground == classic.ground, "\(chip.id)")
            #expect(chip.marks == classic.marks, "\(chip.id)")
            #expect(chip.card.face == classic.card.face, "\(chip.id)")
            #expect(chip.card.well == classic.card.well, "\(chip.id)")
            #expect(chip.card.textWell == classic.card.textWell, "\(chip.id)")
            #expect(chip.card.shadow == classic.card.shadow && chip.card.pressedShadow == classic.card.pressedShadow, "\(chip.id)")
        }
    }

    /// Titles are drawn in the theme's ink on the card's face, top and bottom of its gradient.
    @Test func captionInkReadsOnEveryFace() throws {
        for theme in AppTheme.builtIns {
            for face in theme.card.face {
                let ratio = try contrast(theme.ink.primary, on: face)
                #expect(ratio >= 4.5, "\(theme.id): \(ratio)")
            }
        }
    }

    @Test func themeColoursKeepTheirHexValues() throws {
        let rgb = try #require(ThemeColor.rgb(0x1D9E4A).nsColor.usingColorSpace(.sRGB))
        #expect(Int((rgb.redComponent * 255).rounded()) == 0x1D)
        #expect(Int((rgb.greenComponent * 255).rounded()) == 0x9E)
        #expect(Int((rgb.blueComponent * 255).rounded()) == 0x4A)
        #expect(ThemeColor.rgb(0xFFFFFF, opacity: 0.5).nsColor.alphaComponent == 0.5)
    }

    /// WCAG's ratio, with a translucent colour laid over white first, as marks are over pictures.
    private func contrast(_ ink: ThemeColor, on fill: ThemeColor) throws -> Double {
        func luminance(_ colour: ThemeColor) throws -> Double {
            let c = try #require(colour.nsColor.usingColorSpace(.sRGB))
            func linear(_ v: CGFloat) -> Double {
                let v = Double(v) * Double(c.alphaComponent) + (1 - Double(c.alphaComponent))
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let (a, b) = (try luminance(ink), try luminance(fill))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
