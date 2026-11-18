import Foundation

nonisolated enum ClipboardFiles {
    static func withClipboardSnapshots<T>(of urls: [URL], name: (URL) -> String = { $0.lastPathComponent },
                                         write: ([URL]) throws -> T) throws -> T {
        let files = FileManager.default
        let directory = files.temporaryDirectory
            .appendingPathComponent("\(ScreendropStorage.directoryName)/Clipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            var snapshots: [URL] = []
            for (index, url) in urls.enumerated() {
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                let snapshot = folder.appendingPathComponent(name(url))
                try files.copyItem(at: url, to: snapshot)
                snapshots.append(snapshot)
            }
            // ponytail: published files live until OS temp cleanup; add an expiry policy if storage grows.
            return try write(snapshots)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}
