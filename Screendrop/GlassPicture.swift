//
//  GlassPicture.swift
//  Screendrop
//
//  Glass's picture, painted under the whole window (`AppTheme.Ground.backdrop`): the one the user picked in
//  Settings › Appearance, else the desktop picture of the window's own screen when it's one of Apple's own (which
//  Sukusho reads without a folder-access prompt), else Sukusho's own for the appearance; the first of those that
//  decodes. A picked picture is copied into Sukusho's wallpapers folder first (`AnnotationWallpaperStore.importWallpaper`),
//  so it stays when the original moves. Screen only, like every theme.
//

import AppKit
import ImageIO
import Synchronization

enum GlassPicture {
    /// The picked picture's path; empty: the desktop picture or Sukusho's own. No dot: @AppStorage misses dotted keys.
    static let pathKey = "GlassPicturePath"

    /// The picture to paint: the first of the picked one, the desktop picture (Apple's own only, `automatic`) and
    /// Sukusho's own that decodes. Read off the main thread; each file is read once per version (`decodes`).
    static func resolve(picked path: String, desktop: URL?, dark: Bool) async -> URL {
        let candidates = [path.isEmpty ? nil : URL(fileURLWithPath: path), desktop.flatMap { automatic($0) }].compactMap(\.self)
        let own = ownPicture(dark: dark)
        return await Task.detached(priority: .userInitiated) { candidates.first(where: decodes) ?? own }.value
    }

    /// A desktop picture Sukusho may read unasked: in the folders macOS keeps its own wallpapers in, both where it's
    /// named and where its links lead. Anything else (Downloads, Desktop, another app's folder under /Library) would
    /// ask first, or isn't a wallpaper, so it gets Sukusho's own.
    nonisolated static func automatic(_ url: URL, in folders: [String] = appleWallpaperFolders) -> URL? {
        let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        return paths.allSatisfy { path in folders.contains { path.hasPrefix($0) } } ? url : nil
    }

    nonisolated static let appleWallpaperFolders = [
        "/System/Library/Desktop Pictures/", "/Library/Desktop Pictures/",
        "/System/Library/Wallpapers/",   // DefaultDesktop.heic's target
        "/System/Library/CoreServices/DefaultDesktop.heic",
    ]

    static func ownPicture(dark: Bool) -> URL {
        // Bundled by scripts/make-glass-pictures.swift; a bundle without them would be a broken build.
        Bundle.main.url(forResource: dark ? "GlassDark" : "GlassLight", withExtension: "heic")
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    }

    /// Whether the file decodes, from a 32-pixel thumbnail. Kept per path, file, size and date, so a good or bad file
    /// is read once, and a file replaced or rewritten in place is read again.
    nonisolated static func decodes(_ url: URL) -> Bool {
        // The file a link leads to, such as DefaultDesktop.heic's.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else { return false }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let version = "\(url.standardizedFileURL.path)#\(attributes[.systemFileNumber] ?? 0)#\(attributes[.size] ?? 0)#\(date)"
        if let known = decoded.withLock({ $0[version] }) { return known }
        let ok = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32,
            ] as CFDictionary)
        } != nil
        decoded.withLock { $0[version] = ok }
        return ok
    }

    nonisolated private static let decoded = Mutex<[String: Bool]>([:])
}
