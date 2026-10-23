import CoreServices
import Foundation

/// A file request on the Worker: a link the owner gives a client, who sends
/// files only the owner can read. GET /api/requests lists the open ones;
/// POST /api/requests creates one, and only that answer carries the link.
nonisolated struct CloudFileRequest: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let message: String
    let hasPassword: Bool
    let expiresAt: Date
    let maxFiles: Int
    let maxFileBytes: Int64
    let maxTotalBytes: Int64
    let filesReceived: Int
    let bytesReceived: Int64
    /// The link, in the creation answer only: the Worker keeps just its hash.
    var url: String? = nil
}

/// What the owner fills in for a new request.
nonisolated struct CloudFileRequestDraft: Equatable, Sendable {
    var message = ""
    var password = ""
    var expiry = CloudExpiry.week
    var maxFiles = 20
    var maxFileBytes = CloudFileRequestAPI.maxFileBytes
    var maxTotalBytes: Int64 = 10 * CloudFileRequestAPI.gibibyte

    /// The Worker's limits: 1,000 UTF-16 units of message, a password the
    /// share password rules allow, a link that expires, 1 to 1,000 files.
    var isValid: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 1000
            && (password.isEmpty || CloudUploadList.isValidPassword(password))
            && expiry != .never && (1...1000).contains(maxFiles)
            && (1...CloudFileRequestAPI.maxFileBytes).contains(maxFileBytes) && maxTotalBytes >= 1
    }
}

/// The owner's file request routes, apart from the app so the requests can
/// be checked without a real token or Worker.
nonisolated enum CloudFileRequestAPI {
    static let gibibyte: Int64 = 1024 * 1024 * 1024
    /// The Worker takes files up to 2 GiB.
    static let maxFileBytes = 2 * gibibyte
    static let fileSizeChoices: [Int64] = [100 * 1024 * 1024, 500 * 1024 * 1024, gibibyte, maxFileBytes]
    static let totalSizeChoices: [Int64] = [gibibyte, 5 * gibibyte, 10 * gibibyte, 25 * gibibyte, 50 * gibibyte]
    /// Every link closes on its own; the Worker allows up to 90 days.
    static let expiryChoices = CloudExpiry.allCases.filter { $0 != .never }

    private struct List: Decodable {
        let requests: [CloudFileRequest]
    }

    /// Bearer POST /api/requests with the draft as JSON; the expiry counts from `now`.
    static func createRequest(workerBase: String, token: String, draft: CloudFileRequestDraft, now: Date = .now) -> URLRequest? {
        guard draft.isValid, let expiresAt = draft.expiry.date(from: now) else { return nil }
        let body: [String: Any] = [
            "message": draft.message.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": draft.password.isEmpty ? NSNull() : draft.password,
            "expiresAt": expiresAt.formatted(.iso8601),
            "maxFiles": draft.maxFiles,
            "maxFileBytes": draft.maxFileBytes,
            "maxTotalBytes": draft.maxTotalBytes,
        ]
        guard var request = ownerRequest(workerBase + "/api/requests", method: "POST", token: token),
              let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    static func listRequest(workerBase: String, token: String) -> URLRequest? {
        ownerRequest(workerBase + "/api/requests", method: "GET", token: token)
    }

    /// Bearer DELETE /api/requests/:id closes the link; received files stay.
    static func closeRequest(workerBase: String, token: String, id: String) -> URLRequest? {
        guard CloudPreviewCache.isSafeID(id) else { return nil }
        return ownerRequest(workerBase + "/api/requests/" + id, method: "DELETE", token: token)
    }

    static func decodeList(_ data: Data) throws -> [CloudFileRequest] {
        try CloudUploadList.decoder.decode(List.self, from: data).requests
    }

    static func decodeCreated(_ data: Data) throws -> CloudFileRequest {
        try CloudUploadList.decoder.decode(CloudFileRequest.self, from: data)
    }

    /// A received file's bytes: /api/media/:id on the Worker, with the owner's token.
    static func downloadRequest(workerBase: String, token: String, id: String) -> URLRequest? {
        guard CloudPreviewCache.isSafeID(id) else { return nil }
        return ownerRequest(workerBase + "/api/media/" + id, method: "GET", token: token)
    }

    private static func ownerRequest(_ address: String, method: String, token: String) -> URLRequest? {
        guard let url = URL(string: address), url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// What clients sent: which files are new since the last look, and where a
/// download goes.
nonisolated enum ReceivedFiles {
    /// Received files that weren't there at the last look. `known` is nil on
    /// the first look at a Worker, which only learns what's there.
    static func newFiles(in uploads: [CloudUpload], known: Set<String>?) -> [CloudUpload] {
        guard let known else { return [] }
        return uploads.filter { $0.isReceived && !known.contains($0.id) }
    }

    /// What to remember after a look: every received file still listed, so a
    /// deleted one is forgotten and never counts as new again.
    static func known(after uploads: [CloudUpload]) -> Set<String> {
        Set(uploads.filter(\.isReceived).map(\.id))
    }

    static func notificationText(for files: [CloudUpload]) -> (title: String, body: String) {
        let names = files.map(\.filename)
        guard files.count > 1 else {
            let size = files.first?.size.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            return ("File received", (names.first ?? "") + size)
        }
        let shown = names.prefix(3).joined(separator: ", ")
        return ("\(files.count) files received", names.count > 3 ? shown + " and \(names.count - 3) more" : shown)
    }

    /// Downloads a received file with the owner's token into `folder`, never
    /// over a file already there, and marks it as downloaded from the internet.
    static func download(_ upload: CloudUpload, workerBase: String, token: String, into folder: URL) async throws -> URL {
        guard let request = CloudFileRequestAPI.downloadRequest(workerBase: workerBase, token: token, id: upload.id) else {
            throw CloudPreviewError.badLink
        }
        let (download, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CloudPreviewError.status(status) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = destination(for: upload.filename, in: folder)
        try FileManager.default.moveItem(at: download, to: saved)
        // A stranger's file: Gatekeeper checks it when it's opened, as with a browser download.
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Sukusho",
        ]
        try? saved.setResourceValues(values)
        return saved
    }

    /// A plain file name in `folder` that no file has yet: the name the client
    /// gave, made safe, numbered as Finder does when it's taken.
    static func destination(for filename: String, in folder: URL,
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        // The Worker already refuses slashes and control characters; a colon shows as a slash
        // in Finder, and a leading dot would hide the file.
        let cleaned = String(filename.map { $0 == "/" || $0 == ":" || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        let name = cleaned.isEmpty ? "Received file" : cleaned
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name, directoryHint: .notDirectory)
        var number = 2
        while exists(candidate) {
            candidate = folder.appending(path: "\(base) \(number)" + (ext.isEmpty ? "" : "." + ext), directoryHint: .notDirectory)
            number += 1
        }
        return candidate
    }
}
