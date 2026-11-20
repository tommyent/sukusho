//
//  GlassPicture.swift
//  Screendrop
//
//  Glass's picture, painted under the whole window (`AppTheme.Ground.backdrop`). The default is the Mac's desktop
//  picture, but only when it is one of Apple's own (under /System or /Library), which Sukusho reads without a
//  folder-access prompt; anywhere else, and while it can't be read, Sukusho's own picture for the appearance. A
//  picture the user picks in Settings › Appearance is copied into Sukusho's wallpapers folder first
//  (`AnnotationWallpaperStore.importWallpaper`), so it stays when the original moves. Screen only, like every theme.
//

import AppKit
import ImageIO
import Synchronization

enum GlassPicture {
    /// The picked picture's path; empty: the desktop picture or Sukusho's own. No dot: @AppStorage misses dotted keys.
    static let pathKey = "GlassPicturePath"

    /// The picture to paint: the picked one while it exists, else the default for the appearance.
    static func url(picked path: String, dark: Bool) -> URL {
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return desktopPicture() ?? ownPicture(dark: dark)
    }

    /// The main screen's desktop picture when it's Apple's own and still there.
    static func desktopPicture() -> URL? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              readsWithoutPrompt(url), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Apple's own pictures live under /System and /Library; a protected folder such as Downloads or Desktop would
    /// ask the user first, so those fall back to Sukusho's own.
    nonisolated static func readsWithoutPrompt(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/")
    }

    static func ownPicture(dark: Bool) -> URL {
        // Bundled by scripts/make-glass-pictures.swift; a bundle without them would be a broken build.
        Bundle.main.url(forResource: dark ? "GlassDark" : "GlassLight", withExtension: "heic")
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    }

    /// Whether text drawn straight on the picture is light: the backdrop's choice, or for auto the appearance's own
    /// unless that reads under 4.5:1 on the picture as drawn (its mean, `dim` of the ground over it) and light or dark
    /// text, whichever the appearance doesn't use, reads better.
    nonisolated static func lightInk(_ backdrop: AppTheme.Backdrop, picture url: URL, ground: ThemeColor, dark: Bool) -> Bool {
        switch backdrop.ink {
        case .light: return true
        case .dark: return false
        case .auto:
            guard let mean = meanLuminance(url) else { return dark }
            let shown = mean * (1 - backdrop.dim) + luminance(ground.nsColor) * backdrop.dim
            let onWhite = 1.05 / (shown + 0.05), onDark = (shown + 0.05) / (luminance(darkInk) + 0.05)
            let own = dark ? onWhite : onDark, other = dark ? onDark : onWhite
            return own < 4.5 && other > own ? !dark : dark
        }
    }

    /// Near-black, as Classic's ink reads on a light picture once antialiased; white is the other.
    nonisolated private static let darkInk = NSColor(srgbRed: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255, alpha: 1)

    /// A picture's mean relative luminance from a 32-pixel thumbnail, kept per file.
    nonisolated static func meanLuminance(_ url: URL) -> Double? {
        if let known = luminances.withLock({ $0[url] }) { return known }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              image.width > 0, image.height > 0 else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let count = image.width * image.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var sum = 0.0
        for pixel in 0..<count {
            sum += 0.2126 * linear(bytes[pixel * 4]) + 0.7152 * linear(bytes[pixel * 4 + 1]) + 0.0722 * linear(bytes[pixel * 4 + 2])
        }
        let mean = sum / Double(count)
        luminances.withLock { $0[url] = mean }
        return mean
    }

    nonisolated private static let luminances = Mutex<[URL: Double]>([:])

    nonisolated private static func linear(_ byte: UInt8) -> Double { linear(Double(byte) / 255) }

    nonisolated private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    nonisolated static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * linear(Double(c.redComponent)) + 0.7152 * linear(Double(c.greenComponent))
            + 0.0722 * linear(Double(c.blueComponent))
    }
}
