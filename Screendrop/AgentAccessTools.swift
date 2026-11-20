//
//  AgentAccessTools.swift
//  Screendrop
//
//  The MCP tools and resources Sukusho offers agents (phase 1 of the spec in
//  notes/specs/2026-11-08-sukusho-mcp.md): their schemas, argument checks,
//  the owner's approvals, and result shapes. What a tool does to the Library
//  or the Cloud goes through `AgentBackend`, so this runs without the app.
//

import AppKit

// MARK: - What the backend works with

nonisolated struct AgentItem: Sendable, Equatable {
    let id: String
    /// The owner's own name for it, else when it was taken.
    let title: String
    /// The title Apple Intelligence wrote from the capture's text, when the owner hasn't named it:
    /// outside text in effect, so tools return it under `untrusted`.
    var modelTitle: String? = nil
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
    /// What the Library card shows.
    var shownTitle: String { modelTitle ?? title }
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
    /// The note the owner had Draft message write in Share Options; model-written, so it reaches agents as untrusted.
    var message: String? = nil
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
    /// A capture's or a clip's image file, downscaled.
    func jpeg(of file: URL, maxPixels: Int) async -> Data?
    func shareOne(_ item: AgentItem, settings: AgentShareSettings) async throws -> AgentShareResult
    func shareGallery(_ items: [AgentItem], settings: AgentShareSettings) async throws -> AgentShareResult
    func createFileRequest(_ draft: CloudFileRequestDraft) async throws -> CloudFileRequest
    /// After links changed or went (`deleted`: upload and gallery IDs): the Library's cards and Cloud pages catch up.
    func cloudDidChange(deleted: Set<String>)
    func latestAgentPrompt() -> AgentPromptInfo?
    func exportAgentPrompt(_ item: AgentItem) async throws -> AgentPromptInfo
    func capture(_ mode: AgentCaptureMode) async -> AgentCaptureOutcome
    /// What Share Options' Draft message writes from: a recording's summary and chapters.
    func messageSource(of item: AgentItem) -> ShareMessageSource
    /// Clipboard history as the popup has it, Saved clips and snippets included; nil while history is off.
    func clipboardEntries() async throws -> [ClipboardEntry]?
    /// The history's store while history is on, nil while it's off; a new one each time it's turned on.
    var clipboardStore: ClipboardHistoryStore? { get }
    /// The name Information › Source shows for an app; nil when it isn't on this Mac.
    func appName(_ bundleID: String?) -> String?
    /// The popup's paste up to ⌘V (`ClipboardWriter.restore`); false when the clip couldn't be written, or
    /// `shouldWrite` said no just before the write.
    func restoreClip(_ entry: ClipboardEntry, shouldWrite: () -> Bool) async -> Bool
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
    /// Offers Draft message in Share Options, for one capture.
    var messageSource: ShareMessageSource? = nil
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
    /// Its helper went away, or agent access was turned off (`AgentToolbox.end`).
    var isClosed = false
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
            // A failed clipboard call logs its status alone: its message can echo what the caller sent, copied text included.
            let summary = result.isError && name.hasPrefix("clipboard_") ? result.object["status"] as? String ?? "error" : result.summary
            log.add(agent: session.agent.displayName, tool: name, result: summary, now: now())
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
            case "clipboard_list": return try await clipboardList(raw, session)
            case "clipboard_get": return try await clipboardGet(raw, session)
            case "clipboard_restore": return try await clipboardRestore(raw, session)
            default: return .error("Unknown tool \(name).")
            }
        } catch let error as AgentToolError {
            return .error(error.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: Approval

    /// Nil when the owner said no or didn't answer in time, or the helper went away first. One ask per agent and
    /// group at a time: a second call waits for the first, whose answer may cover it. Each call has 60 seconds from
    /// when it came in, waiting included, and a no to the ask it waited on, or no answer, is its no too (Astra, round 2).
    private func approve(_ group: AgentGroup, items: [String], session: AgentSession, ask: AgentAsk) async -> AgentDecision? {
        // A helper that went away asks nothing, and no grant carries it (Astra, round 3).
        guard !session.isClosed else { return nil }
        if isAllowed(group, items: items, session: session) { return .once }
        let deadline = now().addingTimeInterval(Double(askTimeout.components.seconds))
        // A program Sukusho can't name shares its signer with every other such one: its helper waits only on its own asks.
        let key = (session.agent.isResolved ? session.agent.key : session.id.uuidString) + "|" + group.rawValue
        while let turn = asking[key] {
            while asking[key] === turn, !session.isClosed, now() <= deadline { await sleep(poll) }
            guard asking[key] !== turn, !session.isClosed, !turn.denied else { return nil }
        }
        guard !session.isClosed else { return nil }
        if isAllowed(group, items: items, session: session) { return .once }
        let left = deadline.timeIntervalSince(now())
        guard left > 0 else { return nil }
        let turn = AskTurn()
        asking[key] = turn
        defer { asking[key] = nil }
        var ask = ask
        ask.deadline = deadline
        let pending = AgentPendingAnswer<AgentDecision>(sleep: sleep)
        var answeredAt: Date?
        let id = UUID()
        openAsks[id] = (session, { pending.give(nil) })
        let close = asker.ask(ask) { [self] decision in
            if pending.answer == nil {
                answeredAt = now()
                // Recorded here, so it holds for the waiting calls even if this helper goes before it's read.
                if decision == nil { turn.denied = true }
            }
            pending.give(decision)
        }
        let answer = await pending.wait(upTo: .seconds(left), poll: poll)
        openAsks[id] = nil
        close()
        guard !session.isClosed else { return nil }
        // When the owner answered, not when this wait noticed: a click inside the window counts, one past it doesn't.
        guard let decision = answer ?? nil, let answeredAt, answeredAt <= deadline else {
            turn.denied = true
            return nil
        }
        remember(decision, group, session)
        return decision
    }

    /// Plain asks open now, so `end` can deny them.
    private var openAsks: [UUID: (session: AgentSession, cancel: () -> Void)] = [:]
    /// The ask on screen for each agent and group key, which other calls with that key wait on.
    private var asking: [String: AskTurn] = [:]
    private final class AskTurn {
        /// The owner said no or didn't answer: the calls waiting on it are denied too.
        var denied = false
    }

    /// A helper that went away, or each one when agent access is turned off: its open asks are denied and closed, and
    /// no answer after this counts or keeps a grant.
    func end(_ session: AgentSession) {
        session.isClosed = true
        for (id, open) in openAsks where open.session === session {
            openAsks[id] = nil
            open.cancel()
        }
    }

    private func isAllowed(_ group: AgentGroup, items: [String], session: AgentSession) -> Bool {
        let kept = session.agent.isResolved
        let sessionGrants = kept && grants.hasSession(group, for: session.agent) ? session.grants.union([group]) : session.grants
        return AgentPolicy.allowed(group, session: sessionGrants, always: kept && grants.hasAlways(group, for: session.agent),
                                   items: items, owned: grants.owned(by: session.agent))
    }

    private func remember(_ decision: AgentDecision, _ group: AgentGroup, _ session: AgentSession) {
        switch decision {
        case .once: break
        // A program Sukusho couldn't name shares its signer with every other such program: its grant stays with this
        // helper, and Always, which it isn't offered, is this once. A helper grant would skip Always's rule that what
        // the agent didn't add still asks (Astra, round 2).
        case .always where !session.agent.isResolved: break
        case .session where !session.agent.isResolved: session.grants.insert(group)
        case .session where group.sessionOutlivesHelper: grants.grantSession(group, to: session.agent, now: now())
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
            let fields = [item.title, item.modelTitle, item.fileURL.lastPathComponent, item.source?.appName, item.source?.windowTitle]
                .compactMap { $0 } + item.tags
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
            image = await backend.jpeg(of: item.fileURL, maxPixels: 1568)
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
        // Window titles come from other apps and web pages, and a model's title from the capture's text.
        var untrusted: [String: Any] = [:]
        if let source = item.source {
            untrusted["app"] = source.appName
            if let window = source.windowTitle { untrusted["window"] = window }
        }
        if let modelTitle = item.modelTitle { untrusted["title"] = modelTitle }
        if !untrusted.isEmpty { object["untrusted"] = AgentUntrusted.wrap(untrusted) }
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
            .flatMap { $0.isEmpty ? nil : $0 } ?? (items.count == 1 ? items[0].shownTitle : nil)
        settings.expiry = try args.expiry("expires_in_days", allowsNever: true) ?? settings.expiry
        settings.comments = try args.bool("comments") ?? settings.comments
        settings.anonymousComments = try args.bool("anonymous_comments") ?? settings.anonymousComments
        let wantsPassword = try args.bool("password") ?? false
        // The owner sees the names their Library shows.
        let what = items.count == 1 ? "share “\(items[0].shownTitle)”" : "share \(items.count) images as a gallery"
        var ask = AgentAsk(agent: session.agent, group: .publish, action: what,
                           details: items.prefix(8).map(\.shownTitle) + (items.count > 8 ? ["and \(items.count - 8) more"] : []),
                           thumbnails: items.filter(\.isImage).prefix(6).map(\.fileURL))
        ask.encryptionUnavailable = items.count > 1 ? "Galleries can’t be end-to-end encrypted yet."
            : CloudShareSeal.unavailableReason(fileURLs: [items[0].fileURL], isRecording: !items[0].isImage)
        if items.count == 1 { ask.messageSource = backend.messageSource(of: items[0]) }
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
        var email: [String: Any] = AgentEmail.share(title: shared.title, url: shared.url, expiresAt: shared.expiresAt,
                                                    hasPassword: shared.hasPassword, thumbnailURL: shared.thumbnailURL, count: items.count)
        // The model wrote it from the capture's text and summary: outside text, kept out of the ready-made draft.
        if let message = settings.message { email["untrusted"] = AgentUntrusted.wrap(["message": message]) }
        var object: [String: Any] = [
            "status": "shared", "id": shared.id, "kind": shared.isGallery ? "gallery" : "upload", "url": shared.url,
            "title": shared.title, "has_password": shared.hasPassword, "expires_at": shared.expiresAt.map(Self.iso) ?? NSNull(),
            "email": email,
        ]
        // A link named after a model's title carries that title as outside text.
        if items.count == 1, let modelTitle = items[0].modelTitle, shared.title == modelTitle {
            object["title"] = nil
            object["untrusted"] = AgentUntrusted.wrap(["title": modelTitle])
        }
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

    // MARK: Clipboard

    private func clipboardList(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["kind", "saved", "limit", "before"])
        guard let filter = ClipboardFilter(rawValue: try args.string("kind", maxLength: 20) ?? "all"), AgentClips.kinds.contains(filter) else {
            throw AgentToolError("kind must be all, images, text, links, colors or files.")
        }
        let saved = try args.bool("saved") ?? false
        let limit = try args.int("limit", in: 1...100) ?? 50
        let before = try args.string("before", maxLength: 200).map(AgentClips.Cursor.init(text:))
        guard let history = try await clipboardHistory(session) else { return .denied }
        let page = AgentClips.page(history.entries, filter: filter, saved: saved, before: before, limit: limit)
        return ToolResult(object: ["total": page.total, "clips": page.clips.map(clip), "next_before": page.next?.text ?? NSNull()],
                          summary: "\(page.clips.count) of \(page.total) clips")
    }

    private func clipboardGet(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id", "image"])
        let id = try args.required("id")
        let wantsImage = try args.bool("image") ?? false
        guard let history = try await clipboardHistory(session) else { return .denied }
        let entry = try AgentClips.find(id, in: history.entries)
        var object = clip(entry)
        if let text = entry.text {
            var untrusted = object["untrusted"] as? [String: Any] ?? [:]
            untrusted["text"] = String(text.prefix(AgentClips.textLength))
            object["untrusted"] = untrusted
            if text.count > AgentClips.textLength { object["text_truncated"] = true }
        }
        var image: Data?
        if wantsImage {
            guard entry.kind == .image else { throw AgentToolError("image is for image clips; this is a \(object["kind"] as? String ?? "text") clip.") }
            if let url = entry.imageURL { image = await backend.jpeg(of: url, maxPixels: 1024) }
            guard try history.stillAllowed() else { return .denied }
            if image == nil { throw AgentToolError("Sukusho couldn’t read this clip’s image.") }
        }
        return ToolResult(object: object, image: image, summary: "read")
    }

    private func clipboardRestore(_ raw: [String: Any], _ session: AgentSession) async throws -> ToolResult {
        let args = try AgentArguments(raw, allowed: ["id"])
        let id = try args.required("id")
        guard let history = try await clipboardHistory(session) else { return .denied }
        // Asked again as it writes: the clip's formats are read first, and access can end meanwhile (Astra, round 2).
        guard await backend.restoreClip(try AgentClips.find(id, in: history.entries),
                                        shouldWrite: { (try? history.stillAllowed()) == true }) else {
            guard try history.stillAllowed() else { return .denied }
            throw AgentToolError("Sukusho couldn’t put this clip back on the clipboard: its image file is gone, or the clipboard refused it.")
        }
        return ToolResult(object: ["status": "restored", "id": id], summary: "restored")
    }

    private static let historyOff = AgentToolError("Clipboard history is off in Sukusho (Settings › Clipboard › Keep clipboard history).")

    /// The history, once the owner lets this agent read it; nil when they don't. Off asks nothing. Read after the
    /// answer, so what was deleted, or history turned off, while the ask was open stays out. `stillAllowed`, asked
    /// after each later wait, throws once history is off, or was turned off and on again (a new store), and is false
    /// once the helper went away or the grant the call rode on was revoked; Just this once holds for its call.
    private func clipboardHistory(_ session: AgentSession) async throws
        -> (entries: [ClipboardEntry], stillAllowed: () throws -> Bool)? {
        guard backend.clipboardStore != nil else { throw Self.historyOff }
        let ask = AgentAsk(agent: session.agent, group: .clipboard, action: "read your clipboard history",
                           details: ["It sees what you copied and can put a clip back on the clipboard.",
                                     "Concealed copies, such as passwords, are never kept."])
        guard await approve(.clipboard, items: [], session: session, ask: ask) != nil else { return nil }
        let byGrant = isAllowed(.clipboard, items: [], session: session)
        let store = backend.clipboardStore
        let revocations = grants.revocations
        let stillAllowed = { [self] () throws -> Bool in
            guard let store, backend.clipboardStore === store else { throw Self.historyOff }
            // Grants only grow between revocations, so an unchanged count means the call's grant still stands.
            return !session.isClosed && (!byGrant || grants.revocations == revocations)
        }
        guard let entries = try await backend.clipboardEntries() else { throw Self.historyOff }
        return try stillAllowed() ? (entries, stillAllowed) : nil
    }

    private func clip(_ entry: ClipboardEntry) -> [String: Any] {
        AgentClips.clip(entry, appName: backend.appName(entry.sourceBundleID))
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
        guard let item, let jpeg = await backend.jpeg(of: item.fileURL, maxPixels: 1568) else {
            return .failure(AgentToolError(id == "latest" ? "The Library has no screenshots." : "No screenshot with id \(id)."))
        }
        return .success(["contents": [["uri": uri, "mimeType": "image/jpeg", "blob": jpeg.base64EncodedString()]]])
    }

    static func iso(_ date: Date) -> String { date.formatted(.iso8601) }
}

/// Clipboard history as the clipboard tools list it: the popup's order, filters and Information.
nonisolated enum AgentClips {
    /// The list's preview and title, in characters.
    static let previewLength = 200
    /// clipboard_get's text, as library_get's.
    static let textLength = 20_000
    /// The popup's type menu; Saved is its own switch, and snippets aren't listed.
    static let kinds: [ClipboardFilter] = [.all, .images, .text, .links, .colors, .files]

    /// Where a page ends: a clip's place in its list, by time and then id, so clips copied at one instant page apart.
    /// Sent as "<seconds since 1970>:<id>"; Double's text form reads back as the same number.
    struct Cursor: Comparable {
        let time: Double
        let id: String

        init(_ entry: ClipboardEntry, saved: Bool) {
            time = (saved ? entry.pinnedAt ?? entry.lastCopiedAt : entry.lastCopiedAt).timeIntervalSince1970
            id = entry.id
        }

        init(text: String) throws {
            guard let colon = text.firstIndex(of: ":"), let time = Double(text[..<colon]), time.isFinite,
                  case let id = String(text[text.index(after: colon)...]), !id.isEmpty else {
                throw AgentToolError("before isn’t a cursor from clipboard_list.")
            }
            self.time = time
            self.id = id
        }

        var text: String { "\(time):\(id)" }

        static func < (a: Cursor, b: Cursor) -> Bool { (a.time, a.id) < (b.time, b.id) }
    }

    /// The popup's list, newest first: the history by last copy, or Saved by when each was saved. Never snippets.
    /// The type menu sorts by the same slice the row shows (`shown`), so the filter can't tell what lies past it.
    static func page(_ entries: [ClipboardEntry], filter: ClipboardFilter, saved: Bool, before: Cursor?, limit: Int)
        -> (clips: [ClipboardEntry], total: Int, next: Cursor?) {
        let listed = entries.filter { $0.isArchived == saved && ClipboardList.matches(shown($0), filter: filter) }
            .map { (cursor: Cursor($0, saved: saved), entry: $0) }
            .sorted { $0.cursor > $1.cursor }
        let rest = listed.filter { item in before.map { item.cursor < $0 } ?? true }
        let page = rest.prefix(limit)
        return (page.map(\.entry), listed.count, rest.count > limit ? page.last?.cursor : nil)
    }

    static func find(_ id: String, in entries: [ClipboardEntry]) throws -> ClipboardEntry {
        guard let entry = entries.first(where: { $0.id == id && $0.kind != .snippet }) else {
            throw AgentToolError("No clip with id \(id). clipboard_list lists them.")
        }
        return entry
    }

    /// The row's icon: the popup's kinds, with code apart from text.
    static func kind(of entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .image: return "image"
        case .files: return "files"
        case .snippet: return "snippet"
        case .text:
            switch ClipboardList.textForm(of: entry) {
            case .color: return "color"
            case .link: return "link"
            default: return ClipboardList.looksLikeCode(entry) ? "code" : "text"
            }
        }
    }

    /// A clip as the popup's row and Information show it. What was copied, and the app it names as its source, is
    /// outside text: it goes under `untrusted`. Never more than `previewLength` characters of the text.
    /// The clip with only the first `previewLength` characters of its text. The kind, type, title, colour, domain and
    /// the type menu's sorting are worked out from these, never from the rest: the popup's title skips blank lines and
    /// names a path's file, and a colour or link is read after trimming, all of which could reach past them
    /// (Astra #4, rounds 1 to 3).
    static func shown(_ entry: ClipboardEntry) -> ClipboardEntry {
        var shown = entry
        shown.text = entry.text.map { String($0.prefix(previewLength)) }
        return shown
    }

    static func clip(_ entry: ClipboardEntry, appName: String?) -> [String: Any] {
        let text = entry.text ?? ""
        let shown = Self.shown(entry)
        var object: [String: Any] = [
            // A file list's type counts its files, which isn't content: that one comes from the whole list.
            "id": entry.id, "kind": kind(of: shown), "content_type": ClipboardList.typeName(of: entry.kind == .text ? shown : entry),
            "size_bytes": entry.byteSize, "times_copied": entry.timesCopied,
            "first_copied_at": entry.firstCopiedAt.formatted(.iso8601), "last_copied_at": entry.lastCopiedAt.formatted(.iso8601),
            "saved": entry.isArchived, "from_another_device": entry.isRemote,
        ]
        if entry.isArchived, let saved = entry.pinnedAt { object["saved_at"] = saved.formatted(.iso8601) }
        var untrusted: [String: Any] = ["title": String(ClipboardList.title(of: shown).prefix(previewLength))]
        var preview: String? = text
        switch ClipboardList.textForm(of: shown) {
        case .color(let hex):
            preview = hex
            object["color"] = color(hex)
        case .link:
            // Only a host the cut leaves whole: the same one the whole link has.
            if let host = URL(string: shown.text ?? "")?.host(), host == URL(string: text)?.host() { untrusted["domain"] = host }
        case .plain:
            object["characters"] = text.count
            object["words"] = text.split(whereSeparator: \.isWhitespace).count
            object["lines"] = text.split(separator: "\n", omittingEmptySubsequences: false).count
        case nil: break
        }
        switch entry.kind {
        case .image:
            preview = nil
            object["width"] = entry.pixelWidth
            object["height"] = entry.pixelHeight
            if let category = entry.category { untrusted["category"] = category }
            if !entry.keywords.isEmpty { untrusted["keywords"] = entry.keywords }
        case .files:
            object["file_count"] = text.split(separator: "\n").count
        case .text, .snippet: break
        }
        if let preview {
            untrusted["preview"] = String(preview.prefix(previewLength))
            // The text's own length: a colour's hex stands in for a slice that may have more after it (Astra, round 3).
            if text.count > previewLength { untrusted["preview_truncated"] = true }
        }
        if let appName { untrusted["app"] = appName }
        if let bundleID = entry.sourceBundleID { untrusted["bundle_id"] = bundleID }
        object["untrusted"] = AgentUntrusted.wrap(untrusted, note: AgentUntrusted.clipboardNote)
        return object
    }

    /// Information's RGB and HSB for a color, worked out as the popup does.
    static func color(_ hex: String) -> [String: Any]? {
        guard let parts = ClipboardCapturePolicy.components(ofHex: hex) else { return nil }
        let color = NSColor(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
        return ["hex": hex,
                "rgb": [parts.red, parts.green, parts.blue].map { Int(($0 * 255).rounded()) },
                "hsb": [color.hueComponent * 360, color.saturationComponent * 100, color.brightnessComponent * 100].map { Int($0.rounded()) }]
    }
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
