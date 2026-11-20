import AppKit
import Foundation
import Testing

/// The clipboard tools Unleash lists and pastes through: the popup's order and filters, short previews, the owner's
/// consent per agent, and the popup's own write back to the pasteboard.
@Suite @MainActor
struct AgentClipboardTests {
    /// In the past: a restore is stamped now, and must land above these.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A harness whose backend reads a real history store in a temporary folder.
    private func clipHarness(agent: AgentIdentity = AgentHarness.agent) throws -> AgentHarness {
        let harness = AgentHarness(agent: agent)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentClipboardTests-\(UUID().uuidString)")
        harness.backend.clipStore = try ClipboardHistoryStore(directory: folder, deviceID: "test-mac")
        harness.asker.reply = .allow(.session)
        return harness
    }

    private func text(_ value: String, source: String? = nil) -> ClipboardCapture {
        var capture = ClipboardCapture(kind: .text, hash: ClipboardPasteboardReader.digest(Data(value.utf8)), text: value,
                                       byteSize: value.utf8.count)
        capture.sourceBundleID = source
        return capture
    }

    @discardableResult
    private func record(_ harness: AgentHarness, _ capture: ClipboardCapture, at date: Date) async throws -> String {
        switch try await #require(harness.backend.clipStore).record(capture, at: date) {
        case .inserted(let id), .bumped(let id), .stacked(let id): return id
        }
    }

    private func clips(_ result: AgentToolbox.ToolResult) -> [[String: Any]] {
        result.object["clips"] as? [[String: Any]] ?? []
    }

    private func untrusted(_ clip: [String: Any]) -> [String: Any] { clip["untrusted"] as? [String: Any] ?? [:] }

    private func previews(_ result: AgentToolbox.ToolResult) -> [String] {
        clips(result).compactMap { untrusted($0)["preview"] as? String }
    }

    // MARK: Order and paging

    @Test func historyIsNewestCopiedFirstAndSavedIsItsOwnList() async throws {
        let harness = try clipHarness()
        let a = try await record(harness, text("a"), at: start)
        try await record(harness, text("b"), at: start + 1)
        let c = try await record(harness, text("c"), at: start + 2)
        try await record(harness, text("a"), at: start + 3)
        try await record(harness, text("d"), at: start + 4)
        let store = try #require(harness.backend.clipStore)
        try await store.moveToSaved(ids: [a], at: start + 10)
        try await store.moveToSaved(ids: [c], at: start + 11)
        try await store.addSnippet(title: "Sig", text: "snippet", at: start + 20)

        // The popup's list: copied again goes to the top, saved clips and snippets aren't in it.
        let history = await harness.call("clipboard_list")
        #expect(previews(history) == ["d", "b"])
        #expect(history.object["total"] as? Int == 2)
        // Saved: newest saved first.
        let saved = await harness.call("clipboard_list", ["saved": true])
        #expect(previews(saved) == ["c", "a"])
        #expect(clips(saved).allSatisfy { $0["saved"] as? Bool == true && $0["saved_at"] is String })
        #expect(clips(history).allSatisfy { $0["saved"] as? Bool == false && $0["saved_at"] == nil })
    }

    @Test func kindsFollowThePopupsTypeMenu() async throws {
        let harness = try clipHarness()
        try await record(harness, text("plain words"), at: start)
        try await record(harness, text("let x = foo(1);\nreturn x == 2"), at: start + 1)
        try await record(harness, text("https://example.com/page"), at: start + 2)
        try await record(harness, text("#ff8800", source: "com.figma.Desktop"), at: start + 3)

        let all = clips(await harness.call("clipboard_list"))
        #expect(all.map { $0["kind"] as? String } == ["color", "link", "code", "text"])
        // Text is plain text, code included, as the popup's Text filter.
        #expect(previews(await harness.call("clipboard_list", ["kind": "text"])) == ["let x = foo(1);\nreturn x == 2", "plain words"])
        #expect(previews(await harness.call("clipboard_list", ["kind": "links"])) == ["https://example.com/page"])
        let colour = try #require(clips(await harness.call("clipboard_list", ["kind": "colors"])).first)
        let color = try #require(colour["color"] as? [String: Any])
        #expect(color["hex"] as? String == "#FF8800")
        #expect(color["rgb"] as? [Int] == [255, 136, 0])
        #expect(color["hsb"] as? [Int] == [32, 100, 100])
        #expect(colour["content_type"] as? String == "Color")
        #expect(untrusted(colour)["bundle_id"] as? String == "com.figma.Desktop")
        #expect(agentStatus(await harness.call("clipboard_list", ["kind": "snippets"])) == "error")
    }

    @Test func pagesFollowOnWithoutRepeatsEvenWhenAClipIsCopiedAgain() async throws {
        let harness = try clipHarness()
        for (offset, value) in ["1", "2", "3", "4", "5"].enumerated() {
            try await record(harness, text(value), at: start + Double(offset))
        }
        let first = await harness.call("clipboard_list", ["limit": 2])
        #expect(previews(first) == ["5", "4"])
        #expect(first.object["total"] as? Int == 5)
        let cursor = try #require(first.object["next_before"] as? String)
        // "5" is copied again between pages: it goes to the top, and the next page carries on after "4".
        try await record(harness, text("5"), at: start + 100)
        let second = await harness.call("clipboard_list", ["limit": 2, "before": cursor])
        #expect(previews(second) == ["3", "2"])
        let last = await harness.call("clipboard_list", ["limit": 2, "before": try #require(second.object["next_before"] as? String)])
        #expect(previews(last) == ["1"])
        #expect(last.object["next_before"] is NSNull)
        // Two clips copied at the same instant still page apart.
        let tied = try clipHarness()
        try await record(tied, text("x"), at: start)
        try await record(tied, text("y"), at: start)
        let one = await tied.call("clipboard_list", ["limit": 1])
        let two = await tied.call("clipboard_list", ["limit": 1, "before": try #require(one.object["next_before"] as? String)])
        #expect(Set(previews(one) + previews(two)) == ["x", "y"])
        #expect(agentStatus(await harness.call("clipboard_list", ["before": "not a cursor"])) == "error")
        #expect(agentStatus(await harness.call("clipboard_list", ["limit": 101])) == "error")
    }

    // MARK: What crosses

    @Test func theListCarriesAShortPreviewNeverTheFullText() async throws {
        let harness = try clipHarness()
        let long = String(repeating: "abcdefghij", count: 50) + "TAIL-NEVER-LISTED"
        let id = try await record(harness, text(long, source: "com.apple.Safari"), at: start)
        harness.backend.appNames["com.apple.Safari"] = "Safari"
        let result = await harness.call("clipboard_list")
        let clip = try #require(clips(result).first)
        let shown = untrusted(clip)
        #expect((shown["preview"] as? String)?.count == AgentClips.previewLength)
        #expect(shown["preview_truncated"] as? Bool == true)
        #expect((shown["title"] as? String).map { $0.count <= AgentClips.previewLength } == true)
        #expect(shown["app"] as? String == "Safari")
        #expect(shown["note"] as? String == AgentUntrusted.clipboardNote)
        #expect(clip["characters"] as? Int == long.count)
        // Nothing past the cap is anywhere in what the list sends.
        let json = try #require(result.mcp["content"] as? [[String: Any]]).first?["text"] as? String ?? ""
        #expect(!json.contains("TAIL"))
        // clipboard_get has more, up to its own bound.
        let detail = await harness.call("clipboard_get", ["id": id])
        #expect((untrusted(detail.object)["text"] as? String) == long)
        #expect(detail.object["text_truncated"] == nil)
        let huge = try await record(harness, text(String(repeating: "z", count: AgentClips.textLength + 5)), at: start + 1)
        let capped = await harness.call("clipboard_get", ["id": huge])
        #expect((untrusted(capped.object)["text"] as? String)?.count == AgentClips.textLength)
        #expect(capped.object["text_truncated"] as? Bool == true)
    }

    @Test func anImagesPictureComesOnlyFromClipboardGet() async throws {
        let harness = try clipHarness()
        let png = Data(UUID().uuidString.utf8) + Data(repeating: 7, count: 64)
        let id = try await record(harness, ClipboardCapture(kind: .image, hash: ClipboardPasteboardReader.digest(png), image: png,
                                                            imageExtension: "png", pixelWidth: 40, pixelHeight: 30,
                                                            byteSize: png.count), at: start)
        let listed = await harness.call("clipboard_list")
        let clip = try #require(clips(listed).first)
        #expect(listed.image == nil)
        #expect(clip["kind"] as? String == "image")
        #expect(clip["width"] as? Int == 40 && clip["height"] as? Int == 30)
        #expect(clip["content_type"] as? String == "PNG image")
        #expect(untrusted(clip)["preview"] == nil)
        #expect(await harness.call("clipboard_get", ["id": id]).image == nil)
        #expect(await harness.call("clipboard_get", ["id": id, "image": true]).image != nil)
        let words = try await record(harness, text("words"), at: start + 1)
        #expect(agentStatus(await harness.call("clipboard_get", ["id": words, "image": true])) == "error")
    }

    /// Concealed and transient copies (password managers, nspasteboard.org's markers) never reach the store, so
    /// no tool can return them.
    @Test func concealedAndTransientCopiesNeverComeOut() async throws {
        let harness = try clipHarness()
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("AgentClipboardHistory-\(UUID().uuidString)")
        let copies: [[String: String]] = [
            ["public.utf8-plain-text": "hunter2-concealed", "org.nspasteboard.ConcealedType": ""],
            ["public.utf8-plain-text": "123456-transient", "org.nspasteboard.TransientType": ""],
            ["public.utf8-plain-text": "an ordinary copy"],
        ]
        for (offset, values) in copies.enumerated() {
            let pasteboard = NSPasteboard(name: .init("AgentClipboardTest-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            for (type, value) in values { item.setString(value, forType: .init(type)) }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            // What the monitor does with each copy it reads.
            if case .captured(let capture) = ClipboardPasteboardReader.read(
                pasteboard, changeCount: pasteboard.changeCount, frontmostBundleID: "com.example.front",
                ignoredApps: [], historyDirectory: history).outcome {
                try await record(harness, capture, at: start + Double(offset))
            }
        }
        for saved in [false, true] {
            let result = await harness.call("clipboard_list", ["saved": saved])
            let json = try #require(result.mcp["content"] as? [[String: Any]]).first?["text"] as? String ?? ""
            #expect(!json.contains("hunter2") && !json.contains("123456"))
        }
        #expect(previews(await harness.call("clipboard_list")) == ["an ordinary copy"])
    }

    // MARK: Consent

    @Test func itAsksOnceAndAlwaysCoversOnlyThisAgentAndOnlyTheClipboard() async throws {
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        let id = try await record(harness, text("secret-ish"), at: start)
        harness.asker.reply = .allow(.always)
        #expect(previews(await harness.call("clipboard_list")) == ["secret-ish"])
        #expect(harness.asker.asks.count == 1)
        let ask = try #require(harness.asker.asks.first)
        #expect(ask.group == .clipboard && ask.grantable && ask.deadline != nil)
        #expect(AgentGroup.clipboard.title == "Read my clipboard history")
        // No more asks, for any clipboard tool, in this helper or the next.
        harness.asker.reply = .deny
        #expect(previews(await harness.call("clipboard_list")) == ["secret-ish"])
        #expect(agentStatus(await harness.call("clipboard_get", ["id": id])) != "denied")
        let next = AgentSession(agent: AgentHarness.agent)
        #expect(clips(await harness.toolbox.call("clipboard_list", [:], session: next)).count == 1)
        #expect(harness.asker.asks.count == 1)
        #expect(AgentGrantStore(defaults: harness.defaults).hasAlways(.clipboard, for: AgentHarness.agent))
        // It isn't Library sharing or capturing.
        #expect(!harness.grants.hasAlways(.publish, for: AgentHarness.agent))
        #expect(!harness.grants.hasAlways(.capture, for: AgentHarness.agent))
        #expect(agentStatus(await harness.call("capture", ["mode": "full"])) == "denied")

        // Another agent (Claude Code, say) is asked for itself, and a no gives it nothing.
        let other = AgentIdentity(signer: "team:Q6L2SF6YDW:com.anthropic.claude-code", signerName: "Anthropic (Q6L2SF6YDW)",
                                  clientName: "claude-code")
        let asksBefore = harness.asker.asks.count
        let denied = await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: other))
        #expect(agentStatus(denied) == "denied")
        #expect(clips(denied).isEmpty)
        #expect(harness.asker.asks.count == asksBefore + 1)
        #expect(agentStatus(await harness.toolbox.call("clipboard_restore", ["id": id], session: AgentSession(agent: other))) == "denied")
        #expect(harness.backend.clipPasteboard.string(forType: .string) == nil)
        // The same name from another program is another agent too.
        let impostor = AgentIdentity(signer: "path:/tmp/Unleash", signerName: "Unleash, unsigned", clientName: AgentHarness.agent.clientName)
        #expect(agentStatus(await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: impostor))) == "denied")
    }

    /// Unleash's helper ends each time its panel hides, so "For this session" lasts until Sukusho quits, for this agent.
    @Test func forThisSessionOutlivesTheHelperUntilSukushoQuits() async throws {
        let harness = try clipHarness()
        try await record(harness, text("x"), at: start)
        harness.asker.reply = .allow(.session)
        #expect(clips(await harness.call("clipboard_list")).count == 1)
        harness.asker.reply = .deny
        // The next panel is a new helper: no ask.
        let next = AgentSession(agent: AgentHarness.agent)
        #expect(clips(await harness.toolbox.call("clipboard_list", [:], session: next)).count == 1)
        #expect(harness.asker.asks.count == 1)
        // Never saved, and never an Always: a restarted Sukusho asks again.
        #expect(harness.grants.hasSession(.clipboard, for: AgentHarness.agent))
        #expect(!AgentGrantStore(defaults: harness.defaults).hasSession(.clipboard, for: AgentHarness.agent))
        #expect(harness.grants.grants.isEmpty)
        // Another agent still asks.
        let other = AgentIdentity(signer: "path:/tmp/other", signerName: "other", clientName: "other")
        #expect(agentStatus(await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: other))) == "denied")
        // Settings' revoke ends it, and so does turning agent access off.
        harness.grants.revoke(AgentHarness.agent.key)
        #expect(agentStatus(await harness.toolbox.call("clipboard_list", [:], session: next)) == "denied")
        harness.asker.reply = .allow(.session)
        _ = await harness.call("clipboard_list")
        harness.grants.endSessions()
        harness.asker.reply = .deny
        #expect(agentStatus(await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: AgentHarness.agent))) == "denied")
        // Sharing's session grant still ends with its helper (AgentGrantTests.sessionAsksOnceForTheRestOfTheHelper).
        #expect(!AgentGroup.publish.sessionOutlivesHelper && !AgentGroup.capture.sessionOutlivesHelper)
    }

    @Test func closingTheLastAskGivesTheKeyboardBackOnlyWhenSukushoShowsNoWindow() {
        let own: pid_t = 100
        let statusItem = AgentFocus.Window(visible: true, ordinary: false)
        let library = AgentFocus.Window(visible: true, ordinary: true)
        let closedLibrary = AgentFocus.Window(visible: false, ordinary: true)
        #expect(AgentFocus.returnsFocus(to: 200, own: own, isActive: true, otherWindows: [statusItem, closedLibrary]))
        #expect(!AgentFocus.returnsFocus(to: 200, own: own, isActive: true, otherWindows: [statusItem, library]))
        #expect(!AgentFocus.returnsFocus(to: own, own: own, isActive: true, otherWindows: []))
        #expect(!AgentFocus.returnsFocus(to: nil, own: own, isActive: true, otherWindows: []))
        // The ask timed out after the owner went to another app: they stay there.
        #expect(!AgentFocus.returnsFocus(to: 200, own: own, isActive: false, otherWindows: []))
    }

    @Test func historyOffSaysSoWithoutAsking() async throws {
        let harness = AgentHarness()
        let result = await harness.call("clipboard_list")
        #expect(agentStatus(result) == "error")
        #expect((result.object["error"] as? String)?.contains("Keep clipboard history") == true)
        #expect(harness.asker.asks.isEmpty)
    }

    @Test func badArgumentsAreRefusedBeforeAsking() async throws {
        let harness = try clipHarness()
        #expect(agentStatus(await harness.call("clipboard_list", ["query": "x"])) == "error")
        #expect(agentStatus(await harness.call("clipboard_list", ["kind": "everything"])) == "error")
        #expect(harness.asker.asks.isEmpty)
    }

    // MARK: Ids and restore

    @Test func anUnknownIdSaysSo() async throws {
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        for tool in ["clipboard_get", "clipboard_restore"] {
            let result = await harness.call(tool, ["id": "gone"])
            #expect(agentStatus(result) == "error")
            #expect(result.isError)
            #expect((result.object["error"] as? String)?.hasPrefix("No clip with id gone.") == true)
        }
        #expect(agentStatus(await harness.call("clipboard_restore")) == "error")
        #expect(harness.backend.clipPasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test func restorePutsEveryRepresentationBackAndCountsACopy() async throws {
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        let rtf = Data("{\\rtf1 Hello}".utf8)
        let html = Data("<b>Hello</b>".utf8)
        var rich = text("Hello", source: "com.apple.Safari")
        rich.richText = ["public.rtf": rtf, "public.html": html]
        let id = try await record(harness, rich, at: start)
        try await record(harness, text("newer"), at: start + 1)

        let result = await harness.call("clipboard_restore", ["id": id])
        #expect(agentStatus(result) == "restored")
        #expect(result.object["id"] as? String == id)
        let item = try #require(harness.backend.clipPasteboard.pasteboardItems?.first)
        #expect(item.string(forType: .string) == "Hello")
        #expect(item.data(forType: .init("public.rtf")) == rtf)
        #expect(item.data(forType: .init("public.html")) == html)
        // nspasteboard.org's paste-back markers, and Sukusho's own, so its monitor doesn't file it again.
        #expect(item.string(forType: .init(ClipboardCapturePolicy.sourceType)) == "com.apple.Safari")
        #expect(item.types.contains(.init(ClipboardWriter.autoGeneratedType)))
        #expect(item.types.contains(.init(ClipboardCapturePolicy.ownType)))
        // One more copy, at the top.
        let top = try #require(clips(await harness.call("clipboard_list")).first)
        #expect(top["id"] as? String == id)
        #expect(top["times_copied"] as? Int == 2)

        // An image goes back as its own bytes.
        let png = Data(UUID().uuidString.utf8) + Data(repeating: 9, count: 64)
        let image = try await record(harness, ClipboardCapture(kind: .image, hash: ClipboardPasteboardReader.digest(png), image: png,
                                                               imageExtension: "png", pixelWidth: 4, pixelHeight: 4,
                                                               byteSize: png.count), at: start + 2)
        #expect(agentStatus(await harness.call("clipboard_restore", ["id": image])) == "restored")
        #expect(harness.backend.clipPasteboard.pasteboardItems?.first?.data(forType: .png) == png)
    }

    @Test func restoringASavedClipKeepsItSavedAndCopiesItIntoHistory() async throws {
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        let id = try await record(harness, text("kept"), at: start)
        try await #require(harness.backend.clipStore).moveToSaved(ids: [id], at: start + 1)
        #expect(agentStatus(await harness.call("clipboard_restore", ["id": id])) == "restored")
        #expect(harness.backend.clipPasteboard.string(forType: .string) == "kept")
        #expect(previews(await harness.call("clipboard_list", ["saved": true])) == ["kept"])
        #expect(previews(await harness.call("clipboard_list")) == ["kept"])
    }

    // MARK: Review fixes (Astra, 2026-11-20)

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }

    /// #1: what the owner deletes, or history turned off, while the ask is open never comes out after it.
    @Test func aClipDeletedOrHistoryTurnedOffDuringTheAskIsNotReturned() async throws {
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        harness.toolbox.askTimeout = .seconds(3600)
        let id = try await record(harness, text("deleted-while-asking"), at: start)
        harness.asker.reply = .never
        let get = Task { await harness.call("clipboard_get", ["id": id]) }
        await waitUntil { harness.asker.laterDecisions.count == 1 }
        try await #require(harness.backend.clipStore).delete(id)
        harness.asker.laterDecisions[0](.once)
        let result = await get.value
        #expect((result.object["error"] as? String)?.hasPrefix("No clip with id") == true)
        #expect(!String(describing: result.object).contains("deleted-while-asking"))

        try await record(harness, text("history-turned-off"), at: start + 1)
        let list = Task { await harness.call("clipboard_list") }
        await waitUntil { harness.asker.laterDecisions.count == 2 }
        harness.backend.clipStore = nil
        harness.asker.laterDecisions[1](.once)
        let listed = await list.value
        #expect(agentStatus(listed) == "error")
        #expect(clips(listed).isEmpty)
    }

    /// #2: a helper that goes away, or agent access turned off, ends its open asks: no answer after that counts.
    @Test func aClosedHelperDeniesItsOpenAskAndKeepsNothing() async throws {
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        harness.toolbox.askTimeout = .seconds(3600)
        let id = try await record(harness, text("restore-after-close"), at: start)
        harness.asker.reply = .never
        let restore = Task { await harness.call("clipboard_restore", ["id": id]) }
        await waitUntil { harness.asker.laterDecisions.count == 1 }
        harness.toolbox.end(harness.session)
        harness.asker.laterDecisions[0](.session)
        #expect(agentStatus(await restore.value) == "denied")
        #expect(harness.asker.closed == 1)
        #expect(harness.backend.clipPasteboard.string(forType: .string) == nil)
        #expect(!harness.grants.hasSession(.clipboard, for: AgentHarness.agent))
    }

    /// #3: Settings lists clipboard session grants, also of agents no longer connected, and revokes them alone.
    @Test func sessionGrantsAreListedForSettingsAndRevokedAlone() async throws {
        let harness = try clipHarness()
        try await record(harness, text("x"), at: start)
        harness.asker.reply = .allow(.session)
        _ = await harness.call("clipboard_list")
        harness.grants.grantAlways(.capture, to: AgentHarness.agent)
        #expect(harness.grants.sessions.map(\.agent.key) == [AgentHarness.agent.key])
        #expect(harness.grants.sessions.first?.groups == [.clipboard])
        harness.grants.revokeSession(AgentHarness.agent.key)
        #expect(harness.grants.sessions.isEmpty)
        #expect(!harness.grants.hasSession(.clipboard, for: AgentHarness.agent))
        #expect(harness.grants.hasAlways(.capture, for: AgentHarness.agent))
    }

    /// #4: the row's title and domain come only from the first 200 characters.
    @Test func nothingPastThePreviewIsDerivedIntoTheRow() async throws {
        let harness = try clipHarness()
        try await record(harness, text(String(repeating: "\n", count: 300) + "SECRET-AFTER-BLANKS"), at: start)
        var files = ClipboardCapture(kind: .files, hash: "files", text: "/Users/x/" + String(repeating: "folder/", count: 40) + "SECRET-FILE-NAME.txt")
        files.byteSize = 1
        try await record(harness, files, at: start + 1)
        try await record(harness, text("https://" + String(repeating: "u", count: 250) + "@SECRET-HOST.example/page"), at: start + 2)
        let result = await harness.call("clipboard_list")
        #expect(clips(result).count == 3)
        let json = try #require(result.mcp["content"] as? [[String: Any]]).first?["text"] as? String ?? ""
        #expect(!json.contains("SECRET"))
    }

    /// #5: a program Sukusho can't name never keeps a grant for the next one that can't be named either.
    @Test func anUnresolvedProgramNeverReusesAGrant() async throws {
        for signer in ["unknown", "path:unknown"] {
            let unknown = AgentIdentity(signer: signer, signerName: "Unknown program", clientName: "unleash")
            // A fresh harness per decision, so the second can't ride on the first one's grant (Astra, round 2).
            for decision in [AgentDecision.always, .session] {
                let harness = try clipHarness(agent: unknown)
                try await record(harness, text("x"), at: start)
                harness.asker.reply = .allow(decision)
                #expect(clips(await harness.call("clipboard_list")).count == 1)
                harness.asker.reply = .deny
                #expect(agentStatus(await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: unknown))) == "denied")
                #expect(harness.grants.grants.isEmpty && harness.grants.sessions.isEmpty)
            }
            #expect(!unknown.isResolved)
        }
        #expect(AgentHarness.agent.isResolved)
    }

    /// #6: a failed call logs its status, never what the caller sent.
    @Test func aFailedClipboardCallLogsNoneOfItsArguments() async throws {
        let harness = try clipHarness()
        let log = AgentActivityLog(fileURL: nil)
        let toolbox = AgentToolbox(backend: harness.backend, asker: harness.asker, grants: harness.grants, log: log)
        toolbox.sleep = { _ in await Task.yield() }
        _ = await toolbox.handle(method: "tools/call", params: ["name": "clipboard_get", "arguments": ["id": "COPIED-TEXT-SENT-AS-ID"]],
                                 session: harness.session)
        _ = await toolbox.handle(method: "tools/call", params: ["name": "clipboard_list", "arguments": ["before": "COPIED-CURSOR"]],
                                 session: harness.session)
        #expect(log.entries.count == 2)
        #expect(log.entries.allSatisfy { !$0.result.contains("COPIED") })
    }

    /// #7: paging and ids reach the whole kept history, past the popup's 3,000 newest.
    @Test func pagingAndIdsReachHistoryPastTheFirst3000() async throws {
        let harness = try clipHarness()
        let png = Data(UUID().uuidString.utf8) + Data(repeating: 3, count: 64)
        let old = try await record(harness, ClipboardCapture(kind: .image, hash: ClipboardPasteboardReader.digest(png), image: png,
                                                             imageExtension: "png", pixelWidth: 4, pixelHeight: 4, byteSize: png.count),
                                   at: start)
        for index in 1...3_000 { try await record(harness, text("clip \(index)"), at: start + Double(index)) }
        let images = await harness.call("clipboard_list", ["kind": "images"])
        #expect(clips(images).map { $0["id"] as? String } == [old])
        #expect((await harness.call("clipboard_list")).object["total"] as? Int == 3_001)
        let get = await harness.call("clipboard_get", ["id": old])
        #expect(!get.isError)
        #expect(get.object["id"] as? String == old)
    }

    /// #8: a second ask that opens over another app gives the keyboard back to that app.
    @Test func aNewAskOverAnotherAppMovesTheFocusTarget() {
        let own: pid_t = 100
        #expect(AgentFocus.target(current: 200, front: 300, own: own) == 300)
        #expect(AgentFocus.target(current: 200, front: own, own: own) == 200)
        #expect(AgentFocus.target(current: nil, front: 300, own: own) == 300)
        #expect(AgentFocus.target(current: 200, front: nil, own: own) == 200)
    }

    @Test func aCursorWithoutAnIdIsRefused() async throws {
        let harness = try clipHarness()
        try await record(harness, text("x"), at: start)
        #expect(agentStatus(await harness.call("clipboard_list", ["before": "1700000000.0:"])) == "error")
    }

    /// Two calls at once from one agent show one ask; "For this session" then covers the second.
    @Test func overlappingCallsFromOneAgentAskOnce() async throws {
        let harness = try clipHarness()
        harness.toolbox.askTimeout = .seconds(3600)
        try await record(harness, text("x"), at: start)
        harness.asker.reply = .never
        let first = Task { await harness.call("clipboard_list") }
        let second = Task { await harness.call("clipboard_list") }
        await waitUntil { harness.asker.laterDecisions.count == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(harness.asker.asks.count == 1)
        harness.asker.laterDecisions[0](.session)
        #expect(clips(await first.value).count == 1)
        #expect(clips(await second.value).count == 1)
        #expect(harness.asker.asks.count == 1)
    }

    /// A clock the test moves; with `ticking`, each of the toolbox's polls moves it too.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func useClock(_ clock: Clock, _ harness: AgentHarness, ticking: Bool = false) {
        harness.toolbox.now = { clock.now }
        harness.toolbox.sleep = { step in
            if ticking { clock.now += Double(step.components.seconds) + Double(step.components.attoseconds) / 1e18 }
            await Task.yield()
        }
    }

    /// An answer counts from when the owner gave it: a click inside the window is a yes even when the call notices it
    /// after the deadline, and a click past it is a no (Astra, round 2).
    @Test func anAnswerCountsFromWhenItWasGiven() async throws {
        let base = Date()
        for (clickedAt, expected) in [(base + 59, "clips"), (base + 61, "denied")] {
            let harness = try clipHarness()
            try await record(harness, text("x"), at: start)
            let clock = Clock(base)
            useClock(clock, harness)
            harness.asker.reply = .never
            let list = Task { await harness.call("clipboard_list") }
            await waitUntil { harness.asker.laterDecisions.count == 1 }
            #expect(harness.asker.asks.first?.deadline == base + 60)
            clock.now = clickedAt
            harness.asker.laterDecisions[0](.once)
            clock.now = base + 62
            let result = await list.value
            #expect((expected == "clips" ? clips(result).count == 1 : agentStatus(result) == "denied"), "clicked at +\(clickedAt.timeIntervalSince(base))")
        }
    }

    /// A call that waits behind another's ask keeps the window it came in with, and a no to that ask, or no answer,
    /// is its no too. Just this once still covers only the call it was given to (Astra, round 2).
    @Test func aQueuedCallKeepsItsOwnWindowAndSharesTheOwnersNo() async throws {
        // No answer: the queued call doesn't open a fresh 60 seconds after the first times out.
        let silent = try clipHarness()
        try await record(silent, text("x"), at: start)
        useClock(Clock(Date()), silent, ticking: true)
        silent.asker.reply = .never
        let first = Task { await silent.call("clipboard_list") }
        let second = Task { await silent.call("clipboard_list") }
        #expect(agentStatus(await first.value) == "denied")
        #expect(agentStatus(await second.value) == "denied")
        #expect(silent.asker.asks.count == 1)

        // Deny: the waiting call is denied with it.
        let denied = try clipHarness()
        denied.toolbox.askTimeout = .seconds(3600)
        try await record(denied, text("x"), at: start)
        denied.asker.reply = .never
        let asked = Task { await denied.call("clipboard_list") }
        let waiting = Task { await denied.call("clipboard_list") }
        await waitUntil { denied.asker.laterDecisions.count == 1 }
        for _ in 0..<50 { await Task.yield() }
        denied.asker.laterDecisions[0](nil)
        #expect(agentStatus(await asked.value) == "denied")
        #expect(agentStatus(await waiting.value) == "denied")
        #expect(denied.asker.asks.count == 1)

        // Just this once: the waiting call asks for itself, with the time it has left.
        let once = try clipHarness()
        try await record(once, text("x"), at: start)
        let base = Date()
        let clock = Clock(base)
        useClock(clock, once)
        once.asker.reply = .never
        let a = Task { await once.call("clipboard_list") }
        let b = Task { await once.call("clipboard_list") }
        await waitUntil { once.asker.laterDecisions.count == 1 }
        for _ in 0..<50 { await Task.yield() }
        clock.now = base + 30
        once.asker.laterDecisions[0](.once)
        #expect(clips(await a.value).count == 1)
        await waitUntil { once.asker.laterDecisions.count == 2 }
        #expect(once.asker.asks.count == 2)
        #expect(once.asker.asks.last?.deadline == base + 60)
        once.asker.laterDecisions[1](.once)
        #expect(clips(await b.value).count == 1)
    }

    // MARK: Review fixes, round 2 (Astra, 2026-11-20)

    /// An unresolved launcher isn't offered Always, and an Always that comes anyway is this once: a helper-wide grant
    /// would skip Always's rule that the owner's own Library items still ask.
    @Test func anUnresolvedLaunchersAlwaysNeverCoversTheOwnersItems() async throws {
        let unknown = AgentIdentity(signer: "path:unknown", signerName: "Unknown program", clientName: "unleash")
        #expect(AgentDecision.choices(for: unknown) == [.once, .session])
        #expect(AgentDecision.choices(for: AgentHarness.agent) == AgentDecision.allCases)
        let harness = try clipHarness(agent: unknown)
        harness.addItem("a")
        harness.addItem("b")
        harness.asker.reply = .allow(.always)
        #expect(agentStatus(await harness.call("share", ["ids": ["a"]])) == "shared")
        harness.asker.reply = .never
        #expect(agentStatus(await harness.call("share", ["ids": ["b"]])) == "denied")
        #expect(harness.asker.asks.count == 2)
        #expect(harness.backend.shared.map { $0.ids } == [["a"]])
        // The clipboard too: its next call asks again.
        try await record(harness, text("x"), at: start)
        harness.asker.reply = .allow(.always)
        #expect(clips(await harness.call("clipboard_list")).count == 1)
        harness.asker.reply = .deny
        #expect(agentStatus(await harness.call("clipboard_list")) == "denied")
        #expect(harness.asker.asks.count == 4)
    }

    /// History turned off while the history is read, or while a clip's picture is made: nothing comes out.
    @Test func historyTurnedOffDuringTheReadOrThePictureReturnsNothing() async throws {
        let harness = try clipHarness()
        let png = Data(UUID().uuidString.utf8) + Data(repeating: 5, count: 64)
        let image = try await record(harness, ClipboardCapture(kind: .image, hash: ClipboardPasteboardReader.digest(png), image: png,
                                                               imageExtension: "png", pixelWidth: 4, pixelHeight: 4, byteSize: png.count),
                                     at: start)
        try await record(harness, text("read-while-turned-off"), at: start + 1)
        let store = harness.backend.clipStore
        harness.backend.onClipRead = { harness.backend.clipStore = nil }
        let listed = await harness.call("clipboard_list")
        #expect(agentStatus(listed) == "error")
        #expect(!String(describing: listed.object).contains("read-while-turned-off"))

        harness.backend.onClipRead = nil
        harness.backend.clipStore = store
        harness.backend.onJPEG = { harness.backend.clipStore = nil }
        let picture = await harness.call("clipboard_get", ["id": image, "image": true])
        #expect(agentStatus(picture) == "error")
        #expect(picture.image == nil)

        // The helper going away while the picture is made: denied, no picture.
        harness.backend.clipStore = store
        harness.backend.onJPEG = { harness.toolbox.end(harness.session) }
        let closed = await harness.call("clipboard_get", ["id": image, "image": true])
        #expect(agentStatus(closed) == "denied")
        #expect(closed.image == nil)

        // Off and on again while reading: a new store, not the history this call was allowed to read (Astra, round 3).
        harness.backend.onJPEG = nil
        harness.backend.clipStore = store
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("AgentClipboardTests-\(UUID().uuidString)")
        harness.backend.onClipRead = { harness.backend.clipStore = try? ClipboardHistoryStore(directory: fresh, deviceID: "test-mac") }
        let reopened = await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: AgentHarness.agent))
        #expect(agentStatus(reopened) == "error")
        #expect(!String(describing: reopened.object).contains("read-while-turned-off"))
    }

    /// A helper that has gone away asks nothing, and a standing grant doesn't carry it either (Astra, round 3).
    @Test func aClosedHelperNeverOpensAWindow() async throws {
        let harness = try clipHarness()
        try await record(harness, text("x"), at: start)
        harness.toolbox.end(harness.session)
        harness.asker.reply = .allow(.once)
        #expect(agentStatus(await harness.call("clipboard_list")) == "denied")
        #expect(harness.asker.asks.isEmpty)
        harness.grants.grantAlways(.clipboard, to: AgentHarness.agent)
        #expect(agentStatus(await harness.call("clipboard_list")) == "denied")
        #expect(harness.asker.asks.isEmpty)
    }

    /// The owner's no holds for the calls waiting on it even when the asking helper goes before it reads the answer.
    @Test func aDenialHoldsForWaitingCallsWhenItsHelperCloses() async throws {
        let harness = try clipHarness()
        harness.toolbox.askTimeout = .seconds(3600)
        try await record(harness, text("x"), at: start)
        harness.asker.reply = .never
        let other = AgentSession(agent: AgentHarness.agent)
        let first = Task { await harness.call("clipboard_list") }
        let second = Task { await harness.toolbox.call("clipboard_list", [:], session: other) }
        await waitUntil { harness.asker.laterDecisions.count == 1 }
        for _ in 0..<50 { await Task.yield() }
        harness.asker.laterDecisions[0](nil)
        harness.toolbox.end(harness.session)
        #expect(agentStatus(await first.value) == "denied")
        #expect(agentStatus(await second.value) == "denied")
        #expect(harness.asker.asks.count == 1)
    }

    /// Helpers of programs Sukusho can't name keep their grants to themselves, so they don't wait on, or share a no
    /// with, each other's asks either (Astra, round 3).
    @Test func unresolvedHelpersAskForThemselves() async throws {
        let unknown = AgentIdentity(signer: "unknown", signerName: "Unknown program", clientName: "unleash")
        let harness = try clipHarness(agent: unknown)
        harness.toolbox.askTimeout = .seconds(3600)
        try await record(harness, text("x"), at: start)
        harness.asker.reply = .never
        let first = Task { await harness.call("clipboard_list") }
        let second = Task { await harness.toolbox.call("clipboard_list", [:], session: AgentSession(agent: unknown)) }
        await waitUntil { harness.asker.laterDecisions.count == 2 }
        #expect(harness.asker.asks.count == 2)
        harness.asker.laterDecisions[0](nil)
        if harness.asker.laterDecisions.count == 2 { harness.asker.laterDecisions[1](.once) }
        #expect(agentStatus(await first.value) == "denied")
        #expect(clips(await second.value).count == 1)
    }

    /// A restore whose helper goes away, whose grant is revoked, or whose history is turned off after the ask and
    /// before its write (while the clip's formats are read) writes nothing.
    @Test func aRestoreWritesNothingOnceAccessEndsBeforeTheWrite() async throws {
        enum End: CaseIterable { case helper, revoke, revokeAndGrantAgain, historyOff, historyReopened }
        for end in End.allCases {
            let harness = try clipHarness()
            defer { harness.backend.clipPasteboard.releaseGlobally() }
            let id = try await record(harness, text("restore-\(end)"), at: start)
            harness.asker.reply = .allow(.session)
            #expect(clips(await harness.call("clipboard_list")).count == 1)
            harness.backend.beforeClipWrite = {
                switch end {
                case .helper: harness.toolbox.end(harness.session)
                case .revoke: harness.grants.revoke(AgentHarness.agent.key)
                // A grant given again isn't the one this call was let through on (Astra, round 3).
                case .revokeAndGrantAgain:
                    harness.grants.revoke(AgentHarness.agent.key)
                    harness.grants.grantSession(.clipboard, to: AgentHarness.agent)
                case .historyOff: harness.backend.clipStore = nil
                case .historyReopened:
                    harness.backend.clipStore = try? ClipboardHistoryStore(
                        directory: FileManager.default.temporaryDirectory.appendingPathComponent("AgentClipboardTests-\(UUID().uuidString)"),
                        deviceID: "test-mac")
                }
            }
            let result = await harness.call("clipboard_restore", ["id": id])
            #expect(agentStatus(result) == ([.historyOff, .historyReopened].contains(end) ? "error" : "denied"), "\(end)")
            #expect(harness.backend.clipPasteboard.pasteboardItems?.isEmpty ?? true, "\(end)")
        }
        // The writer itself: told not to, it leaves the pasteboard and the history alone.
        let harness = try clipHarness()
        defer { harness.backend.clipPasteboard.releaseGlobally() }
        let id = try await record(harness, text("never-written"), at: start)
        let entry = try #require(try await harness.backend.clipStore?.agentEntries().first { $0.id == id })
        let wrote = await ClipboardWriter.restore(entry, plain: false, store: harness.backend.clipStore,
                                                  historyDirectory: harness.backend.clipHistoryDirectory,
                                                  to: harness.backend.clipPasteboard, shouldWrite: { false })
        #expect(!wrote)
        #expect(harness.backend.clipPasteboard.pasteboardItems?.isEmpty ?? true)
        #expect(try await harness.backend.clipStore?.agentEntries().first { $0.id == id }?.timesCopied == 1)
    }

    /// Settings' "Connected now" counts Always grants, not only this session's (Astra #3, round 2).
    @Test func connectedNowCountsAlwaysGrants() {
        let defaults = UserDefaults(suiteName: "AgentClipboardTests-\(UUID().uuidString)")!
        let grants = AgentGrantStore(defaults: defaults)
        let agent = AgentHarness.agent
        #expect(grants.connectedDetail(agent: agent, helperGrants: []) == "Asks for everything")
        grants.grantAlways(.clipboard, to: agent)
        #expect(grants.connectedDetail(agent: agent, helperGrants: []) == "Always allowed: Read my clipboard history")
        grants.grantSession(.clipboard, to: agent)
        #expect(grants.connectedDetail(agent: agent, helperGrants: [.capture])
            == "Allowed for this session: Capture the screen, Read my clipboard history")
        // A program Sukusho can't name gets nothing kept, so the row says only what its helper has.
        let unknown = AgentIdentity(signer: "unknown", signerName: "Unknown program", clientName: agent.clientName)
        grants.grantAlways(.publish, to: unknown)
        #expect(grants.connectedDetail(agent: unknown, helperGrants: []) == "Asks for everything")
    }

    /// A colour, a content type or a domain is worked out from the first 200 characters only (Astra #4, round 2).
    @Test func noColorTypeOrDomainComesFromPastThePreview() async throws {
        let harness = try clipHarness()
        let colour = try await record(harness, text(String(repeating: " ", count: 300) + "#ABCDEF"), at: start)
        let deep = try await record(harness, text(String(repeating: " ", count: AgentClips.textLength + 5) + "#FEDCBA"), at: start + 1)
        try await record(harness, text("https://user-SECRET.example" + String(repeating: "x", count: 200) + "@SECRET.example/page"),
                         at: start + 2)
        let result = await harness.call("clipboard_list")
        let json = try #require(result.mcp["content"] as? [[String: Any]]).first?["text"] as? String ?? ""
        #expect(!json.contains("ABCDEF") && !json.contains("FEDCBA"))
        #expect(!json.contains("\"color\"") && !json.contains("\"domain\"") && !json.contains("Color"))
        let detail = await harness.call("clipboard_get", ["id": deep])
        #expect(detail.object["color"] == nil && detail.object["kind"] as? String == "text")
        #expect(!String(describing: detail.object).contains("FEDCBA"))
        #expect((await harness.call("clipboard_get", ["id": colour])).object["id"] as? String == colour)
        // The type menu sorts by the same slice: the hidden colour is Text, not Colors (Astra, round 3).
        #expect(!clips(await harness.call("clipboard_list", ["kind": "colors"])).contains { $0["id"] as? String == colour })
        #expect(clips(await harness.call("clipboard_list", ["kind": "text"])).contains { $0["id"] as? String == colour })
        // A colour in the slice with more after it still says the text goes on.
        let more = try await record(harness, text("#123456" + String(repeating: " ", count: 193) + "and more words"), at: start + 5)
        let shownColour = try #require(clips(await harness.call("clipboard_list")).first { $0["id"] as? String == more })
        #expect(untrusted(shownColour)["preview"] as? String == "#123456")
        #expect(untrusted(shownColour)["preview_truncated"] as? Bool == true)
        // A link within the preview keeps its domain.
        let linkID = try await record(harness, text("https://example.com/page"), at: start + 3)
        let link = try #require(clips(await harness.call("clipboard_list")).first { $0["id"] as? String == linkID })
        #expect(untrusted(link)["domain"] as? String == "example.com")
        // Counts aren't content: a long file list still says how many files it holds.
        var files = ClipboardCapture(kind: .files, hash: "many-files", text: (1...30).map { "/Users/x/Documents/file-\($0).txt" }.joined(separator: "\n"))
        files.byteSize = 1
        let many = try await record(harness, files, at: start + 4)
        let listedFiles = try #require(clips(await harness.call("clipboard_list")).first { $0["id"] as? String == many })
        #expect(listedFiles["content_type"] as? String == "30 files")
        #expect(listedFiles["file_count"] as? Int == 30)
    }

    @Test func catalogListsTheClipboardTools() {
        let tools = Dictionary(uniqueKeysWithValues: AgentToolCatalog.tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool) }
        })
        for name in ["clipboard_list", "clipboard_get", "clipboard_restore"] {
            let tool = tools[name]
            #expect(tool != nil)
            #expect((tool?["inputSchema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
        }
    }
}
