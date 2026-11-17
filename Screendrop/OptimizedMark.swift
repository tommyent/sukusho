//
//  OptimizedMark.swift
//  Screendrop
//

import Foundation

/// Remembers, on the file itself, that it was optimized and the size it had before. An edit replaces the
/// file's contents but keeps its extended attributes (seen live: the editor's save carried the note over),
/// so the note also holds what the optimizer left: its size, its modification date and a hash of its
/// contents. Saves and reverts clear the note as well (`clear`); the checks are for everything else.
nonisolated enum OptimizedMark {
    private static let name = "com.tommyent.sukusho.optimized-from"

    private struct Note {
        let originalBytes: Int64
        let size: Int64
        /// The modification date's bits, so it compares exactly.
        let modified: UInt64
        let digest: String
    }

    /// Call once the optimized file is in place. `originalBytes` equal to the file's size records that the
    /// optimizer found nothing smaller, so it isn't asked again.
    static func set(_ originalBytes: Int64, on url: URL) {
        guard let state = state(of: url), let digest = digest(of: url) else { return }
        let text = "\(originalBytes) \(state.size) \(state.modified) \(digest)"
        _ = text.withCString { setxattr(url.path, name, $0, strlen($0), 0, 0) }
    }

    /// Takes the note off: the file's contents are about to be, or have been, replaced.
    static func clear(_ url: URL) {
        removexattr(url.path, name, 0)
    }

    /// The size before optimizing, for showing the saving: while the file has the size and date the optimizer
    /// left. Cheap enough to ask on every redraw.
    static func originalBytes(of url: URL) -> Int64? {
        guard let note = note(of: url), let state = state(of: url), note.size == state.size, note.modified == state.modified else {
            return nil
        }
        return note.originalBytes
    }

    /// Whether the file is exactly what the optimizer left, so there is nothing to do again. Reads the whole
    /// file: a rewrite of the same length, even with its date put back, is not current.
    static func isCurrent(_ url: URL) -> Bool {
        guard let note = note(of: url), note.size == state(of: url)?.size else { return false }
        return note.digest == digest(of: url)
    }

    /// "↓18%" for a file that is still the optimized one, with the size it came from.
    static func saving(of url: URL) -> (percent: String, original: String)? {
        guard let original = originalBytes(of: url), let now = state(of: url)?.size, now < original else { return nil }
        return (ImageOptimizationResult.saving(from: original, to: now),
                ByteCountFormatter.string(fromByteCount: original, countStyle: .file))
    }

    /// The inspector's size rows. A capture with edits keeps its base, its original and its edit history beside the
    /// image, so its size on disk is several times the image's: the saving belongs to the image, on a row of its own,
    /// not beside the total (Fable 15 #1: "5.2 MB ↓31%" for a 1.3 MB file). `original` is the size before optimizing.
    static func sizeRows(total: Int64, image: Int64, keepsEdits: Bool, original: Int64?) -> [(label: String, value: String, help: String)] {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let saving = original.flatMap { $0 > image ? $0 : nil }
        let percent = saving.map { " " + ImageOptimizationResult.saving(from: $0, to: image) } ?? ""
        let from = saving.map { "Optimized from \(format($0))" } ?? ""
        guard keepsEdits else { return [("Size on disk", format(total) + percent, from)] }
        return [("Image", format(image) + percent, from),
                ("Size on disk", format(total), "With the original and the edit history that Revert To… uses")]
    }

    private static func note(of url: URL) -> Note? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard getxattr(url.path, name, &buffer, buffer.count - 1, 0, 0) > 0 else { return nil }
        let parts = String(cString: buffer).split(separator: " ")
        guard parts.count == 4, let original = Int64(parts[0]), let size = Int64(parts[1]), let modified = UInt64(parts[2]) else {
            return nil
        }
        return Note(originalBytes: original, size: size, modified: modified, digest: String(parts[3]))
    }

    /// Asked of the file system each time: a URL keeps the sizes and dates it has read.
    private static func state(of url: URL) -> (size: Int64, modified: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified.timeIntervalSince1970.bitPattern)
    }

    private static func digest(of url: URL) -> String? { FileIdentity(url)?.digest }
}
