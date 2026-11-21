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
    enum Outcome: Equatable, Sendable {
        /// `originalKept`: a Replace whose new file is in place, but whose original could not be moved to the
        /// Trash and is still beside it.
        case saved(URL, originalKept: Bool = false)
        /// The source isn't the file that was optimized any more; nothing was written or moved.
        case changed
        case failed(String)
    }

    /// Writes `result` beside `original` ("name optimized.png", or "name.webp" for another format), in
    /// `destinationFolder` when one was chosen, or with `replacing` in `original`'s place. `identity` is
    /// the contents the result was made from (`ImageOptimizationResult.source`), and `outputIdentity` is
    /// the encoder's verified output (`ImageOptimizationResult.output`): the original must still hold
    /// `identity` and the staged copy must match `outputIdentity` before the source is touched. `retire`
    /// takes the original out of the way and says where it went: the Trash, outside tests.
    static func save(_ result: URL, of original: URL, identity: FileIdentity?,
                     outputIdentity: FileIdentity?, replacing: Bool,
                     in destinationFolder: URL? = nil,
                     beforeInstall: (URL) throws -> Void = { _ in },
                     retire: (URL) throws -> URL = moveToTrash) -> Outcome {
        guard let identity, identity == FileIdentity(original) else { return .changed }
        guard let outputIdentity else { return .failed("The optimized file couldn't be verified.") }
        let files = FileManager.default
        let folder = replacing ? original.deletingLastPathComponent() : (destinationFolder ?? original.deletingLastPathComponent())
        let base = original.deletingPathExtension().lastPathComponent
        let sameFormat = result.pathExtension.lowercased() == original.pathExtension.lowercased()

        // The whole new file first, on the destination's own volume: after this, putting it in place is a rename.
        let staging = folder.appendingPathComponent(".sukusho-save-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent(result.lastPathComponent)
        defer { try? files.removeItem(at: staging) }
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            try files.copyItem(at: result, to: staged)
            guard let written = FileIdentity(staged), written == outputIdentity else {
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
            let destination = try installUniquely(from: staged, named: name, in: folder, beforeInstall: beforeInstall)
            // Another format gets another name, so the original is retired after its replacement is in place.
            // If it can't be, the new file is saved all the same, and that is what is reported.
            guard replacing else { return .saved(destination) }
            do {
                _ = try retire(original)
            } catch {
                return .saved(destination, originalKept: true)
            }
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

    /// Installs `staged` in `folder` as "name.webp", "name 2.webp", … using exclusive rename so a late
    /// collision picks the next free name instead of failing or overwriting.
    private static func installUniquely(from staged: URL, named name: String, in folder: URL,
                                        beforeInstall: (URL) throws -> Void) throws -> URL {
        let first = folder.appendingPathComponent(name)
        let base = first.deletingPathExtension().lastPathComponent
        let ext = first.pathExtension
        func candidate(_ number: Int) -> URL {
            guard number > 1 else { return first }
            let numbered = folder.appendingPathComponent("\(base) \(number)")
            return ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
        }
        for number in 1...10_000 {
            let destination = candidate(number)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try beforeInstall(destination)
            do {
                try ScreenshotFileActions.installExport(from: staged, at: destination, replacingExisting: false)
                return destination
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        let fallback = folder.appendingPathComponent("\(base) \(UUID().uuidString)")
        let destination = ext.isEmpty ? fallback : fallback.appendingPathExtension(ext)
        try ScreenshotFileActions.installExport(from: staged, at: destination, replacingExisting: false)
        return destination
    }
}
