import CryptoKit
import Darwin
import Foundation

/// Saves a no-clobber copy (`<file>.unreadable-<hash>`) beside a sidecar that exists
/// as a regular file but failed to decode or validate. Never follows symlinks or
/// overwrites an earlier copy.
nonisolated enum RecordingSidecarQuarantine {
    private static let maxBytes: off_t = 64 * 1024 * 1024

    @discardableResult
    static func preserve(at url: URL) -> URL? {
        let source = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard source >= 0 else { return nil }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maxBytes else { return nil }
        let data = FileHandle(fileDescriptor: source, closeOnDealloc: false).readDataToEndOfFile()
        let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(hash)")
        let copy = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard copy >= 0 else {
            guard errno == EEXIST else { return nil }
            var existing = stat()
            return lstat(destination.path, &existing) == 0 && (existing.st_mode & S_IFMT) == S_IFREG ? destination : nil
        }
        defer { close(copy) }
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let step = Darwin.write(copy, base.advanced(by: written), raw.count - written)
                if step < 0 && errno == EINTR { continue }
                if step <= 0 { return false }
                written += step
            }
            return true
        }
        if !ok { unlink(destination.path); return nil }
        return destination
    }
}
