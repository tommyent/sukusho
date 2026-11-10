@preconcurrency import CoreSpotlight
import Foundation
import FoundationModels

/// Library search in plain words ("the invoice from last week"): Apple's
/// on-device model reads the request and searches the app's own Spotlight
/// index (`CaptureSpotlightIndexer`) through Core Spotlight's search tool.
/// Both run on this Mac. Where the model isn't available nothing calls this,
/// and search stays as it is.
nonisolated enum CapturePlainSearch {
    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    struct Answer: Sendable, Equatable {
        /// The captures found, best first, each once.
        var ids: [String]
        /// What the model said about them; for checks, not shown.
        var reply: String
    }

    /// The attributes the model gets back for each capture it finds.
    static let fetchAttributes: [SearchableItemAttribute] = [.title, .kind, .keywords, .creator, .contentCreationDate, .contentDescription]

    static func search(_ query: String, now: Date = .now, limit: Int = 20) async throws -> Answer {
        var source = CoreSpotlightSource(fetchAttributes: fetchAttributes)
        source.maximumResultCount = limit
        // The default guide's schema alone overflows the on-device model's
        // context (macOS 27 release notes, 183770678); the focused one fits.
        let tool = SpotlightSearchTool(configuration: .init(sources: [.coreSpotlight(source)], guide: .focused(.items(.init(
            title: [.title, .alternateNames], text: [.textContent, .keywords, .creator, .kind],
            created: [.contentCreationDate], modified: [.contentModificationDate])))))
        let found = Task {
            var ids: [String] = []
            for await reply in tool.searchResults { ids += Self.ids(in: reply.content) }
            return ids
        }
        defer { found.cancel() }
        let session = LanguageModelSession(tools: [tool], instructions: instructions(now: now))
        let reply = try await session.respond(to: query, options: GenerationOptions(temperature: 0)).content
        // shortcut: counts on the tool having sent its replies by the time the model answers (seen in every
        // run of the check), since the stream never ends by itself; wait for each call's `.complete` reply if results go missing.
        await Task.yield()
        found.cancel()
        return Answer(ids: unique(await found.value, limit: limit), reply: reply)
    }

    static func instructions(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        return """
        You find captures in the user's library of screenshots and screen recordings. Each has a title, the text \
        read from the screen, tags, the app it was taken in, a kind ("Screenshot" or "Recording") and the date it was taken.
        Search with the search tool, using one to three distinctive words of the request, in the singular: names, \
        products, topics. Leave out filler ("the", "my", "screenshot of") and every word about time.
        A request that names no time gets no date limit. Only when it names one ("yesterday", "last week", \
        "in March") limit the search to those dates; today is \(now.formatted(style)).
        For recordings or videos search the word Recording, for screenshots the word Screenshot.
        If a search finds nothing, search once more with fewer words and no date limit. Then answer in one short sentence.
        """
    }

    static func ids(in content: SpotlightSearchTool.SearchReply.Content) -> [String] {
        switch content {
        case .items(let items): items.map(\.item.uniqueIdentifier)
        case .scoredItems(let scored): scored.sorted { $0.score > $1.score }.map(\.item.item.uniqueIdentifier)
        case .groupedItems(let groups): groups.values.flatMap { $0 }.map(\.item.uniqueIdentifier)
        case .count, .table, .statistic, .text: []
        @unknown default: []
        }
    }

    /// Each capture once, in the order first found: the model may search again.
    static func unique(_ ids: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(ids.filter { seen.insert($0).inserted }.prefix(limit))
    }
}
