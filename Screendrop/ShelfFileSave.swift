//
//  ShelfFileSave.swift
//  Screendrop
//
//  How the shake shelf's Save writes an optimized file next to the file it came
//  from, or in its place. A file on the shelf can be changed in another app
//  before Save is pressed, so a result is written only while its source is
//  still the file the optimizer read, and an original leaves its place only
//  once its replacement is safely on the same volume.
//

import Foundation

nonisolated enum ShelfFileSave {
    enum Outcome: Equatable {
        case saved(URL)
        /// The source isn't the file that was optimized any more; nothing was written or moved.
        case changed
        case failed(String)
    }

    /// Writes `result` beside `original` ("name optimized.png", or "name.webp" for another format), or with
    /// `replacing` in its place. `identity` is the contents the result was made from
    /// (`ImageOptimizationResult.source`): the original must still hold exactly those. `retire` takes the
    /// original out of the way and says where it went, so it can be put back: the Trash, outside tests.
    static func save(_ result: URL, of original: URL, identity: FileIdentity?, replacing: Bool,
                     retire: (URL) throws -> URL = moveToTrash) -> Outcome {
        guard let identity, identity == FileIdentity(original) else { return .changed }
        let files = FileManager.default
        let folder = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let sameFormat = result.pathExtension.lowercased() == original.pathExtension.lowercased()

        // The whole new file first, on the destination's own volume: after this, putting it in place is a rename.
        let staging = folder.appendingPathComponent(".sukusho-save-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent(result.lastPathComponent)
        defer { try? files.removeItem(at: staging) }
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            try files.copyItem(at: result, to: staged)
            guard let written = FileIdentity(staged), written == FileIdentity(result) else {
                return .failed("The file couldn't be written completely.")
            }
            // Asked again now that the new file is ready: the last moment before anything moves.
            guard identity == FileIdentity(original) else { return .changed }

            if replacing, sameFormat {
                // The original goes to the Trash only now, and comes back if the new file can't take its place.
                let retired = try retire(original)
                do {
                    try files.moveItem(at: staged, to: original)
                } catch {
                    do {
                        try files.moveItem(at: retired, to: original)
                    } catch {
                        // Neither file is in place now. The original is whole where `retire` put it, so say where.
                        return .failed("The file could not be replaced or put back. The original is kept at \(retired.path).")
                    }
                    throw error
                }
                return .saved(original)
            }

            let name = (replacing || !sameFormat ? base : "\(base) optimized") + "." + result.pathExtension
            let destination = unused(name, in: folder)
            try files.moveItem(at: staged, to: destination)
            // Another format gets another name, so the original is retired after its replacement is in place.
            if replacing { _ = try retire(original) }
            return .saved(destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func moveToTrash(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }

    /// "name.webp", or "name 2.webp" and so on while that is taken.
    private static func unused(_ name: String, in folder: URL) -> URL {
        let first = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let base = first.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let next = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(first.pathExtension)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return folder.appendingPathComponent("\(base) \(UUID().uuidString)").appendingPathExtension(first.pathExtension)
    }
}
