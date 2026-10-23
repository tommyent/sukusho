import Foundation
import Testing

struct CaptureSourceSearchTests {
    private let chrome = CaptureSource(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome",
                                       windowTitle: "Invoice 1042 – Stripe")
    private let code = CaptureSource(bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code", windowTitle: nil)
    private let slack = CaptureSource(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: nil)

    // MARK: Parsing

    @Test func operatorsSplitFromWords() {
        #expect(CaptureLibraryQuery.parse("app:chrome").phrases.isEmpty)
        #expect(CaptureLibraryQuery.parse("app:chrome").operators == ["app": ["chrome"]])
        let mixed = CaptureLibraryQuery.parse("login bug app:safari  stack trace")
        #expect(mixed.phrases == ["login bug", "stack trace"])
        #expect(mixed.operators == ["app": ["safari"]])
        // Operator names ignore case; several values all apply.
        #expect(CaptureLibraryQuery.parse("App:Chrome app:google").operators == ["app": ["Chrome", "google"]])
    }

    @Test func quotedValuesKeepTheirSpaces() {
        let parsed = CaptureLibraryQuery.parse(#"app:"visual studio" error"#)
        #expect(parsed.operators == ["app": ["visual studio"]])
        #expect(parsed.phrases == ["error"])
        // An unclosed quote runs to the end, as it does while typing.
        #expect(CaptureLibraryQuery.parse(#"app:"visual stu"#).operators == ["app": ["visual stu"]])
    }

    @Test func unknownOperatorsAndColonsStayWords() {
        #expect(CaptureLibraryQuery.parse("tag:work").phrases == ["tag:work"])
        #expect(CaptureLibraryQuery.parse("https://example.com/app:chrome").phrases == ["https://example.com/app:chrome"])
        #expect(CaptureLibraryQuery.parse("12:30 meeting").phrases == ["12:30 meeting"])
        #expect(CaptureLibraryQuery.parse("snapp:chrome").phrases == ["snapp:chrome"])
        // Half-typed operators narrow nothing yet.
        let empty = CaptureLibraryQuery.parse("report app:")
        #expect(empty.phrases == ["report"] && empty.operators.isEmpty)
        #expect(CaptureLibraryQuery("app:").isEmpty)
        // Without operators the query is the text as typed, trimmed.
        #expect(CaptureLibraryQuery.parse("  two  spaces ").phrases == ["two  spaces"])
    }

    // MARK: Filtering

    @Test func appMatchesNameOrBundleLastPart() {
        #expect(CaptureLibraryQuery("app:chrome").matches(fields: [], foldedText: nil, source: chrome))
        #expect(CaptureLibraryQuery("app:CHROME").matches(fields: [], foldedText: nil, source: chrome))
        #expect(!CaptureLibraryQuery("app:safari").matches(fields: [], foldedText: nil, source: chrome))
        #expect(CaptureLibraryQuery(#"app:"visual studio""#).matches(fields: [], foldedText: nil, source: code))
        #expect(CaptureLibraryQuery("app:vscode").matches(fields: [], foldedText: nil, source: code))
        #expect(CaptureLibraryQuery("app:slackmac").matches(fields: [], foldedText: nil, source: slack))
        // Only the bundle ID's last part counts, not its vendor.
        #expect(!CaptureLibraryQuery("app:tinyspeck").matches(fields: [], foldedText: nil, source: slack))
        // Captures with no known source never match an app.
        #expect(!CaptureLibraryQuery("app:chrome").matches(fields: ["Google Chrome screenshot"], foldedText: nil, source: nil))
    }

    @Test func appCombinesWithWordsAndOtherApps() {
        let text = CaptureLibraryQuery.fold("Payment received")
        #expect(CaptureLibraryQuery("app:chrome payment").matches(fields: [], foldedText: text, source: chrome))
        #expect(!CaptureLibraryQuery("app:chrome refund").matches(fields: [], foldedText: text, source: chrome))
        #expect(!CaptureLibraryQuery("app:slack payment").matches(fields: [], foldedText: text, source: chrome))
        #expect(CaptureLibraryQuery("app:google app:chrome").matches(fields: [], foldedText: nil, source: chrome))
        #expect(!CaptureLibraryQuery("app:chrome app:safari").matches(fields: [], foldedText: nil, source: chrome))
        // Plain words match the app name and window title, which the Library passes as fields.
        let fields = ["Oct 23", chrome.appName, chrome.windowTitle!]
        #expect(CaptureLibraryQuery("stripe").matches(fields: fields, foldedText: nil, source: chrome))
        #expect(CaptureLibraryQuery("google chrome").matches(fields: fields, foldedText: nil, source: chrome))
    }

    @Test func matchingParagraphsComeFirstForEveryPhrase() {
        let query = CaptureLibraryQuery("refund app:chrome total")
        #expect(query.ordered(["Header", "Total due", "Refund issued"]) == ["Total due", "Refund issued", "Header"])
        #expect(CaptureLibraryQuery("app:chrome").ordered(["b", "a"]) == ["b", "a"])
    }

    // MARK: Stored data

    @Test func projectsWithoutASourceStillDecode() throws {
        let old = Data(#"{"version":1,"displayName":"Demo","tags":["client"]}"#.utf8)
        let decoded = try JSONDecoder().decode(RecordingProjectMetadata.self, from: old)
        #expect(decoded.displayName == "Demo" && decoded.tags == ["client"] && decoded.source == nil)

        var metadata = RecordingProjectMetadata(displayName: "Demo")
        metadata.source = code
        let roundTrip = try JSONDecoder().decode(RecordingProjectMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(roundTrip.source == code)
        // A source without a window title or bundle ID decodes too.
        let bare = Data(#"{"source":{"appName":"Preview"}}"#.utf8)
        #expect(try JSONDecoder().decode(RecordingProjectMetadata.self, from: bare).source
            == CaptureSource(bundleIdentifier: nil, appName: "Preview", windowTitle: nil))
    }
}
