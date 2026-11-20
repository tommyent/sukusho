#if THEME_TUNER
//
//  ThemeTuning.swift
//  Screendrop
//
//  The Theme Tuner's values: Chip's line under the picture, outer edge, shadow and paper, Light and Dark apart,
//  saved under one tuner-only key and laid over the built-in Chip only while the tuner is on. Only the owner's own
//  builds have it: `PERSONAL=1 scripts/release.sh` sets THEME_TUNER (through PERSONAL_CONDITIONS), a release never
//  does, and scripts/check-theme-tuner.sh fails either build whose binary disagrees.
//

import AppKit
import Synchronization
import SwiftUI

nonisolated struct ThemeTuning: Codable, Equatable, Sendable {
    nonisolated struct Side: Codable, Equatable, Sendable {
        /// The line under the picture, sRGB. Solid draws it opaque, the same colour over every picture.
        var line: UInt32
        var lineOpacity: Double
        var lineSolid = false
        /// The picture's inset from the card's top and sides on the 220 pt card; wider cards grow it.
        var inset: Double
        /// The card's outer edge.
        var edge: UInt32
        var edgeOpacity: Double
        /// The drop shadows' opacity at rest, and how much their blur and offset are scaled.
        var shadow: Double
        var shadowBlur: Double
        var shadowOffset: Double
        var paper: Double

        init(_ chip: AppTheme) {
            let line = ThemeTuning.split(chip.card.pictureEdge), edge = ThemeTuning.split(chip.card.recipe.flatEdge)
            self.line = line.hex; lineOpacity = line.opacity
            self.edge = edge.hex; edgeOpacity = edge.opacity
            inset = chip.card.inset
            shadow = chip.card.shadow; shadowBlur = chip.card.shadowBlur; shadowOffset = chip.card.shadowOffset
            paper = chip.card.paper
        }
    }

    var on = false
    var light = Side(.chipLight)
    var dark = Side(.chipDark)

    subscript(isDark isDark: Bool) -> Side {
        get { isDark ? dark : light }
        set { if isDark { dark = newValue } else { light = newValue } }
    }

    /// No dot: @AppStorage didn't redraw the Library's cards for "ThemeTuner.chipValues" (seen on m1). Also
    /// check-theme-tuner.sh's probe for the tuner in a binary: 16 bytes or more, so it's a C string there.
    static let key = "ThemeTunerChipValues"

    /// Chip with the tuned values over it while the tuner is on; every other theme as it is.
    func applied(to theme: AppTheme) -> AppTheme {
        guard on, theme.id == AppTheme.chipLight.id || theme.id == AppTheme.chipDark.id else { return theme }
        let side = self[isDark: theme.isDark]
        var tuned = theme
        tuned.card.recipe = .flat(edge: Self.color(side.edge, side.edgeOpacity))
        tuned.card.pictureEdge = Self.color(side.line, side.lineSolid ? 1 : side.lineOpacity)
        tuned.card.inset = side.inset
        tuned.card.shadow = side.shadow
        tuned.card.shadowBlur = side.shadowBlur
        tuned.card.shadowOffset = side.shadowOffset
        tuned.card.paper = side.paper
        return tuned
    }

    /// The values as `AppTheme.chip`'s lines, Light and Dark folded into one where they agree.
    var swift: String {
        func both(_ value: (Side) -> String) -> String {
            let inLight = value(self.light), inDark = value(self.dark)
            return inLight == inDark ? inLight : "classic.isDark ? \(inDark) : \(inLight)"
        }
        func number(_ value: Double) -> String { String(format: "%g", value) }
        func code(_ hex: UInt32, _ opacity: Double) -> String {
            let shown = opacity == 1 ? "" : "opacity: \(number(opacity))"
            if hex == 0xFFFFFF { return ".white(\(shown))" }
            return ".rgb(\(String(format: "0x%06X", hex))\(shown.isEmpty ? "" : ", " + shown))"
        }
        return """
            card.recipe = .flat(edge: \(both { code($0.edge, $0.edgeOpacity) }))
            card.pictureEdge = \(both { code($0.line, $0.lineSolid ? 1 : $0.lineOpacity) })
            card.inset = \(both { number($0.inset) })
            card.shadow = \(both { number($0.shadow) })
            card.shadowBlur = \(both { number($0.shadowBlur) })
            card.shadowOffset = \(both { number($0.shadowOffset) })
            card.paper = \(both { number($0.paper) })
            """
    }

    // MARK: - Saved

    var data: Data? { try? JSONEncoder().encode(self) }

    /// The saved tuning, decoded once per change: every card's theme lookup reads it, on any thread.
    static var saved: ThemeTuning {
        let data = UserDefaults.standard.data(forKey: key)
        return cache.withLock { cache in
            if cache.data != data { cache = (data, ThemeTuning(data)) }
            return cache.tuning
        }
    }
    private static let cache = Mutex<(data: Data?, tuning: ThemeTuning)>((nil, ThemeTuning()))

    // MARK: - Colours

    /// A theme colour as sRGB hex and opacity; no line reads as white at 0.
    static func split(_ color: ThemeColor?) -> (hex: UInt32, opacity: Double) {
        switch color {
        case .rgb(let hex, let opacity): (hex, opacity)
        case .white(let opacity): (0xFFFFFF, opacity)
        case .black: (0, 1)
        default: (0xFFFFFF, 0)
        }
    }

    /// White stays `.white`, as the built-ins write it, so untouched values give back the built-in theme exactly.
    static func color(_ hex: UInt32, _ opacity: Double) -> ThemeColor {
        hex == 0xFFFFFF ? .white(opacity: opacity) : .rgb(hex, opacity: opacity)
    }

    /// A picked colour as sRGB hex; the colour panel can hand back any colour space.
    static func hex(_ color: Color) -> UInt32 {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(srgb.redComponent) << 16 | byte(srgb.greenComponent) << 8 | byte(srgb.blueComponent)
    }
}

nonisolated extension ThemeTuning {
    /// Saved values, or the built-in ones when there are none or they no longer decode.
    init(_ data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(ThemeTuning.self, from: $0) } ?? ThemeTuning()
    }
}
#endif
