import Foundation

nonisolated enum ClipboardFiles {
    static func snapshot(of url: URL, in directory: URL, name: String) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent(name)
        if !files.fileExists(atPath: result.path) { try files.copyItem(at: url, to: result) }
        return result
    }

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
                snapshots.append(try snapshot(of: url, in: folder, name: name(url)))
            }
            // ponytail: published files live until OS temp cleanup; add an expiry policy if storage grows.
            return try write(snapshots)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}

extension ClipboardEntry {
    nonisolated func snapshotName(for url: URL) -> String {
        let title = ClipboardList.fileTitle(of: self)
        let ext = url.pathExtension
        return ext.isEmpty || title.lowercased().hasSuffix("." + ext.lowercased()) ? title : title + "." + ext
    }

    nonisolated func imageSnapshot() throws -> URL {
        guard let imageURL else { throw CocoaError(.fileNoSuchFile) }
        return try ClipboardFiles.withClipboardSnapshots(of: [imageURL], name: snapshotName) { $0[0] }
    }
}
