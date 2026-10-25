//
//  CloudShareSeal.swift
//  Screendrop
//
//  Encrypted share links. The file is sealed here with CryptoKit and opened
//  in the recipient's browser with WebCrypto (the Worker's
//  src/lib/sealed-share.ts); nothing else touches the cipher.
//
//  Format, version 1:
//  - Key: a new SymmetricKey(size: .bits256) per upload, base64url without
//    padding (43 characters), after `#` in the share link. Browsers never
//    send the fragment, so the Worker never sees it.
//  - Uploaded object: AES.GCM.SealedBox.combined, which is the 12-byte nonce,
//    the ciphertext, then the 16-byte tag. No additional authenticated data.
//  - Plaintext: a 4-byte big-endian length N, N bytes of UTF-8 JSON
//    {"contentType": …, "filename": …}, then the file's bytes.
//

import CryptoKit
import Foundation

nonisolated enum CloudShareSeal {
    /// One seal is decrypted whole, in memory, in the recipient's tab.
    static let maxFileBytes = 32 * 1024 * 1024
    static let maxHeaderBytes = 4096
    /// Shown where the option can't be used: Studio, recordings, and files over the cap.
    static let unavailableNote = "End-to-end encryption is for images and files up to 32 MB for now."

    struct Sealed: Sendable {
        let combined: Data
        /// base64url, the part of the link after `#`.
        let key: String
    }

    struct Opened: Sendable, Equatable {
        let filename: String
        let contentType: String
        let bytes: Data
    }

    enum Failure: LocalizedError, Equatable {
        case tooLarge, wrongKey, unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: CloudShareSeal.unavailableNote
            case .wrongKey: "This Mac’s key for it doesn’t match."
            case .unreadable: "It couldn’t be decrypted."
            }
        }
    }

    /// `key` and `nonce` are only given by tests; every upload gets new ones.
    static func seal(_ file: Data, filename: String, contentType: String,
                     key: SymmetricKey = SymmetricKey(size: .bits256),
                     nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Sealed {
        guard file.count <= maxFileBytes else { throw Failure.tooLarge }
        let box = try AES.GCM.seal(try framed(file, filename: filename, contentType: contentType), using: key, nonce: nonce)
        // Only nil for a nonce that isn't 12 bytes.
        guard let combined = box.combined else { throw Failure.unreadable }
        return Sealed(combined: combined, key: encodedKey(key))
    }

    /// A wrong key and altered bytes fail alike, by GCM's tag.
    static func open(_ combined: Data, key: String) throws -> Opened {
        guard let keyData = decodedKey(key) else { throw Failure.wrongKey }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: keyData))
        } catch {
            throw Failure.wrongKey
        }
        return try unframed(plaintext)
    }

    static func framed(_ file: Data, filename: String, contentType: String) throws -> Data {
        let header = try JSONSerialization.data(withJSONObject: ["filename": filename, "contentType": contentType],
                                                options: [.sortedKeys, .withoutEscapingSlashes])
        guard header.count <= maxHeaderBytes else { throw Failure.unreadable }
        var plaintext = Data(capacity: 4 + header.count + file.count)
        withUnsafeBytes(of: UInt32(header.count).bigEndian) { plaintext.append(contentsOf: $0) }
        plaintext.append(header)
        plaintext.append(file)
        return plaintext
    }

    /// The same checks as the browser's parseFraming.
    static func unframed(_ plaintext: Data) throws -> Opened {
        let bytes = [UInt8](plaintext.prefix(4))
        guard bytes.count == 4 else { throw Failure.unreadable }
        let length = bytes.reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxHeaderBytes, 4 + length <= plaintext.count else { throw Failure.unreadable }
        let start = plaintext.startIndex
        let header = plaintext[(start + 4)..<(start + 4 + length)]
        guard String(data: header, encoding: .utf8) != nil,
              let fields = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              let filename = fields["filename"] as? String, !filename.isEmpty, filename.utf16.count <= 255,
              let contentType = fields["contentType"] as? String, contentType.utf16.count <= 255
        else { throw Failure.unreadable }
        return Opened(filename: filename, contentType: contentType, bytes: Data(plaintext[(start + 4 + length)...]))
    }

    static func encodedKey(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 43 base64url characters, or nil.
    static func decodedKey(_ text: String) -> Data? {
        guard text.count == 43, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    /// Why these files can't be shared encrypted, or nil when they can: recordings
    /// stay plaintext, and one seal holds at most `maxFileBytes`.
    static func unavailableReason(fileURLs: [URL], isRecording: Bool = false) -> String? {
        let tooLarge = fileURLs.contains {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > maxFileBytes
        }
        return isRecording || tooLarge ? unavailableNote : nil
    }

    /// The link as people open it: with the key after `#` when there is one.
    static func link(_ url: String, key: String?) -> String {
        let base = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        guard let key else { return base }
        return base + "#" + key
    }
}

/// Each encrypted upload's key, in the Keychain under its upload ID, beside the
/// upload token, labelled with its Worker's host. Deleting the upload deletes its key.
struct CloudShareKeys {
    var read: (String) -> String?
    /// Account, key, label; false when the Keychain refused it.
    var write: (String, String, String) -> Bool
    var delete: (String) -> Void
    /// Every item's account, label and creation date.
    var list: () -> [(account: String, label: String, created: Date)]

    static let accountPrefix = "cloud_share_key_"

    static func account(for uploadID: String) -> String {
        accountPrefix + uploadID
    }

    /// The label a key carries: its link's host, with any port.
    nonisolated static func host(of url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// False when the Keychain refused it, so the link must not be handed out as if it were kept.
    func save(_ key: String, uploadID: String, workerHost: String) -> Bool {
        write(Self.account(for: uploadID), key, workerHost)
    }

    func key(uploadID: String) -> String? {
        read(Self.account(for: uploadID)).flatMap { CloudShareSeal.decodedKey($0) == nil ? nil : $0 }
    }

    func remove(uploadID: String) {
        delete(Self.account(for: uploadID))
    }

    /// `url` as it's handed out: with this Mac's key, or without one, flagged when the
    /// upload's own record says it's sealed.
    func link(_ url: String, uploadID: String, encrypted: Bool) -> (link: String, missingKey: Bool) {
        let key = key(uploadID: uploadID)
        return (CloudShareSeal.link(url, key: key), key == nil && encrypted)
    }

    /// How much older than the list a key must be to go. The file keychain stores creation times
    /// in whole seconds, so a key saved while the list was in flight can look older than its
    /// start; a key kept by this margin goes at a later refresh if its upload is still gone.
    static let pruneMargin: TimeInterval = 60

    /// After a complete list of one Worker's uploads, drops the keys of its uploads that are gone
    /// (expired, or deleted elsewhere). Keys made within `pruneMargin` of the list's request,
    /// other Workers' keys and unlabelled items stay. Returns the upload IDs whose keys went.
    func prune(workerHost: String, keeping uploadIDs: Set<String>, listedSince: Date) -> [String] {
        let cutoff = listedSince.addingTimeInterval(-Self.pruneMargin)
        let gone = list().compactMap { item -> String? in
            guard item.account.hasPrefix(Self.accountPrefix), item.label == workerHost, item.created < cutoff else { return nil }
            let id = String(item.account.dropFirst(Self.accountPrefix.count))
            return uploadIDs.contains(id) ? nil : id
        }
        gone.forEach(remove(uploadID:))
        return gone.sorted()
    }
}

/// The uploads this Mac sealed, by ID, kept apart from their keys: a link copied later
/// still knows it needs one when the key is gone (refused by the Keychain, or removed).
struct CloudSealedUploads {
    var defaults = UserDefaults.standard
    static let defaultsKey = "cloudSealedUploadIDs"

    private var ids: Set<String> { Set(defaults.stringArray(forKey: Self.defaultsKey) ?? []) }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func insert(_ id: String) {
        defaults.set(Array(ids.union([id])).sorted(), forKey: Self.defaultsKey)
    }

    func remove(_ removed: some Sequence<String>) {
        defaults.set(Array(ids.subtracting(removed)).sorted(), forKey: Self.defaultsKey)
    }
}
