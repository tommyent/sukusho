import CryptoKit
import Foundation

nonisolated struct CaptureSessionSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let openedAt: Date
    let fingerprint: String
    let baseExtension: String?
    var version = 1

    var title: String {
        "Opened \(openedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))"
    }
}

/// Only complete UUID directories are published; an interrupted staging copy
/// cannot become a menu entry or displace one of the five kept sessions.
nonisolated struct CaptureSessionSnapshots {
    let directory: URL

    static func encode<T: Encodable>(_ document: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    /// Decodes ISO-8601 snapshots, falling back to default numeric dates for legacy snapshots.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        do {
            return try iso.decode(type, from: data)
        } catch let isoError {
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw isoError
            }
        }
    }

    func entries() throws -> [CaptureSessionSnapshot] {
        Array(try allEntries(strict: false).prefix(5))
    }

    /// Cleanup must account for every retained folder, including failed prunes.
    func strictEntries() throws -> [CaptureSessionSnapshot] {
        try allEntries(strict: true)
    }

    private func allEntries(strict: Bool) throws -> [CaptureSessionSnapshot] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder -> CaptureSessionSnapshot? in
                if strict { return try metadata(in: folder) }
                return try? metadata(in: folder)
            }
            .sorted {
                $0.openedAt == $1.openedAt ? $0.id.uuidString > $1.id.uuidString : $0.openedAt > $1.openedAt
            }
    }

    @discardableResult
    func keep(document: Data, baseImage: URL? = nil, openedAt: Date) throws -> [CaptureSessionSnapshot] {
        let fingerprint = SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined()
        let existing = try allEntries(strict: false)
        if let newest = existing.first, newest.fingerprint == fingerprint {
            if let baseImage, let ext = newest.baseExtension {
                let previousBase = folder(for: newest.id).appendingPathComponent("base.\(ext)")
                if FileManager.default.contentsEqual(atPath: baseImage.path, andPath: previousBase.path) {
                    return prune(existing)
                }
            } else if baseImage == nil, newest.baseExtension == nil {
                return prune(existing)
            }
        }

        let ext = baseImage.map { $0.pathExtension.isEmpty ? "png" : $0.pathExtension.lowercased() }
        let entry = CaptureSessionSnapshot(id: UUID(), openedAt: openedAt, fingerprint: fingerprint, baseExtension: ext)
        try validate(entry)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".pending-\(entry.id.uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        if let baseImage, let ext {
            try ScreenshotEditFileTransaction.apply(replacements: [(baseImage, staging.appendingPathComponent("base.\(ext)"))])
        }
        try document.write(to: staging.appendingPathComponent("document.json"), options: .atomic)
        let entryData = try Self.encode(entry)
        let storedEntry = try Self.decode(CaptureSessionSnapshot.self, from: entryData)
        try entryData.write(to: staging.appendingPathComponent("session.json"), options: .atomic)
        try manager.moveItem(at: staging, to: folder(for: storedEntry.id))
        return prune(([storedEntry] + existing).sorted {
            $0.openedAt == $1.openedAt ? $0.id.uuidString > $1.id.uuidString : $0.openedAt > $1.openedAt
        })
    }

    func read(_ entry: CaptureSessionSnapshot) throws -> (document: Data, baseImage: URL?) {
        let folder = folder(for: entry.id)
        let stored = try metadata(in: folder)
        guard stored == entry else { throw CocoaError(.fileReadCorruptFile) }
        let base = stored.baseExtension.map { folder.appendingPathComponent("base.\($0)") }
        if let base, !FileManager.default.fileExists(atPath: base.path) { throw CocoaError(.fileReadNoSuchFile) }
        return (try Data(contentsOf: folder.appendingPathComponent("document.json")), base)
    }

    private func folder(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metadata(in folder: URL) throws -> CaptureSessionSnapshot {
        let entry = try Self.decode(CaptureSessionSnapshot.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        guard entry.id.uuidString == folder.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
        try validate(entry)
        return entry
    }

    private func validate(_ entry: CaptureSessionSnapshot) throws {
        guard entry.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        if let ext = entry.baseExtension {
            guard !ext.isEmpty, ext.count <= 10, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func prune(_ entries: [CaptureSessionSnapshot]) -> [CaptureSessionSnapshot] {
        for entry in entries.dropFirst(5) { try? FileManager.default.removeItem(at: folder(for: entry.id)) }
        return Array(entries.prefix(5))
    }
}
