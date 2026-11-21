//
//  WorkspaceBackground.swift
//  Screendrop
//

import AppKit
import Observation
import CoreGraphics
import Foundation
import ImageIO

/// What the Library's browser, the image editor and Studio draw behind their
/// content (Settings › Appearance › Workspace). Screen only: no export, Copy,
/// upload or Agent Prompt path reads these settings.
nonisolated enum WorkspaceBackground {
    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case dots, plain, wallpaper

        var id: Self { self }
        var title: String {
            switch self {
            case .dots: "Dots"
            case .plain: "Solid Color"
            case .wallpaper: "Picture"
            }
        }
    }

    static let styleKey = "workspaceBackground.style"
    static let wallpaperPathKey = "workspaceBackground.wallpaperPath"
    static let dimKey = "workspaceBackground.dim"
    static let blurKey = "workspaceBackground.blur"

    static let defaultDim = 0.3
    static let dimRange = 0.0...0.8
    /// In points. A blurred photo decodes at a quarter of the window's pixels,
    /// since the blur hides that detail anyway.
    static let blurRadius: CGFloat = 24
    private static let blurredDecodeDivisor: CGFloat = 4
    /// Window sizes are rounded up to this many pixels, so a resize decodes
    /// again only every few hundred pixels.
    private static let sizeStep: CGFloat = 256

    /// Reduce Transparency and Increase Contrast get the flat grey instead
    /// of a photo; Dots and Plain draw as chosen.
    static func shown(_ style: Style, reduceTransparency: Bool, increaseContrast: Bool) -> Style {
        style == .wallpaper && (reduceTransparency || increaseContrast) ? .plain : style
    }

    /// How opaque the workspace grey is over the photo. Dark mode fades half
    /// as much again: a bright photo next to dark chrome glares more than a
    /// dark photo next to light chrome.
    static func dimOpacity(_ dim: Double, dark: Bool) -> Double {
        let dim = min(max(dim, dimRange.lowerBound), dimRange.upperBound)
        return dark ? min(0.9, dim * 1.5) : dim
    }

    /// A window's pixel size rounded up to the next step.
    static func bucketed(_ size: CGSize) -> CGSize {
        CGSize(width: (max(1, size.width) / sizeStep).rounded(.up) * sizeStep,
               height: (max(1, size.height) / sizeStep).rounded(.up) * sizeStep)
    }

    /// The longest side, in pixels, to decode an `image`-sized photo at so it
    /// still covers `bounds` when scaled to fill. Never more than the photo
    /// has; a quarter of that when blurred.
    static func decodeSize(image: CGSize, bounds: CGSize, blurred: Bool) -> Int {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return 0 }
        let scale = min(1, max(bounds.width / image.width, bounds.height / image.height))
        let longest = max(image.width, image.height) * scale / (blurred ? blurredDecodeDivisor : 1)
        return max(1, Int(longest.rounded(.up)))
    }

    /// A photo's pixel size as shown, with EXIF rotation applied, read from its
    /// header without decoding it. Nil when the file is gone or isn't an image.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 turn the photo a quarter.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}

enum BackgroundDestination: String, CaseIterable, Identifiable {
    case app = "App Windows", editors = "Editors"
    var id: Self { self }
}

struct BackgroundChoice: Codable, Equatable {
    var style: WorkspaceBackground.Style = .dots
    var picture = ""
    var solidRGB: UInt32?
    var dim = WorkspaceBackground.defaultDim
    var blur = false
    var usesGlassDimDefault: Bool?

    func pictureEffects(for destination: BackgroundDestination, theme: AppTheme) -> AppTheme.Backdrop {
        let glass = destination == .app ? theme.ground.backdrop : nil
        let radius = glass?.blur ?? WorkspaceBackground.blurRadius
        return AppTheme.Backdrop(blur: blur ? radius : 0,
                                 dim: usesGlassDimDefault == true ? glass?.dim ?? dim : dim)
    }

    var needsTextBacking: Bool { style == .wallpaper || (style == .plain && solidRGB != nil) }
}

struct DestinationBackgrounds: Codable, Equatable {
    var day: BackgroundChoice
    var night: BackgroundChoice
    var usesNight = false

    init(day: BackgroundChoice) {
        self.day = day
        night = day
    }
}

struct BackgroundPreferences: Codable, Equatable {
    var app: DestinationBackgrounds
    var editors: DestinationBackgrounds
    private var appFollowsTheme: Bool?
    var dayStart = 7 * 60
    var nightStart = 19 * 60

    subscript(destination: BackgroundDestination) -> DestinationBackgrounds {
        get { destination == .app ? app : editors }
        set {
            if destination == .app {
                app = newValue
                appFollowsTheme = nil
            } else {
                editors = newValue
            }
        }
    }

    func backgrounds(for destination: BackgroundDestination, theme: AppTheme) -> DestinationBackgrounds {
        if destination == .app, appFollowsTheme == true, let backdrop = theme.ground.backdrop {
            return DestinationBackgrounds(day: Self.glassChoice(backdrop))
        }
        return self[destination]
    }

    func isNight(at minute: Int) -> Bool {
        if nightStart > dayStart { return minute >= nightStart || minute < dayStart }
        return minute >= nightStart && minute < dayStart
    }

    init(migrating defaults: UserDefaults) {
        var editor = BackgroundChoice(
            style: defaults.string(forKey: WorkspaceBackground.styleKey).flatMap(WorkspaceBackground.Style.init) ?? .dots,
            picture: defaults.string(forKey: WorkspaceBackground.wallpaperPathKey) ?? "",
            dim: defaults.object(forKey: WorkspaceBackground.dimKey) as? Double ?? WorkspaceBackground.defaultDim,
            blur: defaults.bool(forKey: WorkspaceBackground.blurKey)
        )
        if editor.style == .wallpaper && editor.picture.isEmpty { editor.style = .dots }
        editors = DestinationBackgrounds(day: editor)
        let light = AppTheme.named(defaults.string(forKey: AppTheme.lightKey), dark: false)
        let dark = AppTheme.named(defaults.string(forKey: AppTheme.darkKey), dark: true)
        let savedBackdrop = light.ground.backdrop ?? dark.ground.backdrop
        let hasGlassSettings = defaults.object(forKey: GlassPicture.pathKey) != nil
            || defaults.object(forKey: GlassPicture.solidBackgroundKey) != nil
        if let backdrop = savedBackdrop ?? (hasGlassSettings ? AppTheme.glassLight.ground.backdrop : nil) {
            var choice = Self.glassChoice(backdrop)
            if defaults.bool(forKey: GlassPicture.solidBackgroundKey) { choice.style = .plain }
            choice.picture = defaults.string(forKey: GlassPicture.pathKey) ?? ""
            app = DestinationBackgrounds(day: choice)
        } else {
            app = editors
            appFollowsTheme = true
        }
    }

    private static func glassChoice(_ backdrop: AppTheme.Backdrop) -> BackgroundChoice {
        BackgroundChoice(style: .wallpaper, dim: backdrop.dim, blur: backdrop.blur > 0, usesGlassDimDefault: true)
    }
}

@MainActor @Observable final class WindowBackgroundStore {
    static let shared = WindowBackgroundStore()
    static let key = "WindowBackgroundPreferencesV1"
    var preferences: BackgroundPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: Self.key) }
            if oldValue.dayStart != preferences.dayStart || oldValue.nightStart != preferences.nightStart ||
                oldValue.app.usesNight != preferences.app.usesNight || oldValue.editors.usesNight != preferences.editors.usesNight {
                refreshClock()
            }
        }
    }
    private(set) var isNight = false
    @ObservationIgnored private var timer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(BackgroundPreferences.self, from: data) {
            preferences = saved
        } else {
            preferences = BackgroundPreferences(migrating: defaults)
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
        }
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshClock() }
            }
        }
        refreshClock()
    }

    func choice(for destination: BackgroundDestination, theme: AppTheme) -> BackgroundChoice {
        let choices = preferences.backgrounds(for: destination, theme: theme)
        return choices.usesNight && isNight ? choices.night : choices.day
    }

    private func refreshClock() {
        timer?.invalidate()
        let now = Date(), calendar = Calendar.current
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        isNight = preferences.isNight(at: minute)
        guard preferences.app.usesNight || preferences.editors.usesNight else { return }
        let next = [preferences.dayStart, preferences.nightStart].compactMap { minute in
            calendar.nextDate(after: now, matching: DateComponents(hour: minute / 60, minute: minute % 60),
                              matchingPolicy: .nextTime)
        }.min()
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClock() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
