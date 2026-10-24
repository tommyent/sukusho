import CoreGraphics
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

    @Test func oneSpaceAfterTheColonIsFine() {
        #expect(CaptureLibraryQuery.parse("app: chrome").operators == ["app": ["chrome"]])
        #expect(CaptureLibraryQuery.parse("app: chrome").phrases.isEmpty)
        let quoted = CaptureLibraryQuery.parse(#"bug app: "visual studio""#)
        #expect(quoted.phrases == ["bug"] && quoted.operators == ["app": ["visual studio"]])
        #expect(CaptureLibraryQuery("app: chrome").matches(fields: ["Chrome tips"], foldedText: nil, source: nil) == false)
        // Still half-typed: no value yet, so nothing narrows.
        #expect(CaptureLibraryQuery("report app: ").isEmpty == false)
        #expect(CaptureLibraryQuery.parse("report app: ").operators.isEmpty)
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

    // MARK: Which window a capture shows

    @Test func anAreaIsTheWindowUnderItNotTheFrontmostApp() {
        // Front to back: Chrome (frontmost) on the left half, Terminal on the right, Notes behind both.
        let chromeWindow = CaptureSourceProbe.Window(pid: 1, ownerName: "Google Chrome", title: "Docs", bounds: CGRect(x: 0, y: 25, width: 800, height: 875))
        let terminal = CaptureSourceProbe.Window(pid: 2, ownerName: "Terminal", title: "zsh", bounds: CGRect(x: 800, y: 25, width: 800, height: 875))
        let notes = CaptureSourceProbe.Window(pid: 3, ownerName: "Notes", title: nil, bounds: CGRect(x: 100, y: 100, width: 1200, height: 600))
        let windows = [chromeWindow, terminal, notes]
        func covering(_ covered: CaptureSourceProbe.Covered, frontmost: pid_t? = 1) -> String? {
            CaptureSourceProbe.window(covering: covered, in: windows, frontmostPID: frontmost)?.ownerName
        }
        // The review's case: an area of Terminal while Chrome is frontmost.
        #expect(covering(.area(CGRect(x: 900, y: 200, width: 400, height: 300))) == "Terminal")
        // Its middle decides when it spans both; else the window it overlaps most.
        #expect(covering(.area(CGRect(x: 600, y: 200, width: 300, height: 300))) == "Google Chrome")
        // Middle over the menu bar strip, above every window: Terminal's share is larger.
        #expect(covering(.area(CGRect(x: 600, y: 0, width: 500, height: 30))) == "Terminal")
        #expect(covering(.area(CGRect(x: 2000, y: 0, width: 100, height: 100))) == nil)
        // A whole display is the frontmost app's, else the top window on it.
        #expect(covering(.display(CGRect(x: 0, y: 0, width: 1600, height: 900))) == "Google Chrome")
        #expect(covering(.display(CGRect(x: 0, y: 0, width: 1600, height: 900)), frontmost: 3) == "Notes")
        #expect(covering(.display(CGRect(x: 0, y: 0, width: 1600, height: 900)), frontmost: nil) == "Google Chrome")
        #expect(covering(.display(CGRect(x: 1700, y: 0, width: 1920, height: 1080))) == nil)
        // A point is the top window under it.
        #expect(covering(.point(CGPoint(x: 1000, y: 400))) == "Terminal")
    }

    @Test func anAreaDrawnPastAWindowsEdgeIsStillThatWindow() {
        // The 2026-10-24 4:58 capture: Vitals frontmost over a full-screen Rex,
        // and an area whose right edge ran 2 pt past Vitals onto Rex.
        let vitals = CaptureSourceProbe.Window(pid: 1, ownerName: "Vitals", title: "Vitals", bounds: CGRect(x: 57, y: 34, width: 1399, height: 1023))
        let rex = CaptureSourceProbe.Window(pid: 2, ownerName: "Rex Beta", title: "sukusho-lead", bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073))
        let area = CGRect(x: 16, y: 0, width: 1442, height: 912)
        #expect(CaptureSourceProbe.window(covering: .area(area), in: [vitals, rex], frontmostPID: 1)?.ownerName == "Vitals")
        // The drag's end corner, which the pointer track fell back to, is on Rex.
        #expect(CaptureSourceProbe.window(covering: .point(CGPoint(x: area.maxX, y: area.maxY)), in: [vitals, rex], frontmostPID: 1)?.ownerName == "Rex Beta")
    }

    @Test func thisAppsWindowsAreNamedForWhatTheyShow() {
        func name(_ identifier: String?, autosave: String = "") -> String? {
            CaptureSourceProbe.ownWindowName(identifier: identifier, autosaveName: autosave)
        }
        #expect(name("CAPTURE_LIBRARY") == "Library")
        #expect(name("CAPTURE_LIBRARY-AppWindow-1") == "Library")
        #expect(name("ANNOTATION_EDITOR-AppWindow-3") == "Editor")
        #expect(name("VIDEO_EDITOR-AppWindow-1") == "Studio")
        #expect(name(nil, autosave: "SettingsWindow") == "Settings")
        // Any other window keeps its title.
        #expect(name("CAPTURE_LIBRARY_OLD") == nil)
        #expect(name("com_apple_SwiftUI_Settings_window") == nil)
        #expect(name(nil) == nil)
    }

    @Test func screencaptureRecordsTheAreaOnItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-rect-\(UUID().uuidString).png")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureSourceProbe.capturedRect(of: url) == nil)

        func setRect(_ value: Any) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            let result = data.withUnsafeBytes {
                setxattr(url.path, "com.apple.metadata:kMDItemScreenCaptureGlobalRect", $0.baseAddress, data.count, 0, 0)
            }
            try #require(result == 0)
        }
        // As screencapture writes it: x, y, width, height in global points.
        try setRect([16, 0, 1442, 912])
        #expect(CaptureSourceProbe.capturedRect(of: url) == CGRect(x: 16, y: 0, width: 1442, height: 912))
        try setRect([0.5, 3, 1710, 573.5])
        #expect(CaptureSourceProbe.capturedRect(of: url) == CGRect(x: 0.5, y: 3, width: 1710, height: 573.5))
        // Anything else falls back to the pointer track.
        try setRect([16, 0, 1442])
        #expect(CaptureSourceProbe.capturedRect(of: url) == nil)
        try setRect([16, 0, 0, 912])
        #expect(CaptureSourceProbe.capturedRect(of: url) == nil)
        try setRect("selection")
        #expect(CaptureSourceProbe.capturedRect(of: url) == nil)
        #expect(CaptureSourceProbe.capturedRect(of: url.appendingPathExtension("missing")) == nil)
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
