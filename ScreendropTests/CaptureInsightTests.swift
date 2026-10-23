import Foundation
import Testing

struct CaptureInsightTests {
    private let insight = CaptureInsight(title: "Stripe payout settings", keywords: ["stripe", "payouts", "Bank Account"],
                                         category: "Settings")

    // MARK: Titles

    @Test func theUsersNameBeatsTheModelsTitleWhichBeatsTheDate() {
        let date = "Oct 23, 9:41 AM"
        #expect(CaptureInsightRules.title(customName: "Q3 payouts", modelTitle: "Stripe payout settings", dateTitle: date) == "Q3 payouts")
        #expect(CaptureInsightRules.title(customName: nil, modelTitle: "Stripe payout settings", dateTitle: date) == "Stripe payout settings")
        // Clearing a rename brings back the model's title, else the date.
        #expect(CaptureInsightRules.title(customName: nil, modelTitle: nil, dateTitle: date) == date)
    }

    @Test func modelTitlesAreTwoToSixPlainWords() {
        #expect(CaptureInsightRules.cleanTitle("  \"Swift build error in Xcode.\" ") == "Swift build error in Xcode")
        #expect(CaptureInsightRules.cleanTitle("Invoice  1042 (Stripe)") == "Invoice 1042 (Stripe)")
        #expect(CaptureInsightRules.cleanTitle("release planning") == "Release planning")
        #expect(CaptureInsightRules.cleanTitle("iPhone setup") == "iPhone setup")
        #expect(CaptureInsightRules.cleanTitle("Invoice") == nil)
        #expect(CaptureInsightRules.cleanTitle("A very long title that goes on and on") == nil)
        #expect(CaptureInsightRules.cleanTitle("") == nil)
    }

    @Test func lowercasedNamesTakeTheCapturesSpelling() {
        let lines = ["From: TAP Air Portugal", "Subject: Your flight itinerary to Lisbon", "Payouts – Stripe Dashboard",
                     "Payout schedule: Automatic", "error: cannot find 'x' in scope"]
        #expect(CaptureInsightRules.spelling(of: "tap air portugal", in: lines) == "TAP Air Portugal")
        #expect(CaptureInsightRules.spelling(of: "lisbon", in: lines) == "Lisbon")
        #expect(CaptureInsightRules.spelling(of: "stripe", in: lines) == "Stripe")
        // Capitalized only where a line starts, or not at all: the model's case stands.
        #expect(CaptureInsightRules.spelling(of: "payouts", in: lines) == "payouts")
        #expect(CaptureInsightRules.spelling(of: "schedule", in: lines) == "schedule")
        #expect(CaptureInsightRules.spelling(of: "error", in: lines) == "error")
        // Whole words only: "ai" isn't the start of "Air".
        #expect(CaptureInsightRules.spelling(of: "ai", in: lines) == "ai")
        // A spelling the model chose itself is kept.
        #expect(CaptureInsightRules.spelling(of: "Lisboa", in: lines) == "Lisboa")
        #expect(CaptureInsightRules.spelling(of: "boston", in: []) == "boston")
    }

    // MARK: Suggestions

    @Test func suggestionsSkipTagsTheCaptureHasAndUseTheLibrarysSpelling() {
        let suggested = CaptureInsightRules.suggestions(
            appName: "Google Chrome", insight: insight, tags: ["Payouts"], libraryTags: ["Payouts", "STRIPE", "settings"], dismissed: [])
        // "payouts" is on the capture already as "Payouts"; "stripe" and "Settings" take the Library's spelling.
        #expect(suggested == ["Google Chrome", "settings", "STRIPE", "Bank Account"])
    }

    @Test func dismissedSuggestionsStayGone() {
        let dismissed = ["google chrome", "stripe"].map(CaptureInsightRules.fold)
        let suggested = CaptureInsightRules.suggestions(appName: "Google Chrome", insight: insight, tags: [], libraryTags: [],
                                                        dismissed: dismissed)
        #expect(suggested == ["Settings", "payouts", "Bank Account"])
        #expect(CaptureInsightRules.fold("  Stripe ") == "stripe")
    }

    @Test func theAppNameNeedsNoModel() {
        #expect(CaptureInsightRules.suggestions(appName: "Xcode", insight: nil, tags: [], libraryTags: [], dismissed: []) == ["Xcode"])
        #expect(CaptureInsightRules.suggestions(appName: "Xcode", insight: nil, tags: ["xcode"], libraryTags: [], dismissed: []).isEmpty)
        #expect(CaptureInsightRules.suggestions(appName: nil, insight: nil, tags: [], libraryTags: [], dismissed: []).isEmpty)
    }

    @Test func suggestionsOfferEachTagOnceAndAtMostFiveKeywords() {
        let many = CaptureInsight(title: nil, keywords: ["xcode", "swift", "build", "error", "linker", "ld", "arm64"], category: "Error")
        let suggested = CaptureInsightRules.suggestions(appName: "Xcode", insight: many, tags: [], libraryTags: [], dismissed: [])
        // The app and the category first; "xcode" and "error" repeat them; only the first five keywords count.
        #expect(suggested == ["Xcode", "Error", "swift", "build", "linker"])
    }

    // MARK: Availability gate

    @Test func storedOutputOutlivesTheModelButNotTheSwitch() {
        let entry = CaptureTextEntry(id: "a", fingerprint: "a:1", paragraphs: ["Payouts"], insight: insight)
        // A fake provider says the model is gone (removed to free disk space):
        // nothing new runs, and what was stored still shows while the switch is on.
        #expect(!CaptureInsightRules.runs(modelAvailable: false, enabled: true, readsText: true))
        #expect(CaptureInsightRules.visible(entry.insight, enabled: true) == insight)
        #expect(CaptureInsightRules.suggestions(appName: "Safari", insight: insight, tags: [], libraryTags: [], dismissed: [])
                == ["Safari", "Settings", "stripe", "payouts", "Bank Account"])
        // The switch off hides it, model or not, and keeps it.
        #expect(CaptureInsightRules.visible(entry.insight, enabled: false) == nil)
        #expect(CaptureInsightRules.suggestions(appName: "Safari", insight: nil, tags: [], libraryTags: [], dismissed: []) == ["Safari"])
        #expect(entry.insight == insight)
        // It runs only with the model there, the switch on and text being read.
        #expect(CaptureInsightRules.runs(modelAvailable: true, enabled: true, readsText: true))
        #expect(!CaptureInsightRules.runs(modelAvailable: true, enabled: false, readsText: true))
        #expect(!CaptureInsightRules.runs(modelAvailable: true, enabled: true, readsText: false))
        // A refusal never shows.
        #expect(CaptureInsightRules.visible(CaptureInsight(declined: true), enabled: true) == nil)
    }

    // MARK: Storage

    @Test func entriesWrittenBeforeInsightsStillDecode() throws {
        let old = #"{"id":"a","version":1,"fingerprint":"/History/a.png:100.0","paragraphs":["Hello"]}"#
        let entry = try JSONDecoder().decode(CaptureTextEntry.self, from: Data(old.utf8))
        #expect(entry.paragraphs == ["Hello"] && entry.insight == nil && entry.dismissedSuggestions == nil)
        #expect(entry.isCurrent(fingerprint: "/History/a.png:100.0"))
        var current = entry
        current.insight = insight
        current.dismissedSuggestions = ["safari"]
        #expect(try JSONDecoder().decode(CaptureTextEntry.self, from: JSONEncoder().encode(current)) == current)
    }

    // MARK: Planning

    @Test func newCapturesAreDueNewestFirstAndOlderOnesWaitForTheUser() {
        let since = Date()
        let captures: [CaptureTextIndexPlan.Capture] = [
            .init(id: "older", fingerprint: "older:1", createdAt: since.addingTimeInterval(-100)),
            .init(id: "new", fingerprint: "new:1", createdAt: since.addingTimeInterval(10)),
            .init(id: "newer", fingerprint: "newer:1", createdAt: since.addingTimeInterval(20)),
            .init(id: "unread", fingerprint: "unread:1", createdAt: since.addingTimeInterval(30)),
            .init(id: "edited", fingerprint: "edited:2", createdAt: since.addingTimeInterval(40)),
            .init(id: "titled", fingerprint: "titled:1", createdAt: since.addingTimeInterval(50)),
            .init(id: "declined", fingerprint: "declined:1", createdAt: since.addingTimeInterval(60)),
            .init(id: "busy", fingerprint: "busy:1", createdAt: since.addingTimeInterval(70)),
        ]
        var entries = Dictionary(uniqueKeysWithValues: ["older", "new", "newer", "busy"].map {
            ($0, CaptureTextEntry(id: $0, fingerprint: "\($0):1", paragraphs: []))
        })
        entries["edited"] = CaptureTextEntry(id: "edited", fingerprint: "edited:1", paragraphs: [])
        entries["titled"] = CaptureTextEntry(id: "titled", fingerprint: "titled:1", paragraphs: [], insight: insight)
        entries["declined"] = CaptureTextEntry(id: "declined", fingerprint: "declined:1", paragraphs: [], insight: CaptureInsight(declined: true))
        // Text not read yet, or read before an edit, waits for the read; a refusal isn't asked again.
        let plan = CaptureTextIndexPlan.dueForInsight(captures, entries: entries, since: since, includesExisting: false, skipping: ["busy:1"])
        #expect(plan.due.map(\.id) == ["newer", "new"])
        #expect(plan.older == 1)
        let all = CaptureTextIndexPlan.dueForInsight(captures, entries: entries, since: since, includesExisting: true)
        #expect(all.due.map(\.id) == ["busy", "newer", "new", "older"] && all.older == 0)
        // An older prompt version is asked again.
        var stale = insight
        stale.version = CaptureInsight.currentVersion - 1
        entries["titled"]?.insight = stale
        #expect(CaptureTextIndexPlan.dueForInsight(captures, entries: entries, since: since, includesExisting: false,
                                                   skipping: ["busy:1"]).due.first?.id == "titled")
    }
}
