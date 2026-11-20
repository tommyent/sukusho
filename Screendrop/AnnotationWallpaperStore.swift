//
//  AnnotationWallpaperStore.swift
//  Screendrop
//

import Foundation
import Synchronization
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
            Self.loadRecentWallpaperPaths()
        }.value
        publish(recent)
    }

    func isAvailable(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        Self.isSupportedImageFile(wallpaper.url)
    }

    func accessibilityTitle(for wallpaper: AnnotationCustomWallpaper) -> String {
        let ordinal = (recentWallpapers.firstIndex(where: { $0.id == wallpaper.id }) ?? 0) + 1
        return wallpaper.accessibilityTitle(ordinal: ordinal)
    }

    /// Lists a picked wallpaper. Off the main thread: a reload may hold the list's lock while it checks a slow
    /// volume, and the pick itself mustn't wait for that.
    func addRecentWallpaper(_ url: URL) {
        Task {
            let recent = await Task.detached(priority: .userInitiated) { Self.recentPaths(adding: url) }.value
            if let recent { publish(recent) }
            await reload()
        }
    }

    /// The recent list, saved, and the count of its changes so far: imports finish in any order, and only a list
    /// newer than the one shown is shown.
    nonisolated struct RecentList: Sendable {
        let revision: Int
        let paths: [String]
    }

    private var shownRevision = -1

    private func publish(_ recent: RecentList) {
        guard recent.revision > shownRevision else { return }
        shownRevision = recent.revision
        recentWallpapers = recent.paths.map { AnnotationCustomWallpaper(url: URL(fileURLWithPath: $0)) }
    }

    /// The recent list's one owner: every read, change and save of it, pruning included, happens under this lock,
    /// so imports at once can't each save a list without the others' pictures.
    nonisolated static let recentLock = Mutex(0)

    /// The recent list with `url` first, saved, or nil when it's already listed or isn't a picture. Checks each
    /// listed file, so `importWallpaper` calls it off the main thread. `defaults`: another domain in tests.
    nonisolated static func recentPaths(adding url: URL, in defaults: UserDefaults = .standard) -> RecentList? {
        let standardizedPath = url.standardizedFileURL.path
        guard isSupportedImageFile(URL(fileURLWithPath: standardizedPath)) else { return nil }
        return recentLock.withLock { revision in
            var paths = defaults.stringArray(forKey: recentWallpaperPathsKey) ?? []
            guard !paths.contains(standardizedPath) else { return nil }
            paths.insert(standardizedPath, at: 0)
            let recentPaths = Array(paths.filter { isSupportedImageFile(URL(fileURLWithPath: $0)) }.prefix(maxRecentWallpaperCount))
            defaults.set(recentPaths, forKey: recentWallpaperPathsKey)
            revision += 1
            return RecentList(revision: revision, paths: recentPaths)
        }
    }

    /// Copies a picked image into Sukusho's wallpapers folder, so it stays when
    /// the original moves or goes, and lists it. A file already in that
    /// folder is listed as it is. The copy and the recent list's file checks
    /// run off the main thread: a big picture or a slow volume takes a while.
    func importWallpaper(from url: URL) async throws -> URL {
        let directory = Self.wallpapersDirectory
        let (file, recent) = try await Task.detached(priority: .userInitiated) {
            let file = try Self.copy(url, into: directory)
            return (file, Self.recentPaths(adding: file))
        }.value
        if let recent { publish(recent) }
        return file
    }

    /// The editor's and Studio's Add keeps its own copy too. If the copy
    /// fails, the picked file is used where it is, as before copies.
    func addPickedWallpaper(_ url: URL) -> URL {
        let file = (try? Self.copy(url, into: Self.wallpapersDirectory)) ?? url
        addRecentWallpaper(file)
        return file
    }

    /// `url` copied into `directory` (`name_2` and so on when taken), or `url`
    /// itself when it's already inside. A link is followed: the file it leads
    /// to is what's copied, and a link inside that leads out is copied too.
    nonisolated static func copy(_ url: URL, into directory: URL) throws -> URL {
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        // Already inside: the file itself, named under `directory`, never a link to it from outside.
        if file.path.hasPrefix(folder.path + "/") {
            return directory.standardizedFileURL.appendingPathComponent(String(file.path.dropFirst(folder.path.count + 1)))
        }
        // One copy at a time: two imports of the same name must not both pick the same free name.
        return try copying.withLock { _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = ScreenshotFileNaming.uniqueURL(for: file.lastPathComponent, in: directory.standardizedFileURL)
            try FileManager.default.copyItem(at: file, to: copy)
            return copy
        }
    }

    nonisolated private static let copying = Mutex(())

    // MARK: - Off-main filesystem work

    /// The listed files that are still there, pruned under the recent list's lock like every other change.
    nonisolated private static func loadRecentWallpaperPaths() -> RecentList {
        recentLock.withLock { revision in
            let paths = UserDefaults.standard.stringArray(forKey: recentWallpaperPathsKey) ?? []
            let availablePaths = paths.filter { isSupportedImageFile(URL(fileURLWithPath: $0)) }
            if availablePaths != paths {
                UserDefaults.standard.set(availablePaths, forKey: recentWallpaperPathsKey)
            }
            revision += 1
            return RecentList(revision: revision, paths: availablePaths)
        }
    }

    nonisolated private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard !url.lastPathComponent.hasPrefix("._") else { return false }
        guard !url.pathComponents.contains("__MACOSX") else { return false }
        return supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

}
