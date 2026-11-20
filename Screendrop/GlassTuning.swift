#if THEME_TUNER
//
//  GlassTuning.swift
//  Screendrop
//
//  The Theme Tuner's Glass values: the frost's material, tint and rim, and the picture's blur and dim, Light and
//  Dark apart. Saved under their own tuner-only key, so Chip's saved
//  values are untouched, and laid over the built-in Glass only while on. Owner's builds only, as ThemeTuning.swift.
//

import Foundation
import Synchronization

nonisolated struct GlassTuning: Codable, Equatable, Sendable {
    nonisolated struct Side: Codable, Equatable, Sendable {
        var material: AppTheme.FrostMaterial
        /// Over the material, sRGB.
        var tint: UInt32
        var tintOpacity: Double
        /// The white hairline round each card.
        var rimOpacity: Double
        var blur: Double
        var dim: Double

        init(_ glass: AppTheme) {
            let frost = glass.card.recipe.frost, backdrop = glass.ground.backdrop
            let tint = ThemeTuning.split(frost?.tint)
            material = frost?.material ?? .regular
            self.tint = tint.hex; tintOpacity = tint.opacity
            rimOpacity = ThemeTuning.split(frost?.rim).opacity
            blur = backdrop?.blur ?? 0; dim = backdrop?.dim ?? 0
        }
    }

    var on = false
    var light = Side(.glassLight)
    var dark = Side(.glassDark)

    subscript(isDark isDark: Bool) -> Side {
        get { isDark ? dark : light }
        set { if isDark { dark = newValue } else { light = newValue } }
    }

    /// No dot, as ThemeTuning.key.
    static let key = "ThemeTunerGlassValues"

    /// Glass with the tuned values over it while the tuner is on; every other theme as it is.
    func applied(to theme: AppTheme) -> AppTheme {
        guard on, theme.id == AppTheme.glassLight.id || theme.id == AppTheme.glassDark.id,
              var frost = theme.card.recipe.frost, var backdrop = theme.ground.backdrop else { return theme }
        let side = self[isDark: theme.isDark]
        frost.material = side.material
        frost.tint = ThemeTuning.color(side.tint, side.tintOpacity)
        frost.rim = .white(opacity: side.rimOpacity)
        backdrop.blur = side.blur
        backdrop.dim = side.dim
        var tuned = theme
        tuned.card.recipe = .frost(frost)
        tuned.ground.backdrop = backdrop
        return tuned
    }

    /// The values as `AppTheme.glassLight` and `.glassDark`'s lines.
    var swift: String {
        func number(_ value: Double) -> String { String(format: "%g", value) }
        func lines(_ name: String, _ side: Side) -> String {
            let tint = side.tint == 0xFFFFFF ? ".white(opacity: \(number(side.tintOpacity)))"
                : ".rgb(\(String(format: "0x%06X", side.tint)), opacity: \(number(side.tintOpacity)))"
            return """
                // \(name)
                ground: Ground(workspace: …, backdrop: Backdrop(blur: \(number(side.blur)), dim: \(number(side.dim)))),
                card: Card(recipe: .frost(Frost(material: .\(side.material.rawValue), tint: \(tint), rim: .white(opacity: \(number(side.rimOpacity))))), …
                """
        }
        return lines("Glass Light", light) + "\n" + lines("Glass Dark", dark)
    }

    var data: Data? { try? JSONEncoder().encode(self) }

    /// The saved tuning, decoded once per change, readable on any thread.
    static var saved: GlassTuning {
        let data = UserDefaults.standard.data(forKey: key)
        return cache.withLock { cache in
            if cache.data != data { cache = (data, GlassTuning(data)) }
            return cache.tuning
        }
    }
    private static let cache = Mutex<(data: Data?, tuning: GlassTuning)>((nil, GlassTuning()))
}

nonisolated extension GlassTuning {
    /// Saved values, or the built-in ones when there are none or they no longer decode.
    init(_ data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(GlassTuning.self, from: $0) } ?? GlassTuning()
    }
}
#endif
