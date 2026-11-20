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
