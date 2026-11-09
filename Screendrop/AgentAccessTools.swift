//
//  AgentAccessTools.swift
//  Screendrop
//
//  The MCP tools and resources Sukusho offers agents (phase 1 of the spec in
//  notes/specs/2026-11-08-sukusho-mcp.md): their schemas, argument checks,
//  the owner's approvals, and result shapes. What a tool does to the Library
//  or the Cloud goes through `AgentBackend`, so this runs without the app.
//

import Foundation

// MARK: - What the backend works with

nonisolated struct AgentItem: Sendable, Equatable {
    let id: String
    let title: String
    /// "screenshot", "recording" or "video".
    let kind: String
    let createdAt: Date
    let width: Int
    let height: Int
    var duration: Double? = nil
    var tags: [String] = []
    var source: CaptureSource? = nil
    var cloudURL: String? = nil
    let fileURL: URL
    /// The capture's text, folded for search.
    var foldedText: String? = nil

    var isImage: Bool { kind == "screenshot" }
}

nonisolated struct AgentShareSettings: Sendable, Equatable {
    var title: String?
    var expiry: CloudExpiry
    /// Only ever typed by the owner in Share Options.
    var password: String? = nil
    var comments: Bool
    var anonymousComments: Bool
    /// Only ever ticked by the owner; the key then travels in the link.
    var encrypted = false
}

nonisolated struct AgentShareResult: Sendable, Equatable {
    let id: String
    let url: String
    let title: String
    let expiresAt: Date?
    let hasPassword: Bool
    let thumbnailURL: String?
    let isGallery: Bool
    /// The uploads behind it: itself, or a gallery's images.
    let uploadIDs: [String]
}

nonisolated enum AgentCaptureMode: String, Sendable { case full, text }

nonisolated enum AgentCaptureOutcome: Sendable {
    case captured(AgentItem)
    case text(String)
    case noText
    case cancelled
    case failed(String)
}

nonisolated struct AgentPromptInfo: Sendable, Equatable {
    let folder: URL
    let title: String
    let recording: String
    let time: Date
}

/// The Library and the app's own sharing paths.
@MainActor
protocol AgentBackend: AnyObject {
    /// The owner's Worker, nil when Cloud isn't set up.
    var cloud: AgentCloud? { get }
    var defaultShare: AgentShareSettings { get }
    func libraryItems() -> [AgentItem]
    func addImages(_ files: [URL], title: String?, tags: [String]) async -> [AgentItem]
    func text(of item: AgentItem) -> String?
    func jpeg(of item: AgentItem, maxPixels: Int) async -> Data?
    func shareOne(_ item: AgentItem, settings: AgentShareSettings) async throws -> AgentShareResult
    func shareGallery(_ items: [AgentItem], settings: AgentShareSettings) async throws -> AgentShareResult
    func createFileRequest(_ draft: CloudFileRequestDraft) async throws -> CloudFileRequest
    /// After links changed or went (`deleted`: upload and gallery IDs): the Library's cards and Cloud pages catch up.
    func cloudDidChange(deleted: Set<String>)
    func latestAgentPrompt() -> AgentPromptInfo?
    func exportAgentPrompt(_ item: AgentItem) async throws -> AgentPromptInfo
    func capture(_ mode: AgentCaptureMode) async -> AgentCaptureOutcome
}

/// One question to the owner, in Sukusho's own window.
nonisolated struct AgentAsk: Sendable {
    let agent: AgentIdentity
    let group: AgentGroup
    /// "wants to share 3 images as a gallery".
    let action: String
    var details: [String] = []
    var thumbnails: [URL] = []
    /// Offers For this session and Always; a password hand-off doesn't.
    var grantable = true
    /// When no answer counts as Deny; nil while the owner finishes a hand-off.
    var deadline: Date? = nil
    /// Why Share Options can't offer end-to-end encryption; nil when it can.
    var encryptionUnavailable: String? = nil
}

@MainActor
protocol AgentAsker: AnyObject {
    /// Share Options, prefilled. `answer` gets the owner's choice and settings, or nil.
    /// Returns what closes the window.
    func askShare(_ ask: AgentAsk, settings: AgentShareSettings,
                  answer: @escaping ((decision: AgentDecision, settings: AgentShareSettings)?) -> Void) -> () -> Void
    /// The Request Files sheet, prefilled.
    func askFileRequest(_ ask: AgentAsk, draft: CloudFileRequestDraft,
                        answer: @escaping ((decision: AgentDecision, draft: CloudFileRequestDraft)?) -> Void) -> () -> Void
    /// Everything else: Allow with a choice of how long, or Deny.
    func ask(_ ask: AgentAsk, answer: @escaping (AgentDecision?) -> Void) -> () -> Void
}

/// One helper connection: one agent conversation.
@MainActor
final class AgentSession: Identifiable {
    let id = UUID()
    let agent: AgentIdentity
    let started = Date()
    var grants: Set<AgentGroup> = []
    init(agent: AgentIdentity) { self.agent = agent }
}

// MARK: - Errors and arguments

nonisolated struct AgentToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A tool's arguments, checked. Unknown names are refused, so a misspelled
/// `password` can't quietly share without one.
nonisolated struct AgentArguments {
    let raw: [String: Any]

    init(_ raw: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(raw.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw AgentToolError("Unknown argument\(unknown.count == 1 ? "" : "s"): \(unknown.sorted().joined(separator: ", ")).")
        }
        self.raw = raw.filter { !($0.value is NSNull) }
    }

    func string(_ key: String, maxLength: Int = 1000) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let text = value as? String else { throw AgentToolError("\(key) must be a string.") }
        guard text.count <= maxLength else { throw AgentToolError("\(key) is longer than \(maxLength) characters.") }
        return text
    }

    func required(_ key: String) throws -> String {
        guard let text = try string(key), !text.isEmpty else { throw AgentToolError("\(key) is required.") }
        return text
    }

    func strings(_ key: String, count: ClosedRange<Int>, maxLength: Int = 4096) throws -> [String]? {
        guard let value = raw[key] else { return nil }
        guard let list = value as? [Any], let texts = list as? [String] else { throw AgentToolError("\(key) must be a list of strings.") }
        guard count.contains(texts.count) else { throw AgentToolError("\(key) takes \(count.lowerBound) to \(count.upperBound) entries.") }
        guard texts.allSatisfy({ !$0.isEmpty && $0.count <= maxLength }) else { throw AgentToolError("\(key) has an empty or overlong entry.") }
        return texts
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = raw[key] else { return nil }
        guard Self.isBool(value), let flag = value as? Bool else { throw AgentToolError("\(key) must be true or false.") }
        return flag
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = raw[key] else { return nil }
        guard !Self.isBool(value), let number = value as? NSNumber, number.doubleValue == number.doubleValue.rounded() else {
            throw AgentToolError("\(key) must be a whole number.")
        }
        guard range.contains(number.intValue) else { throw AgentToolError("\(key) must be from \(range.lowerBound) to \(range.upperBound).") }
        return number.intValue
    }

    func date(_ key: String) throws -> Date? {
        guard let text = try string(key, maxLength: 40) else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let day = try? Date(text + "T00:00:00Z", strategy: .iso8601) { return day }
        throw AgentToolError("\(key) must be an ISO 8601 date, such as 2026-11-08 or 2026-11-08T09:30:00Z.")
    }

    /// Sukusho's own expiry choices: 0 for never (shares only), 1, 7 or 30 days.
    func expiry(_ key: String, allowsNever: Bool) throws -> CloudExpiry? {
        guard let days = try int(key, in: 0...365) else { return nil }
        guard let expiry = CloudExpiry(rawValue: days), allowsNever || expiry != .never else {
            throw AgentToolError("\(key) must be " + (allowsNever ? "0 (never), " : "") + "1, 7 or 30.")
        }
        return expiry
    }

    static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }
}

// MARK: - The toolbox

@MainActor
final class AgentToolbox {
    let backend: AgentBackend
    let asker: AgentAsker
    let grants: AgentGrantStore
    let log: AgentActivityLog
    var askTimeout: Duration = .seconds(60)
    var handoffTimeout: Duration = .seconds(600)
    var poll: Duration = .milliseconds(200)
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var now: () -> Date = { .now }
    /// Images only, at most this big each.
    static let maxImportBytes = 100 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
    private var handoffs: [String: AgentHandoff] = [:]

    init(backend: AgentBackend, asker: AgentAsker, grants: AgentGrantStore, log: AgentActivityLog) {
        self.backend = backend
        self.asker = asker
        self.grants = grants
        self.log = log
    }

    /// One request from the helper: the MCP result object, or an error message.
    func handle(method: String, params: [String: Any], session: AgentSession) async -> Result<[String: Any], AgentToolError> {
        switch method {
        case "tools/list": return .success(["tools": AgentToolCatalog.tools])
        case "resources/list": return .success(["resources": AgentToolCatalog.resources])
        case "resources/templates/list": return .success(["resourceTemplates": AgentToolCatalog.resourceTemplates])
        case "resources/read":
            guard let uri = params["uri"] as? String else { return .failure(AgentToolError("uri is required.")) }
            return await readResource(uri)
        case "tools/call":
            guard let name = params["name"] as? String else { return .failure(AgentToolError("name is required.")) }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = await call(name, arguments, session: session)
            log.add(agent: session.agent.displayName, tool: name, result: result.summary, now: now())
            return .success(result.mcp)
        default:
            return .failure(AgentToolError("Unknown method \(method)."))
        }
    }

    struct ToolResult {
        var object: [String: Any]
        var isError = false
        var image: Data? = nil
        /// What the activity log says.
        var summary: String

        var mcp: [String: Any] {
            let text = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            var content: [[String: Any]] = [["type": "text", "text": text]]
            if let image { content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"]) }
            return ["content": content, "structuredContent": object, "isError": isError]
        }

        static func error(_ message: String) -> ToolResult {
            ToolResult(object: ["status": "error", "error": message], isError: true, summary: "error: " + message)
        }

        static let denied = ToolResult(
            object: ["status": "denied", "error": "Sukusho’s owner didn’t allow this. No answer within 60 seconds counts as no. Don’t try it another way."],
            isError: true, summary: "denied")
        static let cancelled = ToolResult(object: ["status": "cancelled"], summary: "cancelled")
    }

    func call(_ name: String, _ raw: [String: Any], session: AgentSession) async -> ToolResult {
        do {
            switch name {
            case "library_add": return try await libraryAdd(raw, session)
            case "library_search": return try librarySearch(raw)
            case "library_get": return try await libraryGet(raw)
            case "share": return try await share(raw, session)
            case "share_status": return try shareStatus(raw)
            case "links_list": return try await linksList(raw)
            case "link_update": return try await linkUpdate(raw, session)
            case "link_delete": return try await linkDelete(raw, session)
            case "file_request_create": return try await fileRequestCreate(raw, session)
            case "file_requests_list": return try await fileRequestsList(raw)
            case "file_request_close": return try await fileRequestClose(raw, session)
            case "received_list": return try await receivedList(raw)
            case "received_download": return try await receivedDownload(raw)
            case "feedback_list": return try await feedbackList(raw)
            case "agent_prompt_latest": return try agentPromptLatest(raw)
            case "agent_prompt_export": return try await agentPromptExport(raw)
            case "capture": return try await capture(raw, session)
            default: return .error("Unknown tool \(name).")
            }
        } catch let error as AgentToolError {
            return .error(error.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: Approval

    /// Nil when the owner said no or didn't answer in time.
    private func approve(_ group: AgentGroup, items: [String], session: AgentSession, ask: AgentAsk) async -> AgentDecision? {
        if isAllowed(group, items: items, session: session) { return .once }
        var ask = ask
        ask.deadline = now().addingTimeInterval(Double(askTimeout.components.seconds))
        let pending = AgentPendingAnswer<AgentDecision>(sleep: sleep)
        let close = asker.ask(ask) { pending.give($0) }
        let answer = await pending.wait(upTo: askTimeout, poll: poll)
        close()
        guard let decision = answer ?? nil else { return nil }
        remember(decision, group, session)
        return decision
    }

    private func isAllowed(_ group: AgentGroup, items: [String], session: AgentSession) -> Bool {
        AgentPolicy.allowed(group, session: session.grants, always: grants.hasAlways(group, for: session.agent),
                            items: items, owned: grants.owned(by: session.agent))
    }

    private func remember(_ decision: AgentDecision, _ group: AgentGroup, _ session: AgentSession) {
        switch decision {
        case .once: break
        case .session: session.grants.insert(group)
        case .always: grants.grantAlways(group, to: session.agent, now: now())
        }
    }

    private func cloud() throws -> AgentCloud {
        guard let cloud = backend.cloud else { throw AgentToolError("Cloud isn’t set up in Sukusho (Settings › Cloud).") }
        return cloud
    }

    // MARK: Library

    private func libraryAdd(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["paths", "title", "tags"])
        guard let paths = try args.strings("paths", count: 1...50) else { throw AgentToolError("paths is required.") }
        let title = try args.string("title", maxLength: 200)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = try args.strings("tags", count: 0...20, maxLength: 60) ?? []
        let files = try paths.map(Self.checkedImage)
        let added = await backend.addImages(files, title: title?.isEmpty == true ? nil : title, tags: tags)
        guard added.count == files.count else { throw AgentToolError("Sukusho couldn’t add every image; \(added.count) of \(files.count) went in.") }
        grants.recordOwned(added.map(\.id), by: session.agent)
        return ToolResult(object: ["status": "added", "items": added.map(Self.summary)], summary: "added \(added.count)")
    }

    /// Only the paths the agent names: an existing regular file, an image, at most 100 MB.
    static func checkedImage(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw AgentToolError("\(path) isn’t an absolute path.") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
        guard values?.isRegularFile == true, values?.isReadable == true else { throw AgentToolError("\(path) isn’t a readable file.") }
        guard imageExtensions.contains(url.pathExtension.lowercased()) else {
            throw AgentToolError("\(path) isn’t an image. Phase 1 adds images only (PNG, JPEG, HEIC, TIFF, GIF, WebP, BMP).")
        }
        guard (values?.fileSize ?? 0) <= maxImportBytes else { throw AgentToolError("\(path) is over 100 MB.") }
        return url
    }

    private func librarySearch(_ raw: [String: Any]) throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["query", "kind", "tags", "since", "limit"])
        let query = CaptureLibraryQuery(try args.string("query", maxLength: 500) ?? "")
        let kind = try args.string("kind", maxLength: 20) ?? "any"
        guard ["any", "screenshot", "recording"].contains(kind) else { throw AgentToolError("kind must be any, screenshot or recording.") }
        let tags = try args.strings("tags", count: 0...20, maxLength: 60) ?? []
        let since = try args.date("since")
        let limit = try args.int("limit", in: 1...100) ?? 20
        let matches = backend.libraryItems().filter { item in
            let fields = [item.title, item.fileURL.lastPathComponent, item.source?.appName, item.source?.windowTitle].compactMap { $0 } + item.tags
            return (kind == "any" || (kind == "screenshot") == item.isImage)
                && tags.allSatisfy(item.tags.contains)
                && since.map { item.createdAt >= $0 } ?? true
                && query.matches(fields: fields, foldedText: item.foldedText, source: item.source)
        }.sorted { $0.createdAt > $1.createdAt }
        return ToolResult(object: ["count": matches.count, "items": matches.prefix(limit).map(Self.summary)],
                          summary: "\(matches.count) found")
    }

    private func libraryGet(_ raw: [String: Any]) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id", "image"])
        let item = try find(try args.required("id"))
        var object = Self.summary(item)
        var untrusted = object["untrusted"] as? [String: Any] ?? [:]
        if let text = backend.text(of: item), !text.isEmpty { untrusted["text"] = String(text.prefix(20_000)) }
        if !untrusted.isEmpty { object["untrusted"] = AgentUntrusted.wrap(untrusted) }
        var image: Data?
        if try args.bool("image") == true {
            guard item.isImage else { throw AgentToolError("image is for screenshots; this is a \(item.kind).") }
            image = await backend.jpeg(of: item, maxPixels: 1568)
            if image == nil { throw AgentToolError("Sukusho couldn’t read this image.") }
        }
        return ToolResult(object: object, image: image, summary: "read")
    }

    private func find(_ id: String) throws -> AgentItem {
        guard let item = backend.libraryItems().first(where: { $0.id == id }) else {
            throw AgentToolError("No capture with id \(id). library_search lists them.")
        }
        return item
    }

    /// A capture as tools return it. No file paths: the agent never gets the Library's files.
    static func summary(_ item: AgentItem) -> [String: Any] {
        var object: [String: Any] = [
            "id": item.id, "title": item.title, "kind": item.kind, "created_at": iso(item.createdAt),
            "width": item.width, "height": item.height, "tags": item.tags,
        ]
        if let duration = item.duration { object["duration_seconds"] = (duration * 10).rounded() / 10 }
        if let link = item.cloudURL { object["cloud_url"] = link }
        // Window titles come from other apps and web pages.
        if let source = item.source {
            var fields: [String: Any] = ["app": source.appName]
            if let window = source.windowTitle { fields["window"] = window }
            object["untrusted"] = AgentUntrusted.wrap(fields)
        }
        return object
    }

    // MARK: Sharing

    private func share(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["ids", "title", "expires_in_days", "password", "comments", "anonymous_comments"])
        guard let ids = try args.strings("ids", count: 1...CloudGalleryAPI.maxImages) else { throw AgentToolError("ids is required.") }
        guard Set(ids).count == ids.count else { throw AgentToolError("ids has repeats.") }
        let items = try ids.map(find)
        if items.count > 1, !CloudGalleryAPI.canShare(count: items.count, includesRecording: !items.allSatisfy(\.isImage)) {
            throw AgentToolError("A gallery takes 2 to 100 screenshots and no recordings. Share a recording on its own.")
        }
        let cloud = try cloud()
        if items.count > 1, !CloudGalleryAPI.supportsGalleries(version: await cloud.version()) {
            throw AgentToolError("Galleries need Worker 2.0.0 or later. Update the Worker, or share images one at a time.")
        }
        var settings = backend.defaultShare
        settings.title = try args.string("title", maxLength: 200).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? (items.count == 1 ? items[0].title : nil)
        settings.expiry = try args.expiry("expires_in_days", allowsNever: true) ?? settings.expiry
        settings.comments = try args.bool("comments") ?? settings.comments
        settings.anonymousComments = try args.bool("anonymous_comments") ?? settings.anonymousComments
        let wantsPassword = try args.bool("password") ?? false
        let what = items.count == 1 ? "share “\(items[0].title)”" : "share \(items.count) images as a gallery"
        var ask = AgentAsk(agent: session.agent, group: .publish, action: what,
                           details: items.prefix(8).map(\.title) + (items.count > 8 ? ["and \(items.count - 8) more"] : []),
                           thumbnails: items.filter(\.isImage).prefix(6).map(\.fileURL))
        ask.encryptionUnavailable = items.count > 1 ? "Galleries can’t be end-to-end encrypted yet."
            : CloudShareSeal.unavailableReason(fileURLs: [items[0].fileURL], isRecording: !items[0].isImage)
        if wantsPassword {
            ask.grantable = false
            return try await handOff(ask: ask, settings: settings, items: items, session: session)
        }
        if !isAllowed(.publish, items: ids, session: session) {
            ask.deadline = now().addingTimeInterval(Double(askTimeout.components.seconds))
            let pending = AgentPendingAnswer<(decision: AgentDecision, settings: AgentShareSettings)>(sleep: sleep)
            let close = asker.askShare(ask, settings: settings) { pending.give($0) }
            let answer = await pending.wait(upTo: askTimeout, poll: poll)
            close()
            guard let answered = answer ?? nil else { return .denied }
            remember(answered.decision, .publish, session)
            settings = answered.settings
        }
        return try await performShare(items, settings, session)
    }

    /// The owner types the password in Share Options and clicks Upload. The link
    /// comes back when that's done; after 10 minutes, `pending` and an id for share_status.
    private func handOff(ask: AgentAsk, settings: AgentShareSettings, items: [AgentItem], session: AgentSession) async throws -> ToolResult {
        let handoff = AgentHandoff()
        let id = UUID().uuidString.lowercased()
        handoffs[id] = handoff
        // The sheet stays open past the wait; it closes itself when the owner finishes.
        _ = asker.askShare(ask, settings: settings) { [weak self] answer in
            guard let self, let answer else { return handoff.cancel() }
            handoff.start { try await self.performShare(items, answer.settings, session).object }
        }
        return await result(of: handoff, id: id)
    }

    private func result(of handoff: AgentHandoff, id: String) async -> ToolResult {
        switch await handoff.wait(upTo: handoffTimeout, poll: poll, sleep: sleep) {
        case .done(let object): return ToolResult(object: object, summary: "shared")
        case .failed(let message): return .error(message)
        case .cancelled: return .cancelled
        case .waiting, .working:
            return ToolResult(object: ["status": "pending", "id": id,
                                       "note": "Sukusho is waiting for its owner to finish. Call share_status with this id later."],
                              summary: "pending")
        }
    }

    private func performShare(_ items: [AgentItem], _ settings: AgentShareSettings, _ session: AgentSession) async throws -> ToolResult {
        let shared = items.count == 1 ? try await backend.shareOne(items[0], settings: settings)
            : try await backend.shareGallery(items, settings: settings)
        grants.recordOwned([shared.id] + shared.uploadIDs, by: session.agent)
        backend.cloudDidChange(deleted: [])
        var object: [String: Any] = [
            "status": "shared", "id": shared.id, "kind": shared.isGallery ? "gallery" : "upload", "url": shared.url,
            "title": shared.title, "has_password": shared.hasPassword, "expires_at": shared.expiresAt.map(Self.iso) ?? NSNull(),
            "email": AgentEmail.share(title: shared.title, url: shared.url, expiresAt: shared.expiresAt, hasPassword: shared.hasPassword,
                                      thumbnailURL: shared.thumbnailURL, count: items.count),
        ]
        if let thumbnail = shared.thumbnailURL { object["thumbnail_url"] = thumbnail }
        if shared.isGallery { object["images"] = items.count }
        if shared.url.contains("#") {
            object["note"] = "End-to-end encrypted: the key is the part after #, so send the whole link. The server can’t open it."
        }
        return ToolResult(object: object, summary: shared.isGallery ? "gallery of \(items.count)" : "shared")
    }

    private func shareStatus(_ raw: [String: Any]) throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id"])
        let id = try args.required("id")
        guard let handoff = handoffs[id] else { throw AgentToolError("No hand-off with id \(id).") }
        switch handoff.state {
        case .done(let object): return ToolResult(object: object, summary: "shared")
        case .failed(let message): return .error(message)
        case .cancelled: return .cancelled
        case .waiting: return ToolResult(object: ["status": "pending", "id": id], summary: "pending")
        case .working: return ToolResult(object: ["status": "uploading", "id": id], summary: "uploading")
        }
    }

    private func linksList(_ raw: [String: Any]) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["kind", "expiring_within_days"])
        let kind = try args.string("kind", maxLength: 20) ?? "uploads"
        let within = try args.int("expiring_within_days", in: 0...3650)
        let cloud = try cloud()
        let links: [CloudUpload]
        switch kind {
        case "uploads": links = try await cloud.uploads().filter { !$0.isReceived && !$0.isGallery }
        case "galleries": links = try await cloud.galleries().map(\.upload)
        case "received": links = try await cloud.uploads(received: true).filter(\.isReceived)
        default: throw AgentToolError("kind must be uploads, galleries or received.")
        }
        let cutoff = within.map { now().addingTimeInterval(Double($0) * 86_400) }
        let shown = links.filter { link in
            guard let cutoff else { return true }
            return link.expiresAt.map { $0 <= cutoff } ?? false
        }
        return ToolResult(object: ["kind": kind, "count": shown.count, "links": shown.map(Self.link)], summary: "\(shown.count) \(kind)")
    }

    static func link(_ upload: CloudUpload) -> [String: Any] {
        var object: [String: Any] = [
            "id": upload.id, "kind": upload.isGallery ? "gallery" : upload.isReceived ? "received" : upload.mediaType,
            "created_at": iso(upload.createdAt), "expires_at": upload.expiresAt.map(iso) ?? NSNull(),
            "has_password": upload.hasPassword ?? false,
        ]
        if !upload.isReceived { object["url"] = upload.url }
        if let views = upload.views { object["views"] = views }
        if let count = upload.commentCount { object["comments"] = count }
        if let count = upload.likeCount { object["likes"] = count }
        if let size = upload.size { object["size_bytes"] = size }
        if let gallery = upload.galleryId { object["gallery_id"] = gallery }
        if let images = upload.galleryItemIDs { object["image_ids"] = images }
        if upload.encrypted == true { object["encrypted"] = true }
        if upload.isReceived {
            object["request_id"] = upload.requestId
            // The client named the file.
            object["untrusted"] = AgentUntrusted.wrap(["filename": upload.filename, "title": upload.title ?? NSNull()])
        } else {
            object["title"] = upload.title ?? upload.filename
        }
        return object
    }

    private func linkUpdate(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id", "expires_in_days", "anonymous_comments"])
        let id = try args.required("id")
        let expiry = try args.expiry("expires_in_days", allowsNever: true)
        let anonymous = try args.bool("anonymous_comments")
        guard expiry != nil || anonymous != nil else { throw AgentToolError("Give expires_in_days or anonymous_comments.") }
        let cloud = try cloud()
        guard let upload = try await cloud.uploads().first(where: { $0.id == id && !$0.isReceived }) else {
            if try await cloud.galleries().contains(where: { $0.id == id }) {
                throw AgentToolError("A gallery’s expiry and comments can’t be changed after it’s shared yet.")
            }
            throw AgentToolError("No upload with id \(id). links_list lists them.")
        }
        var details: [String] = []
        if let expiry { details.append(expiry == .never ? "The link won’t expire." : "The link expires in \(expiry.title).") }
        if let anonymous { details.append(anonymous ? "Anyone can comment without signing in." : "Commenters must sign in.") }
        let ask = AgentAsk(agent: session.agent, group: .publish, action: "change “\(upload.title ?? upload.filename)”", details: details)
        guard await approve(.publish, items: [id], session: session, ask: ask) != nil else { return .denied }
        let updated = try await cloud.update(id: id, expiresAt: expiry.map { $0.date(from: now()) }, anonymousComments: anonymous)
        backend.cloudDidChange(deleted: [])
        return ToolResult(object: ["status": "updated", "link": Self.link(updated ?? upload)], summary: "updated")
    }

    private func linkDelete(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id"])
        let id = try args.required("id")
        let cloud = try cloud()
        let gallery = try await cloud.galleries().first { $0.id == id }
        var upload = gallery == nil ? try await cloud.uploads().first { $0.id == id } : nil
        if gallery == nil, upload == nil { upload = try await cloud.uploads(received: true).first { $0.id == id } }
        guard let target = gallery?.upload ?? upload else { throw AgentToolError("No link with id \(id). links_list lists them.") }
        let name = target.title ?? target.filename
        let ask = AgentAsk(agent: session.agent, group: .publish,
                           action: gallery != nil ? "delete the gallery “\(name)” and its \(gallery!.uploadIds.count) images from Cloud"
                               : target.isReceived ? "delete a received file from Cloud" : "delete “\(name)” from Cloud",
                           details: ["The link stops working at once. This can’t be undone."])
        guard await approve(.publish, items: [id], session: session, ask: ask) != nil else { return .denied }
        if let gallery {
            try await cloud.deleteGallery(gallery.id)
        } else {
            try await cloud.deleteUpload(id)
        }
        // A gallery goes with its images, as the Library's own delete takes them.
        let removed = Set([id] + (gallery?.uploadIds ?? []))
        grants.forget(removed)
        backend.cloudDidChange(deleted: removed)
        return ToolResult(object: ["status": "deleted", "id": id], summary: "deleted")
    }

    // MARK: File requests

    private func fileRequestCreate(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["message", "expires_in_days", "password", "max_files", "max_file_mb", "max_total_gb"])
        var draft = CloudFileRequestDraft()
        draft.message = try args.string("message", maxLength: 1000)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draft.expiry = try args.expiry("expires_in_days", allowsNever: false) ?? draft.expiry
        draft.maxFiles = try args.int("max_files", in: CloudFileRequestAPI.fileCountRange) ?? draft.maxFiles
        if let megabytes = try args.int("max_file_mb", in: 1...2048) { draft.maxFileBytes = Int64(megabytes) * 1024 * 1024 }
        if let gigabytes = try args.int("max_total_gb", in: 1...50) { draft.maxTotalBytes = Int64(gigabytes) * CloudFileRequestAPI.gibibyte }
        guard draft.isValid else { throw AgentToolError("Those limits don’t make a valid request.") }
        _ = try cloud()
        let wantsPassword = try args.bool("password") ?? false
        var ask = AgentAsk(agent: session.agent, group: .publish, action: "make a file request link",
                           details: [draft.message.isEmpty ? "No message" : "“\(draft.message)”",
                                     "Up to \(draft.maxFiles) files, expires in \(draft.expiry.title)"])
        if wantsPassword {
            ask.grantable = false
            let handoff = AgentHandoff()
            let id = UUID().uuidString.lowercased()
            handoffs[id] = handoff
            _ = asker.askFileRequest(ask, draft: draft) { [weak self] answer in
                guard let self, let answer else { return handoff.cancel() }
                handoff.start { try await self.createRequest(answer.draft, session).object }
            }
            return await result(of: handoff, id: id)
        }
        if !isAllowed(.publish, items: [], session: session) {
            ask.deadline = now().addingTimeInterval(Double(askTimeout.components.seconds))
            let pending = AgentPendingAnswer<(decision: AgentDecision, draft: CloudFileRequestDraft)>(sleep: sleep)
            let close = asker.askFileRequest(ask, draft: draft) { pending.give($0) }
            let answer = await pending.wait(upTo: askTimeout, poll: poll)
            close()
            guard let answered = answer ?? nil else { return .denied }
            remember(answered.decision, .publish, session)
            draft = answered.draft
        }
        return try await createRequest(draft, session)
    }

    private func createRequest(_ draft: CloudFileRequestDraft, _ session: AgentSession) async throws -> ToolResult {
        let created = try await backend.createFileRequest(draft)
        grants.recordOwned([created.id], by: session.agent)
        guard let url = created.url else { throw AgentToolError("The Worker made the request but sent no link.") }
        return ToolResult(object: [
            "status": "created", "id": created.id, "url": url, "message": created.message, "expires_at": Self.iso(created.expiresAt),
            "has_password": created.hasPassword, "max_files": created.maxFiles, "max_file_bytes": created.maxFileBytes,
            "max_total_bytes": created.maxTotalBytes,
            "email": AgentEmail.fileRequest(url: url, message: created.message, expiresAt: created.expiresAt, hasPassword: created.hasPassword),
        ], summary: "created")
    }

    private func fileRequestsList(_ raw: [String: Any]) async throws -> ToolResult {
        _ = try AgentArguments(raw, allowed: [])
        let requests = try await cloud().fileRequests()
        return ToolResult(object: ["count": requests.count, "requests": requests.map { request in
            ["id": request.id, "message": request.message, "has_password": request.hasPassword, "expires_at": Self.iso(request.expiresAt),
             "max_files": request.maxFiles, "files_received": request.filesReceived, "bytes_received": request.bytesReceived,
             "max_total_bytes": request.maxTotalBytes] as [String: Any]
        }], summary: "\(requests.count) open")
    }

    private func fileRequestClose(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id"])
        let id = try args.required("id")
        let cloud = try cloud()
        guard let request = try await cloud.fileRequests().first(where: { $0.id == id }) else {
            throw AgentToolError("No open file request with id \(id).")
        }
        let ask = AgentAsk(agent: session.agent, group: .publish, action: "close a file request",
                           details: [request.message.isEmpty ? "No message" : "“\(request.message)”",
                                     "\(request.filesReceived) files received stay."])
        guard await approve(.publish, items: [id], session: session, ask: ask) != nil else { return .denied }
        try await cloud.closeFileRequest(id)
        backend.cloudDidChange(deleted: [])
        return ToolResult(object: ["status": "closed", "id": id], summary: "closed")
    }

    private func receivedList(_ raw: [String: Any]) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["since"])
        let since = try args.date("since")
        let files = try await cloud().uploads(received: true).filter { file in file.isReceived && since.map { file.createdAt >= $0 } ?? true }
        return ToolResult(object: ["count": files.count, "files": files.map(Self.link)], summary: "\(files.count) received")
    }

    private func receivedDownload(_ raw: [String: Any]) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["ids", "to_folder"])
        guard let ids = try args.strings("ids", count: 1...100) else { throw AgentToolError("ids is required.") }
        let folderPath = try args.required("to_folder")
        guard folderPath.hasPrefix("/") else { throw AgentToolError("to_folder must be an absolute path.") }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw AgentToolError("to_folder is a file, not a folder.")
        }
        let cloud = try cloud()
        let received = try await cloud.uploads(received: true).filter(\.isReceived)
        let targets = try ids.map { id in
            guard let file = received.first(where: { $0.id == id }) else { throw AgentToolError("No received file with id \(id).") }
            return file
        }
        var saved: [[String: Any]] = []
        for file in targets {
            // Never over a file already there; the name is made safe and numbered.
            let url = try await ReceivedFiles.download(file, workerBase: cloud.workerBase, token: cloud.token, into: folder)
            saved.append(["id": file.id, "path": url.path])
        }
        return ToolResult(object: ["status": "downloaded", "files": saved,
                                   "note": "Files from clients aren’t scanned for malware; they’re marked as downloaded from the internet."],
                          summary: "downloaded \(saved.count)")
    }

    private func feedbackList(_ raw: [String: Any]) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["since", "upload_id"])
        let since = try args.date("since")
        let uploadID = try args.string("upload_id", maxLength: 100)
        let cloud = try cloud()
        func keep(_ created: Date, _ upload: String) -> Bool {
            since.map { created >= $0 } ?? true && uploadID.map { $0 == upload } ?? true
        }
        let comments = try await cloud.comments().filter { keep($0.createdAt, $0.uploadId) }
        let likes = try await cloud.likes().filter { keep($0.createdAt, $0.uploadId) }
        return ToolResult(object: [
            "comments": comments.map { comment in
                var object: [String: Any] = [
                    "id": comment.id, "upload_id": comment.uploadId, "created_at": Self.iso(comment.createdAt),
                    "upload": ["title": comment.upload.title ?? comment.upload.filename, "url": comment.upload.shareUrl],
                    "untrusted": AgentUntrusted.wrap(["author": comment.authorName, "text": comment.text]),
                ]
                if let at = comment.timestamp { object["video_seconds"] = at }
                return object
            },
            "likes": likes.map { like in
                ["id": like.id, "upload_id": like.uploadId, "created_at": Self.iso(like.createdAt),
                 "upload": ["title": like.uploadName, "url": like.upload.shareUrl]] as [String: Any]
            },
        ], summary: "\(comments.count) comments, \(likes.count) likes")
    }

    // MARK: Agent Prompt and capture

    private func agentPromptLatest(_ raw: [String: Any]) throws -> ToolResult {
        _ = try AgentArguments(raw, allowed: [])
        guard let latest = backend.latestAgentPrompt() else { return ToolResult(object: ["status": "none"], summary: "none") }
        return ToolResult(object: Self.prompt(latest), summary: "latest")
    }

    private func agentPromptExport(_ raw: [String: Any]) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["recording_id"])
        let item = try find(try args.required("recording_id"))
        guard item.kind == "recording" else { throw AgentToolError("Agent Prompt is for recordings; this is a \(item.kind).") }
        return ToolResult(object: Self.prompt(try await backend.exportAgentPrompt(item)), summary: "exported")
    }

    static func prompt(_ info: AgentPromptInfo) -> [String: Any] {
        let prompt = info.folder.appendingPathComponent("prompt.md").path
        return ["status": "ready", "title": info.title, "recording": info.recording, "written_at": iso(info.time),
                "folder": info.folder.path, "prompt_path": prompt, "read_line": "Read \"\(prompt)\" and follow it."]
    }

    private func capture(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["mode"])
        guard let mode = AgentCaptureMode(rawValue: try args.string("mode", maxLength: 10) ?? "full") else {
            throw AgentToolError("mode must be full or text.")
        }
        let ask = AgentAsk(agent: session.agent, group: .capture,
                           action: mode == .full ? "take a screenshot of the whole screen" : "read text from an area you drag out",
                           details: [mode == .full ? "It goes into the Library." : "You choose the area after allowing."])
        guard await approve(.capture, items: [], session: session, ask: ask) != nil else { return .denied }
        switch await backend.capture(mode) {
        case .captured(let item):
            grants.recordOwned([item.id], by: session.agent)
            return ToolResult(object: ["status": "captured", "item": Self.summary(item)], summary: "captured")
        case .text(let text):
            return ToolResult(object: ["status": "read", "untrusted": AgentUntrusted.wrap(["text": text])], summary: "text read")
        case .noText: return ToolResult(object: ["status": "no_text"], summary: "no text")
        case .cancelled: return .cancelled
        case .failed(let message): return .error(message)
        }
    }

    // MARK: Resources

    private func readResource(_ uri: String) async -> Result<[String: Any], AgentToolError> {
        if uri == "sukusho://agent-prompt/latest" {
            guard let latest = backend.latestAgentPrompt(),
                  let text = try? String(contentsOf: latest.folder.appendingPathComponent("prompt.md"), encoding: .utf8) else {
                return .failure(AgentToolError("There’s no Agent Prompt yet."))
            }
            return .success(["contents": [["uri": uri, "mimeType": "text/markdown", "text": text]]])
        }
        let prefix = "sukusho://capture/"
        guard uri.hasPrefix(prefix) else { return .failure(AgentToolError("Unknown resource \(uri).")) }
        let id = String(uri.dropFirst(prefix.count))
        let images = backend.libraryItems().filter(\.isImage)
        let item = id == "latest" ? images.max { $0.createdAt < $1.createdAt } : images.first { $0.id == id }
        guard let item, let jpeg = await backend.jpeg(of: item, maxPixels: 1568) else {
            return .failure(AgentToolError(id == "latest" ? "The Library has no screenshots." : "No screenshot with id \(id)."))
        }
        return .success(["contents": [["uri": uri, "mimeType": "image/jpeg", "blob": jpeg.base64EncodedString()]]])
    }

    static func iso(_ date: Date) -> String { date.formatted(.iso8601) }
}

/// A share the owner finishes by hand, which may outlast the tool call.
@MainActor
final class AgentHandoff {
    enum State {
        case waiting, working
        case done([String: Any])
        case failed(String)
        case cancelled
    }

    private(set) var state = State.waiting

    func start(_ work: @escaping () async throws -> [String: Any]) {
        guard case .waiting = state else { return }
        state = .working
        Task {
            do { state = .done(try await work()) } catch { state = .failed(error.localizedDescription) }
        }
    }

    func cancel() {
        if case .waiting = state { state = .cancelled }
    }

    func wait(upTo limit: Duration, poll: Duration, sleep: (Duration) async -> Void) async -> State {
        var waited = Duration.zero
        while waited < limit, !Task.isCancelled {
            switch state {
            case .waiting, .working: break
            default: return state
            }
            await sleep(poll)
            waited += poll
        }
        return state
    }
}

// MARK: - The owner's Worker

/// The Cloud routes the tools use, with the owner's token. Apart from the app,
/// so a local Worker can stand in.
nonisolated struct AgentCloud: Sendable {
    let workerBase: String
    let token: String
    var session: URLSession = .shared

    func version() async -> String? { await CloudGalleryAPI.workerVersion(workerBase: workerBase, session: session) }

    func uploads(received: Bool = false) async throws -> [CloudUpload] {
        var uploads: [CloudUpload] = []
        var offset: Int? = 0
        while let current = offset {
            guard let request = CloudUploadList.request(workerBase: workerBase, token: token, offset: current, received: received) else {
                throw CloudUploadError.invalidURL
            }
            let (data, response) = try await session.data(for: request)
            try CloudGalleryAPI.expect(200, data, response)
            let page = try CloudUploadList.decode(data)
            uploads += page.uploads
            // Only forward, so a confused Worker can't loop the app.
            offset = page.next.flatMap { $0 > current ? $0 : nil }
        }
        return CloudUploadList.deduplicated(uploads)
    }

    func galleries() async throws -> [CloudGallery] {
        try await CloudGalleryAPI.list(workerBase: workerBase, token: token, session: session)
    }

    func update(id: String, expiresAt: Date??, anonymousComments: Bool?) async throws -> CloudUpload? {
        guard let request = CloudUploadList.patchRequest(workerBase: workerBase, token: token, id: id,
                                                         expiresAt: expiresAt, allowAnonymousComments: anonymousComments) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        try CloudGalleryAPI.expect(200, data, response)
        return try? CloudUploadList.decodeUpload(data)
    }

    func deleteUpload(_ id: String) async throws {
        guard let request = CloudGalleryAPI.deleteUploadRequest(workerBase: workerBase, token: token, uploadID: id) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try CloudGalleryAPI.expect(200, data, response)
    }

    func deleteGallery(_ id: String) async throws {
        try await CloudGalleryAPI.delete(galleryID: id, workerBase: workerBase, token: token, session: session)
    }

    func fileRequests() async throws -> [CloudFileRequest] {
        guard let request = CloudFileRequestAPI.listRequest(workerBase: workerBase, token: token) else { throw CloudUploadError.invalidURL }
        let (data, response) = try await session.data(for: request)
        try CloudGalleryAPI.expect(200, data, response)
        return try CloudFileRequestAPI.decodeList(data)
    }

    func createFileRequest(_ draft: CloudFileRequestDraft) async throws -> CloudFileRequest {
        guard let request = CloudFileRequestAPI.createRequest(workerBase: workerBase, token: token, draft: draft) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        try CloudGalleryAPI.expect(201, data, response)
        return try CloudFileRequestAPI.decodeCreated(data)
    }

    func closeFileRequest(_ id: String) async throws {
        guard let request = CloudFileRequestAPI.closeRequest(workerBase: workerBase, token: token, id: id) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { try CloudGalleryAPI.expect(200, data, response); return }
    }

    func comments() async throws -> [CloudComment] {
        try await feed { CloudCommentList.request(workerBase: workerBase, token: token, offset: $0) } decode: {
            let page = try CloudCommentList.decode($0)
            return (page.comments, page.next)
        }
    }

    func likes() async throws -> [CloudLike] {
        try await feed { CloudLikeList.request(workerBase: workerBase, token: token, offset: $0) } decode: {
            let page = try CloudLikeList.decode($0)
            return (page.likes, page.next)
        }
    }

    private func feed<Item: CloudFeedItem>(_ makeRequest: (Int) -> URLRequest?,
                                           decode: (Data) throws -> (items: [Item], next: Int?)) async throws -> [Item] {
        var items: [Item] = []
        var offset: Int? = 0
        while let current = offset {
            guard let request = makeRequest(current) else { throw CloudUploadError.invalidURL }
            let (data, response) = try await session.data(for: request)
            try CloudGalleryAPI.expect(200, data, response)
            let page = try decode(data)
            items += page.items
            offset = page.next.flatMap { $0 > current ? $0 : nil }
        }
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }
}
