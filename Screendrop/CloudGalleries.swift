//
//  CloudGalleries.swift
//  Screendrop
//
//  Several Library images shared behind one link. Each image goes up as an
//  ordinary upload with its own page, comments and likes; the gallery lists
//  them in order and holds the password. Apart from the app, so the requests
//  can be checked without a real token or Worker.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A gallery on the Worker, as POST and GET /api/galleries answer.
nonisolated struct CloudGallery: Decodable, Hashable, Sendable {
    let id: String
    let url: String
    let title: String?
    let createdAt: Date
    let expiresAt: Date?
    let hasPassword: Bool
    let socialEnabled: Bool
    let allowAnonymousComments: Bool
    let views: Int?
    let coverUrl: String?
    let uploadIds: [String]

    /// Its card on the Uploads page, beside the uploads.
    var upload: CloudUpload {
        CloudUpload(id: id, url: url, title: title.map(CloudUpload.shown), filename: "", mediaType: "gallery", size: nil,
                    duration: nil, createdAt: createdAt, views: views, thumbnailUrl: coverUrl, expiresAt: expiresAt,
                    allowAnonymousComments: allowAnonymousComments, socialEnabled: socialEnabled, hasPassword: hasPassword,
                    galleryItemIDs: uploadIds)
    }
}

nonisolated enum CloudGalleryError: LocalizedError {
    /// The share failed, and some images it had sent are still on the Worker.
    case notRemoved(String, count: Int)

    var errorDescription: String? {
        switch self {
        case .notRemoved(let reason, let count):
            reason + "\n\n" + (count == 1 ? "One image that went up couldn’t be removed. Delete it on the Uploads page."
                : "\(count) images that went up couldn’t be removed. Delete them on the Uploads page.")
        }
    }
}

nonisolated enum CloudGalleryAPI {
    static let maxImages = 100
    static let minimumWorkerVersion = "2.0.0"
    /// The thumbnail each image sends as its poster, for the gallery's grid.
    static let thumbnailPixels = 800

    /// The Library offers a gallery for several images, up to what one holds, and never for recordings.
    static func canShare(count: Int, includesRecording: Bool) -> Bool {
        (2...maxImages).contains(count) && !includesRecording
    }

    /// Galleries need Worker 2.0.0; a Worker that doesn't say its version counts as older.
    static func supportsGalleries(version: String?) -> Bool {
        guard let version else { return false }
        return version.compare(minimumWorkerVersion, options: .numeric) != .orderedAscending
    }

    /// GET /api/version's version, or nil when the Worker has no such route or can't be reached.
    static func workerVersion(workerBase: String, session: URLSession = .shared) async -> String? {
        struct Reply: Decodable { let version: String? }
        guard let url = URL(string: workerBase + "/api/version"), url.host != nil else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.version
    }

    // MARK: - Owner routes

    static func listRequest(workerBase: String, token: String, offset: Int) -> URLRequest? {
        var components = URLComponents(string: workerBase + "/api/galleries")
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(CloudUploadList.pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components?.url, url.host != nil else { return nil }
        return authorized(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30), "GET", token)
    }

    struct Page: Decodable {
        let items: [CloudGallery]
        let total: Int
    }

    static func decodePage(_ data: Data) throws -> Page {
        try CloudUploadList.decoder.decode(Page.self, from: data)
    }

    /// Every gallery, newest first, without repeats.
    static func list(workerBase: String, token: String, session: URLSession = .shared) async throws -> [CloudGallery] {
        var galleries: [CloudGallery] = []
        var seen: Set<String> = []
        var offset = 0
        while true {
            guard let request = listRequest(workerBase: workerBase, token: token, offset: offset) else {
                throw CloudUploadError.invalidURL
            }
            let (data, response) = try await session.data(for: request)
            try expect(200, data, response)
            let page = try decodePage(data)
            let new = page.items.filter { seen.insert($0.id).inserted }
            galleries += new
            offset += page.items.count
            // Only forward, so a confused Worker can't loop the app.
            if new.isEmpty || offset >= page.total { return galleries }
        }
    }

    /// POST /api/galleries for uploads already on the Worker, in display order.
    static func createRequest(workerBase: String, token: String, uploadIDs: [String],
                              settings: CloudGalleryShare.Settings) -> URLRequest? {
        guard let url = URL(string: workerBase + "/api/galleries"), url.host != nil else { return nil }
        var body: [String: Any] = [
            "uploadIds": uploadIDs,
            "expiresAt": settings.expiresAt.map { $0.formatted(.iso8601) } ?? NSNull(),
            "password": settings.password ?? NSNull(),
            "socialEnabled": settings.socialEnabled,
            "allowAnonymousComments": settings.allowAnonymousComments,
        ]
        if let title = settings.title { body["title"] = title }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { return nil }
        var request = authorized(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60), "POST", token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// DELETE /api/galleries/<id>, which also deletes every image in it.
    static func deleteRequest(workerBase: String, token: String, galleryID: String) -> URLRequest? {
        guard CloudPreviewCache.isSafeID(galleryID), let url = URL(string: workerBase + "/api/galleries/" + galleryID),
              url.host != nil else { return nil }
        return authorized(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60), "DELETE", token)
    }

    /// Deletes a gallery and its images. One that's already gone counts as deleted.
    static func delete(galleryID: String, workerBase: String, token: String, session: URLSession = .shared) async throws {
        guard let request = deleteRequest(workerBase: workerBase, token: token, galleryID: galleryID) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try expect(200, data, response)
    }

    /// DELETE /api/upload/<id>, the single delete.
    static func deleteUploadRequest(workerBase: String, token: String, uploadID: String) -> URLRequest? {
        guard CloudPreviewCache.isSafeID(uploadID), let url = URL(string: workerBase + "/api/upload/" + uploadID),
              url.host != nil else { return nil }
        return authorized(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30), "DELETE", token)
    }

    /// POST /api/assets/<id> with one `poster` part, as recordings send theirs.
    static func posterRequest(workerBase: String, token: String, uploadID: String, mediaKey: String?,
                              jpeg: Data) -> (request: URLRequest, body: Data)? {
        guard CloudPreviewCache.isSafeID(uploadID), let url = URL(string: workerBase + "/api/assets/" + uploadID),
              url.host != nil else { return nil }
        let boundary = "screendrop-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"poster\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = authorized(URLRequest(url: url, timeoutInterval: 120), "POST", token)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let mediaKey { request.setValue(mediaKey, forHTTPHeaderField: "X-Media-Key") }
        return (request, body)
    }

    // MARK: - Images

    /// The image's pixel size, and a JPEG of it at most 800 px on the long edge, flattened
    /// onto white: a window's transparent shadow would turn black in a JPEG.
    static func thumbnail(of fileURL: URL) throws -> (jpeg: Data, width: Int, height: Int) {
        let unreadable = CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: fileURL])
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
              ] as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw unreadable }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        let jpeg = NSMutableData()
        guard let flat = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw unreadable }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw unreadable }
        return (jpeg as Data, width, height)
    }

    /// What Delete from Cloud… on a Library card adds when its image is in a gallery, from the Uploads
    /// listing; nil when it isn't. An upload the listing doesn't have may be in one, unless the Worker
    /// predates galleries.
    static func deleteNote(uploadID: String?, uploads: [CloudUpload], galleriesPossible: Bool) -> String? {
        guard let uploadID else { return nil }
        guard let upload = uploads.first(where: { $0.id == uploadID && !$0.isGallery }) else {
            return galleriesPossible ? "If this image is in a gallery, it’s also removed from it. The gallery keeps its other images." : nil
        }
        guard let galleryID = upload.galleryId else { return nil }
        let gallery = uploads.first { $0.isGallery && $0.id == galleryID }
        let title = gallery?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = title.isEmpty ? "its gallery" : "its gallery “\(title)”"
        // The Worker deletes a gallery left empty.
        if gallery?.galleryItemIDs == [uploadID] { return "It’s the last image in \(name), so the gallery is deleted too." }
        return "This image is also removed from \(name). The gallery keeps its other images."
    }

    static func contentType(of fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: - Helpers

    private static func authorized(_ request: URLRequest, _ method: String, _ token: String) -> URLRequest {
        var request = request
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Throws the Worker's own `error` text when the status isn't the one expected.
    static func expect(_ status: Int, _ data: Data, _ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code != status else { return }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        throw CloudUploadError.serverError(code, json?["error"] as? String ?? String(decoding: data, as: UTF8.self))
    }
}

/// Shares several images as one gallery: each goes up as a single upload with its
/// thumbnail as its poster, then POST /api/galleries lists them. Nothing is left
/// half shared: any failure deletes the images that went up.
nonisolated struct CloudGalleryShare: Sendable {
    struct Image: Sendable {
        let fileURL: URL
        /// The image's own page title; nil lets the Worker use the file name.
        let title: String?
    }

    /// Set once for the whole gallery. The images get its expiry and comment
    /// choices; the password stays on the gallery.
    struct Settings: Sendable {
        var title: String?
        var expiresAt: Date?
        var password: String?
        var socialEnabled: Bool
        var allowAnonymousComments: Bool
    }

    struct Item: Sendable, Equatable {
        let id: String
        let url: String
        var mediaKey: String? = nil
    }

    typealias LargeUpload = @Sendable (_ file: URL, _ size: Int, _ metadata: UploadMetadata) async throws -> Item

    let workerBase: String
    let token: String
    var session: URLSession = .shared
    /// Files of at least `threshold` bytes go up in parts; nil sends every image in one PUT.
    var large: (threshold: Int, upload: LargeUpload)? = nil

    /// The gallery and its images in order. `progress` hears the index of each image as it starts.
    @concurrent
    func share(_ images: [Image], settings: Settings,
               progress: @MainActor @Sendable (Int) -> Void) async throws -> (gallery: CloudGallery, items: [Item]) {
        if let password = settings.password, !CloudUploadList.isValidPassword(password) { throw CloudUploadError.invalidPassword }
        var items: [Item] = []
        do {
            for (index, image) in images.enumerated() {
                try Task.checkCancellation()
                await progress(index)
                let thumbnail = try CloudGalleryAPI.thumbnail(of: image.fileURL)
                let item = try await upload(image, width: thumbnail.width, height: thumbnail.height, settings: settings)
                items.append(item)
                try await sendPoster(thumbnail.jpeg, for: item)
            }
            try Task.checkCancellation()
            return (try await create(items.map(\.id), settings: settings), items)
        } catch {
            let ids = items.map(\.id)
            // Detached, so a cancelled share still takes down what went up.
            let left = await Task.detached { await self.remove(ids) }.value
            if left > 0 { throw CloudGalleryError.notRemoved(error.localizedDescription, count: left) }
            throw error
        }
    }

    /// One image as a single upload with the gallery's expiry and comment choices, never a password or a seal.
    private func upload(_ image: Image, width: Int, height: Int, settings: Settings) async throws -> Item {
        let metadata = UploadMetadata(
            filename: image.fileURL.lastPathComponent, contentType: CloudGalleryAPI.contentType(of: image.fileURL),
            mediaType: "image", width: width, height: height, duration: nil, title: image.title,
            socialEnabled: settings.socialEnabled, expiresAt: settings.expiresAt,
            allowAnonymousComments: settings.allowAnonymousComments, password: nil
        )
        let size = try image.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let large, size >= large.threshold { return try await large.upload(image.fileURL, size, metadata) }
        guard let url = URL(string: workerBase + "/api/upload"), url.host != nil else { throw CloudUploadError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try metadata.apply(to: &request)
        let (data, response) = try await session.upload(for: request, from: Data(contentsOf: image.fileURL, options: .mappedIfSafe))
        try CloudGalleryAPI.expect(201, data, response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String, CloudPreviewCache.isSafeID(id), let link = json?["url"] as? String else {
            throw CloudUploadError.invalidResponse
        }
        return Item(id: id, url: link, mediaKey: json?["mediaKey"] as? String)
    }

    private func sendPoster(_ jpeg: Data, for item: Item) async throws {
        guard let poster = CloudGalleryAPI.posterRequest(workerBase: workerBase, token: token, uploadID: item.id,
                                                         mediaKey: item.mediaKey, jpeg: jpeg) else { throw CloudUploadError.invalidURL }
        let (data, response) = try await session.upload(for: poster.request, from: poster.body)
        try CloudGalleryAPI.expect(200, data, response)
    }

    private func create(_ ids: [String], settings: Settings) async throws -> CloudGallery {
        guard let request = CloudGalleryAPI.createRequest(workerBase: workerBase, token: token, uploadIDs: ids, settings: settings) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        try CloudGalleryAPI.expect(201, data, response)
        let gallery = try CloudUploadList.decoder.decode(CloudGallery.self, from: data)
        guard CloudPreviewCache.isSafeID(gallery.id) else { throw CloudUploadError.invalidResponse }
        // A gallery that ignored its password is open to anyone: take it down instead.
        if settings.password != nil, !gallery.hasPassword {
            try? await CloudGalleryAPI.delete(galleryID: gallery.id, workerBase: workerBase, token: token, session: session)
            throw CloudUploadError.passwordUnsupported
        }
        return gallery
    }

    /// Deletes these uploads; how many couldn't be. One already gone counts as removed.
    func remove(_ ids: [String]) async -> Int {
        var left = 0
        for id in ids {
            var status: Int?
            if let request = CloudGalleryAPI.deleteUploadRequest(workerBase: workerBase, token: token, uploadID: id),
               let (_, response) = try? await session.data(for: request) {
                status = (response as? HTTPURLResponse)?.statusCode
            }
            if status != 200, status != 404 { left += 1 }
        }
        return left
    }
}
