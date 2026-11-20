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
}
