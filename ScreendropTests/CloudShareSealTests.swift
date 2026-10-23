// Encrypted share links: the seal's known answers (the same file is checked into the
// Worker, which opens it with WebCrypto), failures, the 32 MB cap, the Keychain naming
// and the link's fragment. scripts/check-sealed-share-interop.mjs crosses the platforms.
import CryptoKit
import Foundation
import Testing

private final class SealFixtureBundle {}

@MainActor
@Suite
struct CloudShareSealTests {
    struct Vector: Decodable {
        let name, key, nonce, filename, contentType, file, plaintext, sealed: String
    }

    private func vectors() throws -> [Vector] {
        struct Document: Decodable { let vectors: [Vector] }
        let url = try #require(Bundle(for: SealFixtureBundle.self).url(forResource: "sealed-share-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)).vectors
    }

    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    @Test func knownAnswers() throws {
        let vectors = try vectors()
        #expect(vectors.count == 3)
        for vector in vectors {
            let key = SymmetricKey(data: try #require(CloudShareSeal.decodedKey(vector.key)))
            let file = bytes(vector.file)
            #expect(try CloudShareSeal.framed(file, filename: vector.filename, contentType: vector.contentType) == bytes(vector.plaintext))
            let sealed = try CloudShareSeal.seal(file, filename: vector.filename, contentType: vector.contentType,
                                                 key: key, nonce: AES.GCM.Nonce(data: bytes(vector.nonce)))
            #expect(sealed.combined == bytes(vector.sealed), "\(vector.name)")
            #expect(sealed.key == vector.key)
            #expect(try CloudShareSeal.open(bytes(vector.sealed), key: vector.key)
                    == .init(filename: vector.filename, contentType: vector.contentType, bytes: file))
        }
    }

    @Test func freshKeyAndNonceEachTime() throws {
        let file = Data("same file".utf8)
        let first = try CloudShareSeal.seal(file, filename: "a.png", contentType: "image/png")
        let second = try CloudShareSeal.seal(file, filename: "a.png", contentType: "image/png")
        #expect(first.key != second.key)
        #expect(first.combined.prefix(12) != second.combined.prefix(12))
        #expect(first.key.count == 43)
        #expect(try CloudShareSeal.open(first.combined, key: first.key).bytes == file)
    }

    @Test func tamperingAndWrongKeysFail() throws {
        let vector = try #require(try vectors().first)
        let sealed = bytes(vector.sealed)
        for index in [0, 11, 12, sealed.count / 2, sealed.count - 1] {
            var tampered = sealed
            tampered[index] ^= 0x01
            #expect(throws: CloudShareSeal.Failure.wrongKey) { try CloudShareSeal.open(tampered, key: vector.key) }
        }
        #expect(throws: CloudShareSeal.Failure.wrongKey) { try CloudShareSeal.open(sealed.prefix(sealed.count - 1), key: vector.key) }
        let other = CloudShareSeal.encodedKey(SymmetricKey(size: .bits256))
        #expect(throws: CloudShareSeal.Failure.wrongKey) { try CloudShareSeal.open(sealed, key: other) }
        for malformed in ["", String(vector.key.dropLast()), vector.key + "A", vector.key.replacingOccurrences(of: "A", with: "+")] {
            #expect(CloudShareSeal.decodedKey(malformed) == nil, "\(malformed)")
            #expect(throws: CloudShareSeal.Failure.wrongKey) { try CloudShareSeal.open(sealed, key: malformed) }
        }
    }

    @Test func framingIsChecked() throws {
        let header = Data(#"{"contentType":"image/png","filename":"a.png"}"#.utf8)
        func framed(length: UInt32, _ body: Data) -> Data {
            withUnsafeBytes(of: length.bigEndian) { Data($0) } + body
        }
        #expect(try CloudShareSeal.unframed(framed(length: UInt32(header.count), header + Data([1, 2])))
                == .init(filename: "a.png", contentType: "image/png", bytes: Data([1, 2])))
        let bad: [Data] = [
            Data([0, 0, 0]),
            framed(length: UInt32(header.count + 1), header),
            framed(length: 4097, Data(count: 5000)),
            framed(length: 3, Data("{}x".utf8)),
            framed(length: 2, Data("{}".utf8)),
            framed(length: 15, Data(#"{"filename":""}"#.utf8)),
            framed(length: 2, Data([0xC3, 0x28])),
        ]
        for data in bad {
            #expect(throws: CloudShareSeal.Failure.unreadable) { try CloudShareSeal.unframed(data) }
        }
    }

    @Test func refusesFilesOverTheCap() throws {
        #expect(throws: CloudShareSeal.Failure.tooLarge) {
            try CloudShareSeal.seal(Data(count: CloudShareSeal.maxFileBytes + 1), filename: "big.bin", contentType: "application/octet-stream")
        }
        let atCap = try CloudShareSeal.seal(Data(count: CloudShareSeal.maxFileBytes), filename: "cap.bin", contentType: "application/octet-stream")
        #expect(atCap.combined.count > CloudShareSeal.maxFileBytes)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sukusho-SealTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("shot.png")
        let large = folder.appendingPathComponent("large.zip")
        try Data(count: 10).write(to: small)
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(CloudShareSeal.maxFileBytes + 1))
        try handle.close()
        #expect(CloudShareSeal.unavailableReason(fileURLs: [small]) == nil)
        #expect(CloudShareSeal.unavailableReason(fileURLs: [small, large]) == CloudShareSeal.unavailableNote)
        #expect(CloudShareSeal.unavailableReason(fileURLs: [small], isRecording: true) == CloudShareSeal.unavailableNote)
        #expect(CloudShareSeal.unavailableNote == "Encrypted links are for images and files up to 32 MB for now.")
    }

    @Test func keysLiveUnderTheUploadID() throws {
        var items: [String: String] = [:]
        let keys = CloudShareKeys(read: { items[$0] }, write: { items[$0] = $1 }, delete: { items[$0] = nil })
        let key = try CloudShareSeal.seal(Data(), filename: "a", contentType: "").key
        keys.save(key, uploadID: "0123456789abcdef")
        #expect(items == ["cloud_share_key_0123456789abcdef": key])
        #expect(keys.key(uploadID: "0123456789abcdef") == key)
        #expect(keys.key(uploadID: "fedcba9876543210") == nil)
        // Something else stored under the name is no key.
        items["cloud_share_key_fedcba9876543210"] = "not a key"
        #expect(keys.key(uploadID: "fedcba9876543210") == nil)
        // Deleting the upload deletes its key, and only its key.
        keys.remove(uploadID: "0123456789abcdef")
        #expect(keys.key(uploadID: "0123456789abcdef") == nil)
        #expect(items.keys.sorted() == ["cloud_share_key_fedcba9876543210"])
    }

    @Test func linksCarryTheKeyInTheFragment() {
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        #expect(CloudShareSeal.link("https://share.example/0123456789abcdef", key: key)
                == "https://share.example/0123456789abcdef#" + key)
        #expect(CloudShareSeal.link("https://share.example/0123456789abcdef?t=12", key: key)
                == "https://share.example/0123456789abcdef?t=12#" + key)
        #expect(CloudShareSeal.link("https://share.example/0123456789abcdef#old", key: key)
                == "https://share.example/0123456789abcdef#" + key)
        #expect(CloudShareSeal.link("https://share.example/0123456789abcdef", key: nil)
                == "https://share.example/0123456789abcdef")
        // The fragment changes nothing about which upload a link names.
        #expect(CloudUploadList.uploadID(of: CloudShareSeal.link("https://share.example/0123456789abcdef", key: key)) == "0123456789abcdef")
    }

    @Test func workerSaysWhichUploadsAreSealed() throws {
        let json = Data(#"{"uploads":[{"id":"a1","url":"https://w.example/a1","filename":"a.png","mediaType":"image","createdAt":"2026-10-23T10:00:00Z","encrypted":true},{"id":"b2","url":"https://w.example/b2","filename":"b.png","mediaType":"image","createdAt":"2026-10-23T10:00:00Z"}],"next":null}"#.utf8)
        let page = try CloudUploadList.decode(json)
        #expect(page.uploads.map(\.encrypted) == [true, nil])
        // Quick Look reads a sealed share from /api/media, as its page does.
        #expect(CloudPreviewCache.mediaURL(for: page.uploads[0])?.path == "/api/media/a1")
        #expect(CloudPreviewCache.mediaURL(for: page.uploads[1])?.path == "/api/image/b2")
    }
}
