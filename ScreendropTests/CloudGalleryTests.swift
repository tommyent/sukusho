import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Answers every request from the test's route and records it with its body,
/// which upload tasks hand over as a stream.
nonisolated private final class GalleryURLProtocol: URLProtocol, @unchecked Sendable {
    struct Call: @unchecked Sendable {
        let request: URLRequest
        let body: Data
        var method: String { request.httpMethod ?? "" }
        var path: String { request.url?.path ?? "" }
        var line: String { method + " " + path }
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    }
    typealias Route = @Sendable (Call, [Call]) -> (Int, String)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var route: Route = { _, _ in (500, "") }
    nonisolated(unsafe) private static var recorded: [Call] = []

    static func configure(_ route: @escaping Route) { lock.withLock { self.route = route; recorded = [] } }
    static var calls: [Call] { lock.withLock { recorded } }
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GalleryURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { body.append(buffer, count: count) }
            stream.close()
        }
        let call = Call(request: request, body: body)
        let reply = Self.lock.withLock {
            Self.recorded.append(call)
            return Self.route(call, Self.recorded)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class ProgressLog {
    var indices: [Int] = []
}

@Suite(.serialized) @MainActor
struct CloudGalleryTests {
    private let base = "https://worker.example.invalid"
    nonisolated private static let ids = ["a1b2c3d4e5f60001", "a1b2c3d4e5f60002", "a1b2c3d4e5f60003"]
    nonisolated private static let galleryID = "9f8e7d6c5b4a0001"

    // MARK: - Fixtures

    /// A PNG of this size on disk, transparent where `clear`.
    private func image(_ name: String, width: Int, height: Int, clear: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !clear {
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func images() throws -> [CloudGalleryShare.Image] {
        [
            .init(fileURL: try image("wide.png", width: 1600, height: 1000), title: "Morning ☀︎"),
            .init(fileURL: try image("tall.png", width: 600, height: 1200), title: nil),
            .init(fileURL: try image("small.png", width: 300, height: 200), title: "Third"),
        ]
    }

    nonisolated private static func galleryJSON(hasPassword: Bool = true) -> String {
        """
        {"id":"\(galleryID)","url":"https://worker.example.invalid/g/\(galleryID)","title":"Trip","createdAt":"2026-11-08T10:00:00.000Z",
         "expiresAt":"2026-11-15T10:00:00.000Z","hasPassword":\(hasPassword),"socialEnabled":true,"allowAnonymousComments":false,
         "views":0,"itemCount":3,"coverUrl":"https://worker.example.invalid/api/poster/\(ids[0])","uploadIds":\(ids)}
        """
    }

    /// The Worker as the contract has it: the n-th PUT is upload n; `fail` answers instead where it matches.
    private func worker(fail: @escaping @Sendable (GalleryURLProtocol.Call, [GalleryURLProtocol.Call]) -> (Int, String)? = { _, _ in nil },
                        hasPassword: Bool = true) {
        GalleryURLProtocol.configure { call, calls in
            if let failure = fail(call, calls) { return failure }
            switch (call.method, call.path) {
            case ("PUT", "/api/upload"):
                let id = Self.ids[calls.count { $0.line == "PUT /api/upload" } - 1]
                return (201, #"{"id":"\#(id)","url":"https://worker.example.invalid/\#(id)","filename":"x.png","size":1,"mediaKey":"uploads/\#(id)/x.png"}"#)
            case ("POST", let path) where path.hasPrefix("/api/assets/"): return (200, #"{"stored":["poster"]}"#)
            case ("POST", "/api/galleries"): return (201, Self.galleryJSON(hasPassword: hasPassword))
            case ("DELETE", _): return (200, #"{"deleted":true}"#)
            default: return (404, #"{"error":"Not found"}"#)
            }
        }
    }

    private var settings: CloudGalleryShare.Settings {
        .init(title: "Trip", expiresAt: Date(timeIntervalSince1970: 1_794_736_800), password: "hunter 2",
              socialEnabled: true, allowAnonymousComments: false)
    }

    private func share(_ images: [CloudGalleryShare.Image], _ settings: CloudGalleryShare.Settings,
                       progress: ProgressLog? = nil) async throws -> (gallery: CloudGallery, items: [CloudGalleryShare.Item]) {
        let share = CloudGalleryShare(workerBase: base, token: "secret", session: GalleryURLProtocol.session)
        return try await share.share(images, settings: settings) { progress?.indices.append($0) }
    }

    /// The error the share must throw.
    private func failure(_ images: [CloudGalleryShare.Image], _ settings: CloudGalleryShare.Settings) async -> (any Error)? {
        await #expect(throws: (any Error).self) { try await share(images, settings) }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Menu and version

    @Test func theLibraryOffersAGalleryForSeveralImagesOnly() {
        #expect(!CloudGalleryAPI.canShare(count: 1, includesRecording: false))
        #expect(CloudGalleryAPI.canShare(count: 2, includesRecording: false))
        #expect(CloudGalleryAPI.canShare(count: 100, includesRecording: false))
        #expect(!CloudGalleryAPI.canShare(count: 101, includesRecording: false))
        #expect(!CloudGalleryAPI.canShare(count: 3, includesRecording: true))
    }

    @Test func galleriesNeedWorkerTwo() async {
        #expect(!CloudGalleryAPI.supportsGalleries(version: nil))
        #expect(!CloudGalleryAPI.supportsGalleries(version: "1.1.0"))
        #expect(!CloudGalleryAPI.supportsGalleries(version: "1.99.0"))
        #expect(CloudGalleryAPI.supportsGalleries(version: "2.0.0"))
        #expect(CloudGalleryAPI.supportsGalleries(version: "2.0.1"))
        #expect(CloudGalleryAPI.supportsGalleries(version: "10.0.0"))

        GalleryURLProtocol.configure { call, _ in call.line == "GET /api/version" ? (200, #"{"version":"2.0.0"}"#) : (404, "") }
        #expect(await CloudGalleryAPI.workerVersion(workerBase: base, session: GalleryURLProtocol.session) == "2.0.0")
        // A Worker without the route, or one that can't be read, has no galleries.
        GalleryURLProtocol.configure { _, _ in (404, "Not found") }
        #expect(await CloudGalleryAPI.workerVersion(workerBase: base, session: GalleryURLProtocol.session) == nil)
        GalleryURLProtocol.configure { _, _ in (200, "<html>") }
        #expect(await CloudGalleryAPI.workerVersion(workerBase: base, session: GalleryURLProtocol.session) == nil)
    }

    // MARK: - Sharing

    @Test func eachImageGoesUpWithItsPosterThenTheGallery() async throws {
        worker()
        let images = try images()
        let progress = ProgressLog()
        let result = try await share(images, settings, progress: progress)
        let calls = GalleryURLProtocol.calls
        #expect(calls.map(\.line) == [
            "PUT /api/upload", "POST /api/assets/\(Self.ids[0])",
            "PUT /api/upload", "POST /api/assets/\(Self.ids[1])",
            "PUT /api/upload", "POST /api/assets/\(Self.ids[2])",
            "POST /api/galleries",
        ])
        #expect(progress.indices == [0, 1, 2])
        #expect(result.items.map(\.id) == Self.ids)
        #expect(result.gallery.id == Self.galleryID)
        #expect(calls.allSatisfy { $0.header("Authorization") == "Bearer secret" })

        // Each image: a single upload with the gallery's expiry and comment choices, no password, not sealed.
        let puts = calls.filter { $0.method == "PUT" }
        let sizes = [(1600, 1000), (600, 1200), (300, 200)]
        for (index, put) in puts.enumerated() {
            #expect(put.header("Content-Type") == "image/png")
            #expect(put.header("X-Filename") == images[index].fileURL.lastPathComponent)
            #expect(put.header("X-Media-Type") == "image")
            #expect(put.header("X-Width") == String(sizes[index].0))
            #expect(put.header("X-Height") == String(sizes[index].1))
            #expect(put.header("X-Social-Enabled") == "true")
            #expect(put.header("X-Allow-Anonymous-Comments") == "false")
            #expect(put.header("X-Expires-At") == settings.expiresAt?.formatted(.iso8601))
            #expect(put.header("X-Password") == nil)
            #expect(put.header("X-Encrypted") == nil)
            let original = try Data(contentsOf: images[index].fileURL)
            #expect(put.body == original)
        }
        #expect(puts[0].header("X-Title") == "Morning ☀︎".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        #expect(puts[1].header("X-Title") == nil)

        // Each poster: one JPEG part, 800 px on the long edge at most, for the upload's current media.
        let posters = calls.filter { $0.path.hasPrefix("/api/assets/") }
        let expected = [[800, 500], [400, 800], [300, 200]]
        for (index, poster) in posters.enumerated() {
            let type = try #require(poster.header("Content-Type"))
            #expect(type.hasPrefix("multipart/form-data; boundary="))
            #expect(poster.header("X-Media-Key") == "uploads/\(Self.ids[index])/x.png")
            let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
            let head = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"poster\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
            let tail = Data("\r\n--\(boundary)--\r\n".utf8)
            #expect(poster.body.starts(with: head))
            #expect(poster.body.suffix(tail.count) == tail)
            let jpeg = poster.body.dropFirst(head.count).dropLast(tail.count)
            let source = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
            let thumb = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect([thumb.width, thumb.height] == expected[index])
        }

        // The gallery: the ids in Library order, and the options, password included.
        let create = try #require(calls.last)
        #expect(create.header("Content-Type") == "application/json")
        let body = try json(create.body)
        #expect(Set(body.keys) == ["title", "uploadIds", "expiresAt", "password", "socialEnabled", "allowAnonymousComments"])
        #expect(body["title"] as? String == "Trip")
        #expect(body["uploadIds"] as? [String] == Self.ids)
        #expect(body["expiresAt"] as? String == settings.expiresAt?.formatted(.iso8601))
        #expect(body["password"] as? String == "hunter 2")
        #expect(body["socialEnabled"] as? Bool == true)
        #expect(body["allowAnonymousComments"] as? Bool == false)
    }

    @Test func anUntitledOpenGallerySendsNulls() async throws {
        worker()
        let open = CloudGalleryShare.Settings(title: nil, expiresAt: nil, password: nil, socialEnabled: false, allowAnonymousComments: true)
        let two = Array(try images().prefix(2))
        _ = try await share(two, open)
        let calls = GalleryURLProtocol.calls
        #expect(calls.filter { $0.method == "PUT" }.allSatisfy { $0.header("X-Expires-At") == nil && $0.header("X-Social-Enabled") == "false" })
        let body = try json(try #require(calls.last).body)
        #expect(body["title"] == nil)
        #expect(body["expiresAt"] is NSNull)
        #expect(body["password"] is NSNull)
        #expect(body["uploadIds"] as? [String] == Array(Self.ids.prefix(2)))
    }

    @Test func aFailedImageTakesDownTheOnesBeforeIt() async throws {
        worker(fail: { call, calls in
            call.line == "PUT /api/upload" && calls.count(where: { $0.line == "PUT /api/upload" }) == 3 ? (500, #"{"error":"R2 is down"}"#) : nil
        })
        let error = await failure(try images(), settings)
        #expect(error?.localizedDescription.contains("R2 is down") == true)
        #expect(GalleryURLProtocol.calls.map(\.line) == [
            "PUT /api/upload", "POST /api/assets/\(Self.ids[0])",
            "PUT /api/upload", "POST /api/assets/\(Self.ids[1])",
            "PUT /api/upload",
            "DELETE /api/upload/\(Self.ids[0])", "DELETE /api/upload/\(Self.ids[1])",
        ])
    }

    @Test func aFailedPosterTakesDownItsImageToo() async throws {
        worker(fail: { call, _ in call.line == "POST /api/assets/\(Self.ids[1])" ? (413, #"{"error":"Poster too large"}"#) : nil })
        #expect(await failure(try images(), settings)?.localizedDescription.contains("Poster too large") == true)
        #expect(GalleryURLProtocol.calls.suffix(2).map(\.line) == [
            "DELETE /api/upload/\(Self.ids[0])", "DELETE /api/upload/\(Self.ids[1])",
        ])
    }

    @Test func aRefusedGalleryTakesDownEveryImage() async throws {
        worker(fail: { call, _ in
            call.line == "POST /api/galleries" ? (400, #"{"error":"Upload is not an image","uploadId":"\#(Self.ids[1])"}"#) : nil
        })
        let error = await failure(try images(), settings)
        #expect(error?.localizedDescription.contains("Upload is not an image") == true)
        #expect(GalleryURLProtocol.calls.suffix(3).map(\.line) == Self.ids.map { "DELETE /api/upload/\($0)" })
    }

    @Test func aGalleryThatDroppedItsPasswordIsTakenDown() async throws {
        worker(hasPassword: false)
        let error = await failure(try images(), settings)
        guard case CloudUploadError.passwordUnsupported? = error else {
            Issue.record("Expected passwordUnsupported, got \(String(describing: error))")
            return
        }
        #expect(GalleryURLProtocol.calls.suffix(4).map(\.line)
                == ["DELETE /api/galleries/\(Self.galleryID)"] + Self.ids.map { "DELETE /api/upload/\($0)" })
    }

    @Test func cleanupThatFailsSaysWhatIsLeft() async throws {
        worker(fail: { call, _ in
            switch call.line {
            case "POST /api/galleries": (500, #"{"error":"D1 is down"}"#)
            case "DELETE /api/upload/\(Self.ids[1])": (500, "")
            case "DELETE /api/upload/\(Self.ids[2])": (404, "")
            default: nil
            }
        })
        let error = await failure(try images(), settings)
        guard case CloudGalleryError.notRemoved(let reason, let count)? = error else {
            Issue.record("Expected notRemoved, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("D1 is down"))
        #expect(count == 1)
    }

    @Test func aBadPasswordStopsBeforeAnythingGoesUp() async throws {
        worker()
        var long = settings
        long.password = String(repeating: "x", count: 129)
        #expect(await failure(try images(), long) != nil)
        #expect(GalleryURLProtocol.calls.isEmpty)
    }

    @Test func thumbnailsAreFlattenedOntoWhite() throws {
        let thumb = try CloudGalleryAPI.thumbnail(of: try image("clear.png", width: 1000, height: 1000, clear: true))
        #expect(thumb.width == 1000 && thumb.height == 1000)
        let source = try #require(CGImageSourceCreateWithData(thumb.jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 800 && image.height == 800)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -400, y: -400, width: 800, height: 800))
        #expect(pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245)
    }

    // MARK: - Uploads page

    @Test func galleriesListPageByPageAndHideTheirImages() async throws {
        let single = "b0b0b0b0b0b00001"
        let gallery = { (id: String, items: [String]) in
            #"{"id":"\#(id)","url":"https://worker.example.invalid/g/\#(id)","title":null,"createdAt":"2026-11-08T10:00:00Z","expiresAt":null,"hasPassword":false,"socialEnabled":true,"allowAnonymousComments":true,"views":4,"itemCount":\#(items.count),"coverUrl":"https://worker.example.invalid/api/poster/\#(items[0])","uploadIds":\#(items)}"#
        }
        GalleryURLProtocol.configure { call, _ in
            switch call.request.url?.query {
            case "limit=500&offset=0": (200, #"{"items":[\#(gallery(Self.galleryID, Array(Self.ids.prefix(2)))),\#(gallery("9f8e7d6c5b4a0002", [Self.ids[2]]))],"total":3}"#)
            case "limit=500&offset=2": (200, #"{"items":[\#(gallery("9f8e7d6c5b4a0003", ["c0c0c0c0c0c00001"]))],"total":3}"#)
            default: (500, "")
            }
        }
        let galleries = try await CloudGalleryAPI.list(workerBase: base, token: "secret", session: GalleryURLProtocol.session)
        #expect(galleries.map(\.id) == [Self.galleryID, "9f8e7d6c5b4a0002", "9f8e7d6c5b4a0003"])
        #expect(GalleryURLProtocol.calls.map(\.line) == ["GET /api/galleries", "GET /api/galleries"])
        #expect(GalleryURLProtocol.calls.allSatisfy { $0.header("Authorization") == "Bearer secret" })

        let uploads = try CloudUploadList.decode(Data("""
        {"uploads":[
          {"id":"\(Self.ids[0])","url":"https://worker.example.invalid/\(Self.ids[0])","title":null,"filename":"a.png","mediaType":"image","createdAt":"2026-11-08T10:00:00Z","galleryId":"\(Self.galleryID)"},
          {"id":"\(single)","url":"https://worker.example.invalid/\(single)","title":null,"filename":"b.png","mediaType":"image","createdAt":"2026-11-07T10:00:00Z","galleryId":null},
          {"id":"c0c0c0c0c0c00002","url":"https://worker.example.invalid/c0c0c0c0c0c00002","title":null,"filename":"old.png","mediaType":"image","createdAt":"2026-11-06T10:00:00Z"}
        ],"next":null}
        """.utf8)).uploads
        let all = uploads + galleries.map(\.upload)
        #expect(all.filter { CloudUploadList.isListed($0, files: false, received: false) }.map(\.id)
                == [single, "c0c0c0c0c0c00002", Self.galleryID, "9f8e7d6c5b4a0002", "9f8e7d6c5b4a0003"])
        #expect(all.filter { CloudUploadList.isListed($0, files: true, received: false) }.isEmpty)
        #expect(all.filter { CloudUploadList.isListed($0, files: false, received: true) }.isEmpty)

        let card = galleries[0].upload
        #expect(card.isGallery && !card.isVideo && !card.isFile && card.kindTitle == "Gallery")
        #expect(card.galleryItemIDs == Array(Self.ids.prefix(2)))
        #expect(card.thumbnailUrl == "https://worker.example.invalid/api/poster/\(Self.ids[0])")
        #expect(card.url == "https://worker.example.invalid/g/\(Self.galleryID)")
        #expect(card.hasPassword == false && card.expiresAt == nil && card.views == 4)
    }

    @Test func deletingAGalleryUsesItsOwnRoute() async throws {
        GalleryURLProtocol.configure { call, _ in call.method == "DELETE" ? (404, "") : (500, "") }
        // One already gone counts as deleted.
        try await CloudGalleryAPI.delete(galleryID: Self.galleryID, workerBase: base, token: "secret", session: GalleryURLProtocol.session)
        #expect(GalleryURLProtocol.calls.map(\.line) == ["DELETE /api/galleries/\(Self.galleryID)"])
        #expect(CloudGalleryAPI.deleteRequest(workerBase: base, token: "secret", galleryID: "../uploads") == nil)
        GalleryURLProtocol.configure { _, _ in (500, #"{"error":"D1 is down"}"#) }
        await #expect(throws: (any Error).self) {
            try await CloudGalleryAPI.delete(galleryID: Self.galleryID, workerBase: base, token: "secret", session: GalleryURLProtocol.session)
        }
    }
}
