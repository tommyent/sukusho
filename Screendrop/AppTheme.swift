//
//  AppTheme.swift
//  Screendrop
//
//  A theme is one look for Sukusho's own windows in one appearance: the
//  chrome's colours, the workspace ground, and how Library cards are drawn.
//  Settings › Appearance picks a theme for Light and one for Dark, and Mode
//  picks which appearance Sukusho's windows take. A theme sets values; its
//  card recipe is drawing code that ships with the app. Themes are screen
//  only: exports, copies, uploads and agent prompts never see them, and
//  recording red, annotation colours and system chrome stay as they are.
//

import AppKit
import SwiftUI

nonisolated struct AppTheme: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    var ink: Ink
    var chrome: Chrome
    var ground: Ground
    var card: Card
    var marks: Marks

    nonisolated struct Ink: Sendable, Equatable {
        /// Text and glyphs at full strength; Palette's label roles are opacities of it.
        var primary: ThemeColor
        /// Marks drawn on a solid `primary` fill.
        var inverse: ThemeColor
    }

    nonisolated struct Chrome: Sendable, Equatable {
        /// The one flat colour of the toolbar, the sidebar and the inspector (`WorkspaceChrome`).
        var background: ThemeColor
        /// The opaque background of inspectors and side panels (`Palette.panel`).
        var panel: ThemeColor
        /// Glass: the sidebar, inspector and toolbar show macOS's own glass over the theme's picture. `background` and
        /// `panel` stay opaque: Reduce Transparency and Increase Contrast draw them, and so do plates under text.
        var glass = false
    }

    nonisolated struct Ground: Sendable, Equatable {
        /// What the Library's cards and the editors' canvas sit on, under Dots, Plain or a wallpaper.
        var workspace: ThemeColor
        /// A picture under the whole window in place of the Workspace setting (Glass); nil: the Workspace setting.
        var backdrop: Backdrop? = nil
    }

    /// Glass's picture (`GlassPicture`): blurred by `blur` points, then `workspace` laid over it at `dim`. No text
    /// sits on it bare: the cards, rows, status bar and headings over it each have frost or a plate under their text.
    nonisolated struct Backdrop: Sendable, Equatable {
        var blur: Double
        var dim: Double
    }

    nonisolated struct Card: Sendable, Equatable {
        var recipe: Recipe
        /// Corner radius and picture inset on the 220 pt card. Classic's grow with wider cards.
        var radius: CGFloat
        var inset: CGFloat
        /// The caption's side margin from the card's edge, wherever the picture sits. nil: it follows the inset, one more
        /// inset in from the picture.
        var gutter: CGFloat?
        /// The face under the caption, top to bottom.
        var face: [ThemeColor]
        /// Behind a picture's transparent pixels.
        var well: ThemeColor
        /// Behind text, code and link clips.
        var textWell: ThemeColor
        /// The drop shadows' opacity at rest and while pressed; their offsets and blurs are the app's (`LibraryCardDepth`),
        /// scaled by `shadowBlur` and `shadowOffset`.
        var shadow: Double
        var pressedShadow: Double
        var shadowBlur = 1.0
        var shadowOffset = 1.0
        /// The strength of the paper grain over the caption strip, never the picture: the app's one tile
        /// (`CardPaperGrain`) at this opacity. 0: none.
        var paper = 0.0
        /// A 0.5 pt line along the picture's bottom edge, where it meets the caption. nil: none.
        var pictureEdge: ThemeColor? = nil
    }

    /// How a card is drawn. A theme picks one and tunes it; it can't add its own.
    nonisolated enum Recipe: Sendable, Equatable {
        /// Heavy stock: raised and rounded, two lips, two shadows, a bevelled picture (Classic).
        case stock(Stock)
        /// Square cut and flat: no lips or bevel, a hairline perimeter, the card's drop shadow (Chip).
        case flat(edge: ThemeColor)
        /// Frosted glass over the theme's picture: a standard material, never Liquid Glass (2.1 W against 0.75 W of GPU
        /// on m1 at 2x while scrolling, plan section 3), a tint over it and a light rim (Glass).
        case frost(Frost)

        /// The flat recipe's perimeter; nil for the stock card.
        var flatEdge: ThemeColor? { if case .flat(let edge) = self { edge } else { nil } }
        var frost: Frost? { if case .frost(let frost) = self { frost } else { nil } }
    }

    nonisolated struct Frost: Sendable, Equatable {
        var material: FrostMaterial
        /// Laid over the material: white lightens the frost, black deepens it.
        var tint: ThemeColor
        /// The hairline round the card, where light catches the glass's edge.
        var rim: ThemeColor
    }

    /// SwiftUI's standard materials, thinnest to thickest.
    nonisolated enum FrostMaterial: String, Sendable, Equatable, CaseIterable, Codable {
        case ultraThin, thin, regular, thick
        var title: String {
            switch self {
            case .ultraThin: "Ultra thin"
            case .thin: "Thin"
            case .regular: "Regular"
            case .thick: "Thick"
            }
        }
        var material: Material {
            switch self {
            case .ultraThin: .ultraThinMaterial
            case .thin: .thinMaterial
            case .regular: .regularMaterial
            case .thick: .thickMaterial
            }
        }
    }

    nonisolated struct Stock: Sendable, Equatable {
        var upperLip: ThemeColor
        var lowerLip: ThemeColor
        /// The light edge along the face's top.
        var gloss: ThemeColor
    }

    /// The pills and badges on pictures (`cardMark`).
    nonisolated struct Marks: Sendable, Equatable {
        var fill: ThemeColor
        var ink: ThemeColor
        /// A badge's glyph before it does anything, such as the cloud before sharing.
        var idle: ThemeColor
    }
}

// MARK: - Built-ins

nonisolated extension AppTheme {
    /// Beta 5's look, value for value: `scripts/check-classic-render.sh` holds it to the same pixels.
    static let classicLight = AppTheme(
        id: "classic-light", name: "Classic Light", isDark: false,
        ink: Ink(primary: .black, inverse: .white()),
        chrome: Chrome(background: .white(), panel: .white()),
        ground: Ground(workspace: .gray(0.93)),
        card: Card(recipe: .stock(Stock(upperLip: .rgb(0xD6D6DA), lowerLip: .rgb(0xBDBDC2), gloss: .white())),
                   radius: 16, inset: 6, gutter: nil, face: [.white(), .rgb(0xF7F7F8)],
                   well: .white(), textWell: .rgb(0xECEFF2), shadow: 0.18, pressedShadow: 0.12),
        marks: .classic)

    static let classicDark = AppTheme(
        id: "classic-dark", name: "Classic Dark", isDark: true,
        ink: Ink(primary: .white(), inverse: .black),
        chrome: Chrome(background: .windowBackground, panel: .windowBackground),
        ground: Ground(workspace: .gray(0.16)),
        card: Card(recipe: .stock(Stock(upperLip: .rgb(0x141414), lowerLip: .rgb(0x0A0A0A), gloss: .white(opacity: 0.16))),
                   radius: 16, inset: 6, gutter: nil, face: [.rgb(0x333335), .rgb(0x2B2B2D)],
                   well: .rgb(0x282627), textWell: .rgb(0x26282C), shadow: 0.65, pressedShadow: 0.5),
        marks: .classic)

    /// A colour chip: Classic cut square and flat, the picture above the label (owner's pick, 2026-11-19,
    /// sd-ygmk). Only the shape changes; the owner kept Classic's colours ("I would keep the colours the same") and
    /// its drop shadow ("The chips are missing the shadow"), added a subtle kraft grain to the paper only, and a border:
    /// a dark outer edge in both appearances with a line under the picture ("Yes, as read back"). The edge, the line and
    /// the paper are the owner's own values from the Theme Tuner, Light and Dark apart. Last, "padding top left and right
    /// of the image": the picture sits in from the card's top and sides, like a paint chip, its bottom on the label.
    static let chipLight = chip(classicLight, id: "chip-light", name: "Chip Light")
    static let chipDark = chip(classicDark, id: "chip-dark", name: "Chip Dark")

    /// Classic's colours in the flat recipe: square corners, the picture 8 pt in (Classic's inset is 6), the caption on its
    /// own 11 pt gutter, and a hairline perimeter (the mockup's strength, which is what sets a card without shadows off
    /// the ground).
    private static func chip(_ classic: AppTheme, id: String, name: String) -> AppTheme {
        var card = classic.card
        card.recipe = .flat(edge: classic.isDark ? .rgb(0x191919, opacity: 0.81) : .rgb(0x000000, opacity: 0.3))
        card.pictureEdge = classic.isDark ? .rgb(0x6D6F6F, opacity: 0.35) : .rgb(0xCBCBCB, opacity: 0.69)
        card.radius = 0
        card.inset = 8
        card.gutter = 11
        card.paper = classic.isDark ? 0.2 : 0.28
        return AppTheme(id: id, name: name, isDark: classic.isDark, ink: classic.ink, chrome: classic.chrome,
                        ground: classic.ground, card: card, marks: classic.marks)
    }

    /// Glass: a picture under the whole window (`GlassPicture`: the desktop picture when macOS lets Sukusho read it
    /// without asking, else Sukusho's own, or one the user picks), macOS's own glass on the sidebar, inspector and
    /// toolbar, and frosted cards. Classic's ink and marks; the opaque colours are Classic's too, for Reduce
    /// Transparency, Increase Contrast and the plates under text.
    static let glassLight = AppTheme(
        id: "glass-light", name: "Glass Light", isDark: false,
        ink: classicLight.ink,
        chrome: Chrome(background: .white(), panel: .white(), glass: true),
        ground: Ground(workspace: .gray(0.93), backdrop: Backdrop(blur: 30, dim: 0.1)),
        card: Card(recipe: .frost(Frost(material: .regular, tint: .white(opacity: 0.3), rim: .white(opacity: 0.55))),
                   radius: 16, inset: 6, gutter: nil, face: [.white(), .rgb(0xF7F7F8)],
                   well: .white(), textWell: .rgb(0xECEFF2), shadow: 0.12, pressedShadow: 0.08),
        marks: .classic)

    static let glassDark = AppTheme(
        id: "glass-dark", name: "Glass Dark", isDark: true,
        ink: classicDark.ink,
        chrome: Chrome(background: .windowBackground, panel: .windowBackground, glass: true),
        ground: Ground(workspace: .gray(0.16), backdrop: Backdrop(blur: 30, dim: 0.25)),
        card: Card(recipe: .frost(Frost(material: .regular, tint: .rgb(0x000000, opacity: 0.15), rim: .white(opacity: 0.16))),
                   radius: 16, inset: 6, gutter: nil, face: [.rgb(0x333335), .rgb(0x2B2B2D)],
                   well: .rgb(0x282627), textWell: .rgb(0x26282C), shadow: 0.4, pressedShadow: 0.3),
        marks: .classic)

    static let builtIns = [classicLight, classicDark, chipLight, chipDark, glassLight, glassDark]

    static let lightKey = "appTheme.light"
    static let darkKey = "appTheme.dark"

    /// The theme a slot draws: the one chosen if it exists and fits the slot, else Classic.
    static func named(_ id: String?, dark: Bool) -> AppTheme {
        let theme = builtIns.first { $0.id == id && $0.isDark == dark } ?? (dark ? classicDark : classicLight)
        #if THEME_TUNER
        return GlassTuning.saved.applied(to: ThemeTuning.saved.applied(to: theme))
        #else
        return theme
        #endif
    }

    /// The theme for an appearance as saved, readable from any thread: AppKit resolves dynamic colours off the main one.
    static func current(dark: Bool) -> AppTheme {
        named(UserDefaults.standard.string(forKey: dark ? darkKey : lightKey), dark: dark)
    }

    static func current(for appearance: NSAppearance) -> AppTheme {
        current(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// Glass's picture, while it's drawn: Reduce Transparency and Increase Contrast take every Glass surface (the
    /// picture, the sidebar, inspector and toolbar glass, the frost, the popup) to its opaque colours instead.
    func drawnBackdrop(reduceTransparency: Bool, increaseContrast: Bool) -> Backdrop? {
        chrome.glass && !reduceTransparency && !increaseContrast ? ground.backdrop : nil
    }
}

nonisolated extension AppTheme.Marks {
    static let classic = AppTheme.Marks(fill: .white(opacity: 0.94), ink: .rgb(0x1D1D1F), idle: .rgb(0x48484A))
}

// MARK: - Colours

/// A theme's colour, kept in the form the drawing code always used, so Classic's pixels can't drift: AppKit's
/// `NSColor(white:)` and SwiftUI's `Color(white:)` are different greys, and so are `.white` and an sRGB white.
nonisolated enum ThemeColor: Sendable, Equatable {
    /// sRGB, 0xRRGGBB.
    case rgb(UInt32, opacity: Double = 1)
    case gray(Double)
    case white(opacity: Double = 1)
    case black
    /// macOS's window background, which picks up the desktop picture's tint when the Mac allows it.
    case windowBackground

    var color: Color {
        switch self {
        case .rgb(let hex, let opacity):
            let rgb = Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
            return opacity == 1 ? rgb : rgb.opacity(opacity)
        case .gray(let white): return Color(white: white)
        case .white(let opacity): return opacity == 1 ? .white : .white.opacity(opacity)
        case .black: return .black
        case .windowBackground: return Color(nsColor: .windowBackgroundColor)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .rgb(let hex, let opacity):
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: opacity)
        case .gray(let white): return NSColor(white: white, alpha: 1)
        case .white(let opacity): return opacity == 1 ? .white : .white.withAlphaComponent(opacity)
        case .black: return .black
        case .windowBackground: return .windowBackgroundColor
        }
    }
}

// MARK: - Views

/// The theme drawn in a view's appearance. A view reading it redraws when Settings › Appearance changes a slot.
@propertyWrapper struct CurrentTheme: DynamicProperty {
    @AppStorage(AppTheme.lightKey) private var light = AppTheme.classicLight.id
    @AppStorage(AppTheme.darkKey) private var dark = AppTheme.classicDark.id
    @Environment(\.colorScheme) private var scheme
    #if THEME_TUNER
    @AppStorage(ThemeTuning.key) private var tuning: Data?
    @AppStorage(GlassTuning.key) private var glassTuning: Data?
    #endif

    var wrappedValue: AppTheme {
        #if THEME_TUNER
        _ = (tuning, glassTuning)   // so every card redraws as the tuner moves
        #endif
        return scheme == .dark ? AppTheme.named(dark, dark: true) : AppTheme.named(light, dark: false)
    }
}

/// The current theme's Glass picture while it's drawn (`AppTheme.drawnBackdrop`); nil for every other theme, and for
/// Glass under Reduce Transparency or Increase Contrast, where its surfaces draw their opaque colours.
@propertyWrapper struct DrawnGlass: DynamicProperty {
    @CurrentTheme private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var wrappedValue: AppTheme.Backdrop? {
        theme.drawnBackdrop(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
    }
}
