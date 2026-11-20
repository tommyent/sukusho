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
    /// True when Glass uses a solid background instead of its blurred picture.
    static let solidBackgroundKey = "GlassSolidBackground"

    /// What Glass paints: the file and its version (`version(of:)`), so a window repaints when the file at the same
    /// path is replaced, not only when the path changes.
    nonisolated struct Resolved: Equatable, Sendable {
        let url: URL
        let version: String
    }

    /// The picture to paint: the first of the picked one, the desktop picture (Apple's own only, `automatic`) and
    /// Sukusho's own that decodes. All of it off the main thread, links too, which a slow volume would make stall;
    /// each file is read once per version (`decodes`). `roots`: Apple's wallpaper folders, a test's own in tests.
    static func resolve(picked path: String, desktop: URL?, dark: Bool,
                        roots: [String] = appleWallpaperFolders) async -> Resolved {
        let own = ownPicture(dark: dark)
        return await Task.detached(priority: .userInitiated) {
            let candidates = [path.isEmpty ? nil : URL(fileURLWithPath: path), desktop.flatMap { automatic($0, in: roots) }]
            let url = candidates.compactMap(\.self).first(where: decodes) ?? own
            return Resolved(url: url, version: version(of: url) ?? "")
        }.value
    }

    /// A desktop picture Sukusho may read unasked: in the folders macOS keeps its own wallpapers in, both where it's
    /// named and where its links lead. Anything else (Downloads, Desktop, another app's folder under /Library) would
    /// ask first, or isn't a wallpaper, so it gets Sukusho's own. A root ending in "/" is a folder; any other is one
    /// file, matched exactly, so `DefaultDesktop.heic-backup` isn't it. A path outside is turned away before its
    /// links are followed.
    nonisolated static func automatic(_ url: URL, in roots: [String] = appleWallpaperFolders) -> URL? {
        func allowed(_ path: String) -> Bool { roots.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 } }
        guard allowed(url.standardizedFileURL.path) else { return nil }
        return allowed(url.resolvingSymlinksInPath().standardizedFileURL.path) ? url : nil
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
        guard let version = version(of: url) else { return false }
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

    /// The path, and the file it leads to (such as DefaultDesktop.heic's) by number, size and date; nil when it's gone.
    nonisolated static func version(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.standardizedFileURL.path)#\(attributes[.systemFileNumber] ?? 0)#\(attributes[.size] ?? 0)#\(date)"
    }
}

/// A picture choice in Settings (Glass's, and the workspace wallpaper's): picks overlap while a slow copy runs, and
/// only the latest lands, so an earlier copy that finishes late can't undo a newer choice, Default included. One per
/// preference (`for`), kept for the app's life: a picker left and opened again picks with the same one.
final class LatestPick {
    private var latest = 0
    private static var byPreference: [String: LatestPick] = [:]

    /// The one for a preference's key.
    static func `for`(_ key: String) -> LatestPick {
        if let pick = byPreference[key] { return pick }
        let pick = LatestPick()
        byPreference[key] = pick
        return pick
    }

    /// `apply` gets the imported file's path, or `failed` the error, only while this is still the latest pick.
    /// No URL is a choice too (Glass's Default), applied at once as "".
    func choose(_ url: URL?, importing: (URL) async throws -> URL,
                apply: (String) -> Void, failed: (Error) -> Void) async {
        latest += 1
        let pick = latest
        guard let url else { return apply("") }
        do {
            let path = try await importing(url).standardizedFileURL.path
            if pick == latest { apply(path) }
        } catch {
            if pick == latest { failed(error) }
        }
    }
}
