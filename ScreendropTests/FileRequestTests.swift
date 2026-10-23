import CoreServices
import Foundation
import Testing

struct FileRequestTests {
    private let base = "https://worker.example.invalid"

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func creationSendsTheDraftAsTheWorkerReadsIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = CloudFileRequestDraft()
        draft.message = "  Footage for Friday\n"
        draft.expiry = .week
        draft.maxFiles = 5
        draft.maxFileBytes = 500 * 1024 * 1024
        draft.maxTotalBytes = CloudFileRequestAPI.gibibyte
        let request = try #require(CloudFileRequestAPI.createRequest(workerBase: base, token: "secret", draft: draft, now: now))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == base + "/api/requests")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(request)
        #expect(Set(body.keys) == ["message", "password", "expiresAt", "maxFiles", "maxFileBytes", "maxTotalBytes"])
        #expect(body["message"] as? String == "Footage for Friday")
        #expect(body["password"] is NSNull)
        let expiresAt = try #require(body["expiresAt"] as? String)
        // The Worker's expiry pattern, and seven days on.
        #expect(expiresAt.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z/) != nil)
        #expect(try Date.ISO8601FormatStyle().parse(expiresAt) == now.addingTimeInterval(7 * 86_400))
        #expect(body["maxFiles"] as? Int == 5)
        #expect((body["maxFileBytes"] as? NSNumber)?.int64Value == Int64(500 * 1024 * 1024))
        #expect((body["maxTotalBytes"] as? NSNumber)?.int64Value == CloudFileRequestAPI.gibibyte)

        draft.password = "correct horse"
        #expect(try json(try #require(CloudFileRequestAPI.createRequest(workerBase: base, token: "t", draft: draft)))["password"] as? String == "correct horse")
    }

    @Test func creationRefusesWhatTheWorkerWould() {
        func refused(_ change: (inout CloudFileRequestDraft) -> Void) -> Bool {
            var draft = CloudFileRequestDraft()
            change(&draft)
            return CloudFileRequestAPI.createRequest(workerBase: base, token: "t", draft: draft) == nil
        }
        #expect(!refused { _ in })
        #expect(refused { $0.expiry = .never })
        #expect(refused { $0.password = String(repeating: "p", count: 129) })
        #expect(refused { $0.message = String(repeating: "m", count: 1001) })
        // 500 emoji are 1,000 UTF-16 units, as the Worker counts them; one more is over.
        #expect(!refused { $0.message = String(repeating: "😀", count: 500) })
        #expect(refused { $0.message = String(repeating: "😀", count: 501) })
        #expect(refused { $0.maxFiles = 0 })
        #expect(refused { $0.maxFileBytes = CloudFileRequestAPI.maxFileBytes + 1 })
        #expect(CloudFileRequestAPI.createRequest(workerBase: "not a url", token: "t", draft: CloudFileRequestDraft()) == nil)
        #expect(!CloudFileRequestAPI.expiryChoices.contains(.never))
    }

    @Test func closeListAndDownloadUseTheOwnerRoutes() throws {
        let close = try #require(CloudFileRequestAPI.closeRequest(workerBase: base, token: "t", id: "0123456789abcdef"))
        #expect(close.httpMethod == "DELETE")
        #expect(close.url?.absoluteString == base + "/api/requests/0123456789abcdef")
        #expect(close.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(CloudFileRequestAPI.closeRequest(workerBase: base, token: "t", id: "../uploads") == nil)
        let list = try #require(CloudFileRequestAPI.listRequest(workerBase: base, token: "t"))
        #expect(list.httpMethod == "GET" && list.url?.path == "/api/requests")
        let download = try #require(CloudFileRequestAPI.downloadRequest(workerBase: base, token: "t", id: "fedcba9876543210"))
        #expect(download.url?.absoluteString == base + "/api/media/fedcba9876543210")
        #expect(download.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let received = try #require(CloudUploadList.request(workerBase: base, token: "t", offset: 0, received: true))
        #expect(received.url?.query()?.contains("received=1") == true)
        #expect(CloudUploadList.request(workerBase: base, token: "t", offset: 0)?.url?.query()?.contains("received") == false)
    }

    @Test func requestsDecodeTheWorkersShape() throws {
        // As POST /api/requests answered in checks/file-requests-local.mjs.
        let created = try CloudFileRequestAPI.decodeCreated(Data("""
        {"message":"Please send","expiresAt":"2026-10-23T20:00:00.000Z","maxFiles":20,"maxFileBytes":2147483648,
         "maxTotalBytes":10737418240,"id":"0123456789abcdef","hasPassword":true,"createdAt":"2026-10-23T19:00:00Z",
         "filesReceived":0,"bytesReceived":0,"url":"https://worker.example.invalid/r/0123456789abcdefAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
        """.utf8))
        #expect(created.id == "0123456789abcdef")
        #expect(created.hasPassword && created.maxFileBytes == 2_147_483_648 && created.maxTotalBytes == 10_737_418_240)
        #expect(created.url?.hasSuffix("/r/0123456789abcdefAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == true)
        let listed = try CloudFileRequestAPI.decodeList(Data("""
        {"requests":[{"id":"0123456789abcdef","message":"","hasPassword":false,"expiresAt":"2026-10-30T19:00:00Z",
         "maxFiles":3,"maxFileBytes":1000,"maxTotalBytes":1500,"createdAt":"2026-10-23T19:00:00Z","filesReceived":2,"bytesReceived":1400}]}
        """.utf8))
        #expect(listed.count == 1 && listed[0].url == nil && listed[0].filesReceived == 2 && listed[0].bytesReceived == 1400)
    }

    @Test func receivedUploadsDecodeAndOldWorkersStillDecode() throws {
        let page = try CloudUploadList.decode(Data("""
        {"uploads":[
          {"id":"aaaaaaaaaaaaaaaa","url":"https://w.example/aaaaaaaaaaaaaaaa","title":null,"filename":"brief.pdf","contentType":"application/octet-stream",
           "mediaType":"file","mediaKey":"uploads/aaaaaaaaaaaaaaaa/brief.pdf","size":64,"createdAt":"2026-10-23T19:00:00Z","views":0,
           "thumbnailUrl":null,"expiresAt":null,"hasPassword":false,"requestId":"0123456789abcdef","someLaterField":[1,2]},
          {"id":"bbbbbbbbbbbbbbbb","url":"https://w.example/bbbbbbbbbbbbbbbb","title":"Shot","filename":"shot.png","mediaType":"image",
           "size":10,"createdAt":"2026-10-23T18:00:00Z","views":3,"thumbnailUrl":null,"expiresAt":null,"requestId":null},
          {"id":"cccccccc","url":"https://w.example/cccccccc","title":null,"filename":"old.png","mediaType":"image",
           "createdAt":"2026-10-22T18:00:00Z","thumbnailUrl":null}
        ],"next":null}
        """.utf8))
        #expect(page.uploads.map(\.isReceived) == [true, false, false])
        #expect(page.uploads[0].requestId == "0123456789abcdef")
        #expect(page.uploads[0].kindTitle == "Received file")
        #expect(page.uploads[1].kindTitle == "Screenshot")
    }

    private func upload(_ id: String, received: Bool, name: String = "file.bin", size: Int? = 2048) -> CloudUpload {
        CloudUpload(id: id, url: "https://w.example/" + id, title: nil, filename: name, mediaType: received ? "file" : "image",
                    size: size, duration: nil, createdAt: .now, views: nil, thumbnailUrl: nil,
                    requestId: received ? "0123456789abcdef" : nil)
    }

    @Test func onlyReceivedFilesNotSeenBeforeNotify() {
        let first = [upload("r1", received: true), upload("own", received: false)]
        // The first look at a Worker only learns what's there.
        #expect(ReceivedFiles.newFiles(in: first, known: nil).isEmpty)
        let known = ReceivedFiles.known(after: first)
        #expect(known == ["r1"])
        #expect(ReceivedFiles.newFiles(in: first, known: known).isEmpty)
        let later = [upload("r2", received: true), upload("r1", received: true), upload("own2", received: false)]
        #expect(ReceivedFiles.newFiles(in: later, known: known).map(\.id) == ["r2"])
        // A file deleted since is forgotten; it can't come back as new.
        #expect(ReceivedFiles.known(after: [upload("r2", received: true)]) == ["r2"])
        #expect(ReceivedFiles.newFiles(in: later, known: []).map(\.id) == ["r2", "r1"])
    }

    @Test func notificationNamesTheFiles() {
        let one = ReceivedFiles.notificationText(for: [upload("a", received: true, name: "brief.pdf", size: 2048)])
        #expect(one.title == "File received")
        #expect(one.body == "brief.pdf · " + ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
        let five = ReceivedFiles.notificationText(for: ["a", "b", "c", "d", "e"].map { upload($0, received: true, name: $0 + ".mov") })
        #expect(five.title == "5 files received")
        #expect(five.body == "a.mov, b.mov, c.mov and 2 more")
    }

    @Test func downloadsNeverReplaceAFileAndStayPlainNames() {
        let folder = URL(filePath: "/Downloads", directoryHint: .isDirectory)
        let taken: Set<String> = ["/Downloads/brief.pdf", "/Downloads/brief 2.pdf", "/Downloads/notes"]
        let exists = { (url: URL) in taken.contains(url.path(percentEncoded: false)) }
        #expect(ReceivedFiles.destination(for: "brief.pdf", in: folder, exists: exists).lastPathComponent == "brief 3.pdf")
        #expect(ReceivedFiles.destination(for: "notes", in: folder, exists: exists).lastPathComponent == "notes 2")
        #expect(ReceivedFiles.destination(for: "a:b.txt", in: folder, exists: exists).lastPathComponent == "a-b.txt")
        #expect(ReceivedFiles.destination(for: ".zshrc", in: folder, exists: exists).lastPathComponent == "zshrc")
        #expect(ReceivedFiles.destination(for: "...", in: folder, exists: exists).lastPathComponent == "Received file")
        #expect(ReceivedFiles.destination(for: "clip.mov", in: folder, exists: exists).deletingLastPathComponent().path() == "/Downloads/")
    }
    @Test func formatCharactersLeaveNamesAndJoinersStay() throws {
        let uploads = try CloudUploadList.decode(Data("""
        {"uploads":[
          {"id":"aaaaaaaaaaaaaaaa","url":"https://w.example/a","title":"Brief \\u202Ev2","filename":"invoice\\u202Efdp.exe","mediaType":"file",
           "createdAt":"2026-10-23T19:00:00Z","thumbnailUrl":null,"requestId":"0123456789abcdef"},
          {"id":"bbbbbbbbbbbbbbbb","url":"https://w.example/b","title":null,"filename":"family \\ud83d\\udc68\\u200d\\ud83d\\udc69\\u200d\\ud83d\\udc67.png",
           "mediaType":"file","createdAt":"2026-10-23T19:00:00Z","thumbnailUrl":null,"requestId":"0123456789abcdef"}
        ],"next":null}
        """.utf8)).uploads
        #expect(uploads[0].filename == "invoicefdp.exe")
        #expect(uploads[0].title == "Brief v2")
        #expect(uploads[1].filename == "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.png")
        #expect(ReceivedFiles.notificationText(for: [uploads[0]]).body == "invoicefdp.exe")
        let folder = URL(filePath: "/Downloads", directoryHint: .isDirectory)
        #expect(ReceivedFiles.destination(for: "a\u{202E}b\u{2066}.txt", in: folder, exists: { _ in false }).lastPathComponent == "ab.txt")
    }

    @Test func aFileThatCantBeQuarantinedDoesNotStay() throws {
        struct MarkFailed: Error {}
        let root = FileManager.default.temporaryDirectory.appending(path: "FileRequestTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
        let first = root.appending(path: "first.tmp")
        try Data("one".utf8).write(to: first)
        #expect(throws: MarkFailed.self) { try ReceivedFiles.save(first, as: "brief.pdf", in: folder) { _ in throw MarkFailed() } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        let second = root.appending(path: "second.tmp")
        try Data("two".utf8).write(to: second)
        let saved = try ReceivedFiles.save(second, as: "brief.pdf", in: folder)
        #expect(saved.lastPathComponent == "brief.pdf")
        let quarantine = try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Sukusho")
    }
}
