//
//  OptimizedMark.swift
//  Screendrop
//

import Foundation

/// Remembers, on the file itself, that it was optimized and the size it had before. An edit replaces the
/// file's contents but keeps its extended attributes (seen live: the editor's save carried the note over),
/// so the note also holds the size the optimizer left, and counts only while the file still has that size.
nonisolated enum OptimizedMark {
    private static let name = "com.tommyent.sukusho.optimized-from"

    /// Call once the optimized file is in place. `originalBytes` equal to the file's size records that the
    /// optimizer found nothing smaller, so it isn't asked again.
    static func set(_ originalBytes: Int64, on url: URL) {
        guard let now = size(of: url) else { return }
        let text = "\(originalBytes) \(now)"
        _ = text.withCString { setxattr(url.path, name, $0, strlen($0), 0, 0) }
    }

    /// The size before optimizing, while the file is still as the optimizer left it.
    static func originalBytes(of url: URL) -> Int64? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard getxattr(url.path, name, &buffer, buffer.count - 1, 0, 0) > 0 else { return nil }
        let parts = String(cString: buffer).split(separator: " ").compactMap { Int64($0) }
        guard parts.count == 2, parts[1] == size(of: url) else { return nil }
        return parts[0]
    }

    /// Whether the file is as the optimizer left it, so there is nothing to do again.
    static func isCurrent(_ url: URL) -> Bool {
        originalBytes(of: url) != nil
    }

    /// "↓18%" for a file that is still the optimized one, with the size it came from.
    static func saving(of url: URL) -> (percent: String, original: String)? {
        guard let original = originalBytes(of: url), let now = size(of: url), now < original else { return nil }
        return (ImageOptimizationResult.saving(from: original, to: now),
                ByteCountFormatter.string(fromByteCount: original, countStyle: .file))
    }

    /// Asked of the file system each time: a URL keeps the sizes it has read, and would report the old one.
    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
