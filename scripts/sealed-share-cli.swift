// Command line over the app's own CloudShareSeal, for scripts/check-sealed-share-interop.mjs.
// Build: swiftc -O Screendrop/CloudShareSeal.swift scripts/sealed-share-cli.swift -o <out>
//   seal <file> <filename> <content type> <sealed out>   prints the new key
//   open <sealed> <key> <file out>                       prints {"filename", "contentType", "size"}
//   vectors                                              prints the known-answer vectors as JSON

import CryptoKit
import Foundation

@main
struct SealedShareCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "seal" where arguments.count == 5:
            let sealed = try CloudShareSeal.seal(Data(contentsOf: URL(fileURLWithPath: arguments[1])),
                                                 filename: arguments[2], contentType: arguments[3])
            try sealed.combined.write(to: URL(fileURLWithPath: arguments[4]))
            print(sealed.key)
        case "open" where arguments.count == 4:
            do {
                let opened = try CloudShareSeal.open(Data(contentsOf: URL(fileURLWithPath: arguments[1])), key: arguments[2])
                try opened.bytes.write(to: URL(fileURLWithPath: arguments[3]))
                print(String(decoding: try JSONSerialization.data(withJSONObject: [
                    "filename": opened.filename, "contentType": opened.contentType, "size": opened.bytes.count,
                ], options: .sortedKeys), as: UTF8.self))
            } catch let failure as CloudShareSeal.Failure {
                print(#"{"failure":"\#(failure)"}"#)
                exit(2)
            }
        case "vectors":
            print(try vectors())
        default:
            FileHandle.standardError.write(Data("usage: seal <file> <name> <type> <out> | open <sealed> <key> <out> | vectors\n".utf8))
            exit(64)
        }
    }

    /// Fixed keys and nonces, so the output is the same on every run and on every machine.
    static func vectors() throws -> String {
        let cases: [(name: String, key: [UInt8], nonce: [UInt8], filename: String, contentType: String, file: [UInt8])] = [
            ("PNG screenshot", Array(0..<32), Array(0..<12), "Screenshot 2026-10-23 at 09.41.png", "image/png",
             [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("not really pixels".utf8)),
            ("PDF with a non-ASCII name", (0..<32).map { UInt8(255 - $0) }, Array(repeating: 0xA5, count: 12),
             "Rechnung März – 日本.pdf", "application/pdf", Array("%PDF-1.7\n%%EOF\n".utf8)),
            ("Empty file", Array(repeating: 0x42, count: 32), Array(repeating: 0, count: 12), "empty.txt", "text/plain", []),
        ]
        let hex = { (bytes: Data) in bytes.map { String(format: "%02x", $0) }.joined() }
        let vectors = try cases.map { item -> [String: String] in
            let key = SymmetricKey(data: item.key)
            let plaintext = try CloudShareSeal.framed(Data(item.file), filename: item.filename, contentType: item.contentType)
            let sealed = try CloudShareSeal.seal(Data(item.file), filename: item.filename, contentType: item.contentType,
                                                 key: key, nonce: try AES.GCM.Nonce(data: item.nonce))
            return [
                "name": item.name, "key": sealed.key, "nonce": hex(Data(item.nonce)), "filename": item.filename,
                "contentType": item.contentType, "file": hex(Data(item.file)), "plaintext": hex(plaintext), "sealed": hex(sealed.combined),
            ]
        }
        let document: [String: Any] = [
            "format": "Sukusho sealed share v1: AES-256-GCM (CryptoKit seal, WebCrypto decrypt), 12-byte nonce || ciphertext || 16-byte tag, no AAD; plaintext = 4-byte big-endian header length, UTF-8 JSON {contentType, filename}, file bytes; key = 32 bytes base64url without padding, after # in the link.",
            "vectors": vectors,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
