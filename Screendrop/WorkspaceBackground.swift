//
//  WorkspaceBackground.swift
//  Screendrop
//

import CoreGraphics
import Foundation
import ImageIO

/// What the Library's browser, the image editor and Studio draw behind their
/// content (Settings › General › Workspace). Screen only: no export, Copy,
/// upload or Agent Prompt path reads these settings.
nonisolated enum WorkspaceBackground {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case dots, plain, wallpaper

        var id: Self { self }
        var title: String {
            switch self {
            case .dots: "Dots"
            case .plain: "Plain"
            case .wallpaper: "Wallpaper"
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
