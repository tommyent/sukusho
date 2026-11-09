//
//  AnnotationWallpaperStore.swift
//  Screendrop
//

import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AnnotationWallpaperStore {
    static let shared = AnnotationWallpaperStore()

    static var wallpapersDirectory: URL {
        ScreendropStorage.applicationSupportDirectory.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    nonisolated private static let recentWallpaperPathsKey = "annotationBackground.recentWallpaperPaths"
    nonisolated private static let maxRecentWallpaperCount = 24
    nonisolated private static let supportedImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    /// What a wallpaper picker offers: the files this list keeps.
    static var supportedContentTypes: [UTType] {
        supportedImageExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    private(set) var recentWallpapers: [AnnotationCustomWallpaper] = []

    private init() {
        Task { await reload() }
    }

    /// Refreshes the recent wallpaper list. The filesystem checks run off
    /// the main actor; only the resulting state assignment happens on-main.
    func reload() async {
        let recent = await Task.detached(priority: .userInitiated) {
            Self.loadRecentWallpaperURLs()
        }.value
        recentWallpapers = recent.map { AnnotationCustomWallpaper(url: $0) }
    }

    func isAvailable(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        Self.isSupportedImageFile(wallpaper.url)
    }

    func accessibilityTitle(for wallpaper: AnnotationCustomWallpaper) -> String {
        let ordinal = (recentWallpapers.firstIndex(where: { $0.id == wallpaper.id }) ?? 0) + 1
        return wallpaper.accessibilityTitle(ordinal: ordinal)
    }

    func addRecentWallpaper(_ url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        let standardizedURL = URL(fileURLWithPath: standardizedPath)
        guard Self.isSupportedImageFile(standardizedURL) else { return }

        var paths = UserDefaults.standard.stringArray(forKey: Self.recentWallpaperPathsKey) ?? []
        guard !paths.contains(standardizedPath) else { return }
        paths.insert(standardizedPath, at: 0)

        let filteredPaths = paths
            .filter { path in
                let url = URL(fileURLWithPath: path)
                return Self.isSupportedImageFile(url)
            }
            .prefix(Self.maxRecentWallpaperCount)
        let recentPaths = Array(filteredPaths)

        UserDefaults.standard.set(recentPaths, forKey: Self.recentWallpaperPathsKey)
        recentWallpapers = recentPaths.map { AnnotationCustomWallpaper(url: URL(fileURLWithPath: $0)) }
        Task { await reload() }
    }

    /// Copies a picked image into Sukusho's wallpapers folder, so it stays when
    /// the original moves or goes, and lists it. A file already in that
    /// folder is listed as it is.
    func importWallpaper(from url: URL) throws -> URL {
        let directory = Self.wallpapersDirectory.standardizedFileURL
        var file = url.standardizedFileURL
        if !file.path.hasPrefix(directory.path + "/") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = ScreenshotFileNaming.uniqueURL(for: file.lastPathComponent, in: directory)
            try FileManager.default.copyItem(at: file, to: copy)
            file = copy
        }
        addRecentWallpaper(file)
        return file
    }

    // MARK: - Off-main filesystem work

    nonisolated private static func loadRecentWallpaperURLs() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentWallpaperPathsKey) ?? []
        let availablePaths = paths.filter { path in
            let url = URL(fileURLWithPath: path)
            return isSupportedImageFile(url)
        }

        if availablePaths != paths {
            UserDefaults.standard.set(availablePaths, forKey: recentWallpaperPathsKey)
        }

        return availablePaths.map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard !url.lastPathComponent.hasPrefix("._") else { return false }
        guard !url.pathComponents.contains("__MACOSX") else { return false }
        return supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

}
