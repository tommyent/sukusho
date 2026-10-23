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
    static let unavailableNote = "Encrypted links are for images and files up to 32 MB for now."

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
/// upload token. Deleting the upload deletes its key.
struct CloudShareKeys {
    var read: (String) -> String?
    var write: (String, String) -> Void
    var delete: (String) -> Void

    static func account(for uploadID: String) -> String {
        "cloud_share_key_" + uploadID
    }

    func save(_ key: String, uploadID: String) {
        write(Self.account(for: uploadID), key)
    }

    func key(uploadID: String) -> String? {
        read(Self.account(for: uploadID)).flatMap { CloudShareSeal.decodedKey($0) == nil ? nil : $0 }
    }

    func remove(uploadID: String) {
        delete(Self.account(for: uploadID))
    }
}
