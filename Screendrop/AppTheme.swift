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
    }

    nonisolated struct Ground: Sendable, Equatable {
        /// What the Library's cards and the editors' canvas sit on, under Dots, Plain or a wallpaper.
        var workspace: ThemeColor
    }

    nonisolated struct Card: Sendable, Equatable {
        var recipe: Recipe
        /// Corner radius and picture inset on the 220 pt card. Classic's grow with wider cards.
        var radius: CGFloat
        var inset: CGFloat
        /// The caption's side margin. nil: it follows the inset, one more inset in from the card's edge.
        var gutter: CGFloat?
        /// The face under the caption, top to bottom.
        var face: [ThemeColor]
        /// Behind a picture's transparent pixels.
        var well: ThemeColor
        /// Behind text, code and link clips.
        var textWell: ThemeColor
    }

    /// How a card is drawn. A theme picks one and tunes it; it can't add its own.
    nonisolated enum Recipe: Sendable, Equatable {
        /// Heavy stock: raised and rounded, two lips, two shadows, a bevelled picture (Classic).
        case stock(Stock)
    }

    nonisolated struct Stock: Sendable, Equatable {
        var upperLip: ThemeColor
        var lowerLip: ThemeColor
        /// The light edge along the face's top.
        var gloss: ThemeColor
        /// The shadows' opacity at rest and while pressed.
        var shadow: Double
        var pressedShadow: Double
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
        card: Card(recipe: .stock(Stock(upperLip: .rgb(0xD6D6DA), lowerLip: .rgb(0xBDBDC2), gloss: .white(),
                                        shadow: 0.18, pressedShadow: 0.12)),
                   radius: 16, inset: 6, gutter: nil, face: [.white(), .rgb(0xF7F7F8)],
                   well: .white(), textWell: .rgb(0xECEFF2)),
        marks: .classic)

    static let classicDark = AppTheme(
        id: "classic-dark", name: "Classic Dark", isDark: true,
        ink: Ink(primary: .white(), inverse: .black),
        chrome: Chrome(background: .windowBackground, panel: .windowBackground),
        ground: Ground(workspace: .gray(0.16)),
        card: Card(recipe: .stock(Stock(upperLip: .rgb(0x141414), lowerLip: .rgb(0x0A0A0A), gloss: .white(opacity: 0.16),
                                        shadow: 0.65, pressedShadow: 0.5)),
                   radius: 16, inset: 6, gutter: nil, face: [.rgb(0x333335), .rgb(0x2B2B2D)],
                   well: .rgb(0x282627), textWell: .rgb(0x26282C)),
        marks: .classic)

    static let builtIns = [classicLight, classicDark]

    static let lightKey = "appTheme.light"
    static let darkKey = "appTheme.dark"

    /// The theme a slot draws: the one chosen if it exists and fits the slot, else Classic.
    static func named(_ id: String?, dark: Bool) -> AppTheme {
        builtIns.first { $0.id == id && $0.isDark == dark } ?? (dark ? classicDark : classicLight)
    }

    /// The theme for an appearance as saved, readable from any thread: AppKit resolves dynamic colours off the main one.
    static func current(dark: Bool) -> AppTheme {
        named(UserDefaults.standard.string(forKey: dark ? darkKey : lightKey), dark: dark)
    }

    static func current(for appearance: NSAppearance) -> AppTheme {
        current(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
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

    var wrappedValue: AppTheme {
        scheme == .dark ? AppTheme.named(dark, dark: true) : AppTheme.named(light, dark: false)
    }
}
