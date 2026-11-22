import CryptoKit
import Darwin
import Foundation

/// Saves a verified, no-clobber copy (`<file>.unreadable-<hash>`) beside a sidecar
/// that exists as a regular file inside a verified package directory but failed to
/// decode or validate. Never follows symlinks (package directory, source, or
/// destination), bounds reads to `maxBytes`, publishes atomically via `linkat`,
/// and verifies byte equality on `EEXIST`.
nonisolated enum RecordingSidecarQuarantine {
    enum QuarantineError: LocalizedError, Equatable {
        case missingSourceFile(String)
        case unsafePackageDirectory(String)
        case unsafeSourceFile(String)
        case oversizedSourceFile(String)
        case preservationFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .missingSourceFile(let name):
                "The sidecar file \"\(name)\" does not exist."
            case .unsafePackageDirectory(let name):
                "The recording package \"\(name)\" is not a regular directory."
            case .unsafeSourceFile(let name):
                "The sidecar file \"\(name)\" is not a regular file inside the package."
            case .oversizedSourceFile(let name):
                "The sidecar file \"\(name)\" exceeds the maximum quarantine size."
            case .preservationFailed(let name, let code):
                "Could not preserve unreadable sidecar \"\(name)\" (errno \(code))."
            }
        }
    }

    static let maxBytes = 64 * 1024 * 1024

    /// Reads an existing regular file at `url` relative to a verified package directory
    /// descriptor, bounding the read to `maxBytes`. Throws `.missingSourceFile` on `ENOENT`.
    static func readBounded(at url: URL) throws -> Data {
        let (dirFD, leaf) = try openVerifiedParent(for: url)
        defer { close(dirFD) }
        let sourceFD = try openSource(leaf: leaf, inDirFD: dirFD)
        defer { close(sourceFD) }
        return try readBounded(fd: sourceFD, name: leaf, limit: maxBytes)
    }

    /// Preserves the regular file at `url` to `<name>.<kind>-<12hex>`: `unreadable` for a sidecar that failed
    /// to decode, `conflict` for a readable edit set aside on purpose (see `conflictArchiveKind`).
    /// Throws if the package directory or file is unsafe, missing, oversized, or
    /// preservation cannot be verified (including a mismatched existing copy).
    @discardableResult
    static func preserve(at url: URL, as kind: String = "unreadable") throws -> URL {
        let (dirFD, leaf) = try openVerifiedParent(for: url)
        defer { close(dirFD) }
        let sourceFD = try openSource(leaf: leaf, inDirFD: dirFD)
        defer { close(sourceFD) }
        let data = try readBounded(fd: sourceFD, name: leaf, limit: maxBytes)
        return try preserve(data: data, leaf: leaf, kind: kind, inDirFD: dirFD, directoryURL: url.deletingLastPathComponent())
    }

    /// Readable edits Revert sets aside from a conflict; the media sweep counts what they reference.
    static let conflictArchiveKind = "conflict"

    /// Reads `url` once relative to a verified package directory descriptor.
    /// Returns immediately if `url` is absent (`ENOENT`) or passes `validate`.
    /// Otherwise preserves the exact bytes read and throws if preservation fails
    /// (so callers abort overwriting the original).
    static func preserveIfInvalid(at url: URL, validate: (Data) throws -> Void) throws {
        let (dirFD, leaf) = try openVerifiedParent(for: url)
        defer { close(dirFD) }
        let sourceFD: Int32
        do {
            sourceFD = try openSource(leaf: leaf, inDirFD: dirFD)
        } catch QuarantineError.missingSourceFile {
            return
        }
        defer { close(sourceFD) }
        let data = try readBounded(fd: sourceFD, name: leaf, limit: maxBytes)
        do {
            try validate(data)
        } catch {
            _ = try preserve(data: data, leaf: leaf, inDirFD: dirFD, directoryURL: url.deletingLastPathComponent())
        }
    }

    private static func openVerifiedParent(for url: URL) throws -> (dirFD: Int32, leaf: String) {
        let leaf = url.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            throw QuarantineError.unsafeSourceFile(leaf)
        }
        let parent = url.deletingLastPathComponent()
        let dirFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else {
            throw QuarantineError.unsafePackageDirectory(parent.lastPathComponent)
        }
        return (dirFD, leaf)
    }

    private static func openSource(leaf: String, inDirFD dirFD: Int32) throws -> Int32 {
        let fd = openat(dirFD, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { throw QuarantineError.missingSourceFile(leaf) }
            throw QuarantineError.unsafeSourceFile(leaf)
        }
        return fd
    }

    private static func readBounded(fd: Int32, name: String, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw QuarantineError.unsafeSourceFile(name)
        }
        guard info.st_size >= 0, info.st_size <= off_t(limit) else {
            throw QuarantineError.oversizedSourceFile(name)
        }
        var data = Data()
        data.reserveCapacity(min(Int(info.st_size), 1024 * 1024))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw QuarantineError.unsafeSourceFile(name)
            }
            if count == 0 { break }
            if data.count + count > limit {
                throw QuarantineError.oversizedSourceFile(name)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func preserve(data: Data, leaf: String, kind: String = "unreadable", inDirFD dirFD: Int32,
                                 directoryURL: URL) throws -> URL {
        let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let destName = "\(leaf).\(kind)-\(hash)"
        let destination = directoryURL.appendingPathComponent(destName)
        let tempName = ".\(destName).\(UUID().uuidString).tmp"
        let tempFD = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard tempFD >= 0 else {
            throw QuarantineError.preservationFailed(destName, errno)
        }
        defer { unlinkat(dirFD, tempName, 0) }
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let step = Darwin.write(tempFD, base.advanced(by: written), raw.count - written)
                if step < 0 && errno == EINTR { continue }
                if step <= 0 { return false }
                written += step
            }
            return true
        }
        let writeErrno = errno
        let synced = wroteAll && fsync(tempFD) == 0
        let syncErrno = errno
        close(tempFD)
        guard wroteAll else { throw QuarantineError.preservationFailed(destName, writeErrno) }
        guard synced else { throw QuarantineError.preservationFailed(destName, syncErrno) }

        if linkat(dirFD, tempName, dirFD, destName, 0) == 0 {
            return destination
        }
        let linkErrno = errno
        guard linkErrno == EEXIST else {
            throw QuarantineError.preservationFailed(destName, linkErrno)
        }
        // Verify the existing quarantine file is a regular file with exact byte equality.
        let existingFD = openat(dirFD, destName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard existingFD >= 0 else {
            throw QuarantineError.preservationFailed(destName, errno)
        }
        defer { close(existingFD) }
        guard let existingData = try? readBounded(fd: existingFD, name: destName, limit: data.count),
              existingData == data else {
            throw QuarantineError.preservationFailed(destName, EEXIST)
        }
        return destination
    }
}
