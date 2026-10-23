import AppKit
import AVFoundation
import CoreText
import Foundation
import FoundationModels

// Run with check-editor-idle-save.py against the actual app sources and an isolated home.
// It asks Apple's on-device model for real, so run it on a Mac where
// SystemLanguageModel is available (this Air), not the VMPal VM.
@main
struct LibraryInsightChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func require<T>(_ value: T?, _ message: String = "Missing value") throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }

    static func waitUntil(_ what: String, timeout: Duration = .seconds(180), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func draw(_ lines: [String], in context: CGContext, width: Int, height: Int) {
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (row, text) in lines.enumerated() {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, row == 0 ? 48 : 34, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 80, y: CGFloat(height) - 120 - CGFloat(row) * 60)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
    }

    static func writePNG(_ lines: [String], to url: URL) throws {
        let context = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(lines, in: context, width: 1600, height: 900)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "PNG fixture failed")
    }

    /// Six seconds of 1280×720 with the same lines throughout.
    static func movie(_ lines: [String], at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB),
                                                         size: .init(width: 1280, height: 720))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            var pixels = try CVMutablePixelBuffer(attributes)
            try pixels.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first,
                      let context = CGContext(data: plane.bytes.baseAddress, width: 1280, height: 720,
                        bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                else { throw Failure(description: "Cannot create fixture pixels") }
                draw(lines, in: context, width: 1280, height: 720)
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 10))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1))
        await writer.finishWriting()
        try check(writer.status == .completed, "Movie fixture failed: \(String(describing: writer.error))")
    }

    static func item(_ id: String) throws -> CaptureLibraryItem {
        try require(CaptureLibraryModel.shared.items.first { $0.id == id }, "No Library item \(id)")
    }

    /// The isolated home doesn't isolate UserDefaults: cfprefsd keeps this
    /// tool's domain in the real one, so a previous run's opt-in would carry over.
    static let defaultsKeys = [ScreendropPreferences.libraryUsesIntelligenceKey, ScreendropPreferences.libraryInsightsIncludeExistingKey,
                               "libraryInsightsSince", ScreendropPreferences.libraryReadsTextKey]

    static func main() async {
        defer { defaultsKeys.forEach(UserDefaults.standard.removeObject) }
        do {
            defaultsKeys.forEach(UserDefaults.standard.removeObject)
            try await run()
            print("PASS: Library insights")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    struct Fixture {
        let name: String
        let lines: [String]
        let source: CaptureSource?
    }

    static let fixtures = [
        Fixture(name: "stripe", lines: ["Payouts", "Payout schedule: Automatic, every Monday",
                                        "Send payouts to: Chase bank account ending 4242",
                                        "Minimum payout amount: $100.00 USD", "Next payout: Oct 27, $1,284.50"],
                source: CaptureSource(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Payouts – Stripe Dashboard")),
        Fixture(name: "xcode", lines: ["Build Failed", "CaptureLibraryIndex.swift:42:13",
                                       "error: cannot find 'CaptureInsightRules' in scope",
                                       "Screendrop — Debug Dev — My Mac", "1 error, 218 warnings"],
                source: CaptureSource(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "Screendrop — CaptureLibraryIndex.swift")),
        Fixture(name: "mail", lines: ["From: TAP Air Portugal", "Subject: Your flight itinerary to Lisbon",
                                      "Flight TP 218 departs Boston Logan at 6:40 PM on Nov 14",
                                      "Arrives Lisbon Humberto Delgado at 6:25 AM on Nov 15", "Booking reference: QX7P2L"],
                source: CaptureSource(bundleIdentifier: "com.apple.mail", appName: "Mail", windowTitle: "Inbox")),
        Fixture(name: "slack", lines: ["#release-planning", "Priya: can we ship 2.4 on Thursday?",
                                       "Sam: the crash in onboarding is fixed, QA signed off",
                                       "Priya: great, I'll write the release notes tonight"],
                source: CaptureSource(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "release-planning")),
    ]

    static func run() async throws {
        let support = ScreendropStorage.applicationSupportDirectory
        try check(support.path.contains("/tmp/screendrop-idle-save-"), "Storage is outside the temporary home: \(support.path)")
        print("CHECK: availability \(SystemLanguageModel.default.availability), vision \(SystemLanguageModel.default.capabilities.contains(.vision))")
        try check(CaptureIntelligence.isModelAvailable, "The model isn't available on this Mac")
        let history = ScreenshotHistoryStore.shared
        let model = CaptureLibraryModel.shared
        let index = CaptureLibraryIndex.shared
        let store = CaptureTextIndexStore(directory: support.appendingPathComponent("Library Index", isDirectory: true))
        let scratch = support.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        index.start()
        // The first plan fixes "new from now on"; captures from before it wait for the opt-in.
        try await waitUntil("first plan") { index.modelAvailable && index.usesIntelligence }

        // Real answers for screenshots with clear text.
        var durations: [Duration] = []
        var stripeID = ""
        for fixture in fixtures {
            try writePNG(fixture.lines, to: scratch.appendingPathComponent("\(fixture.name).png"))
            let url = history.importScreenshot(from: scratch.appendingPathComponent("\(fixture.name).png"), source: fixture.source)
            let id = try require(history.items.first).id.uuidString
            if fixture.name == "stripe" { stripeID = id }
            try await waitUntil("\(fixture.name) read") { index.entries[id] != nil }
            let started = ContinuousClock.now
            try await waitUntil("\(fixture.name) described") { index.entries[id]?.insight != nil }
            durations.append(ContinuousClock.now - started)
            let insight = try require(index.entries[id]?.insight)
            print("MODEL: \(fixture.name): title \(insight.title.map { "\"\($0)\"" } ?? "nil"), category \(insight.category ?? "nil"), keywords \(insight.keywords), declined \(insight.declined), \(durations.last!)")
            try check(!insight.declined, "\(fixture.name) declined")
            let title = try require(insight.title, "\(fixture.name) has no title")
            try check((2...6).contains(title.split(separator: " ").count), "\(fixture.name) title isn't 2–6 words")
            try check(!insight.keywords.isEmpty, "\(fixture.name) has no keywords")
            try check(store.loadAll()[id]?.insight == insight, "\(fixture.name) insight not saved")
            try await waitUntil("\(fixture.name) title shows", timeout: .seconds(5)) { (try? item(id).title) == title }
            let shown = try item(id)
            // The file, the name exports and uploads use, and the custom name stay as they were.
            try check(shown.customName == nil && shown.name == url.lastPathComponent && shown.fileURL == url, "\(fixture.name): model title leaked into names")
            try check(shown.subtitle == shown.dateTitle && shown.automaticTitle == title, "\(fixture.name): subtitle or placeholder wrong")
            let suggestions = index.suggestedTags(for: shown, libraryTags: model.tags)
            print("MODEL: \(fixture.name) suggestions \(suggestions)")
            try check(suggestions.first == fixture.source?.appName, "\(fixture.name): app name not suggested first")
        }
        let average = durations.reduce(Duration.zero, +) / durations.count
        print("CHECK: model answered \(durations.count) screenshots, \(average) on average (first includes warm-up)")

        // A user-named capture keeps its name; clearing it brings back the model's title.
        try writePNG(["Quarterly roadmap review", "Q4 goals: ship Library search, model titles and tag suggestions",
                      "Owner: Platform team", "Due: December 12"], to: scratch.appendingPathComponent("named.png"))
        history.importScreenshot(from: scratch.appendingPathComponent("named.png"))
        let named = try require(history.items.first)
        history.rename(id: named.id, to: "My roadmap notes")
        model.refresh()
        try await waitUntil("named described") { index.entries[named.id.uuidString]?.insight != nil }
        let namedInsight = try require(index.entries[named.id.uuidString]?.insight)
        print("MODEL: named: title \(namedInsight.title ?? "nil"), category \(namedInsight.category ?? "nil"), keywords \(namedInsight.keywords)")
        model.refresh()
        try await Task.sleep(for: .milliseconds(500))
        try check(try item(named.id.uuidString).title == "My roadmap notes", "The model replaced a user's name")
        try check(history.items.first { $0.id == named.id }?.displayName == "My roadmap notes", "History name changed")
        history.rename(id: named.id, to: "")
        model.refresh()
        try await waitUntil("cleared name shows the model title", timeout: .seconds(5)) {
            (try? item(named.id.uuidString).title) == namedInsight.title && namedInsight.title != nil
        }
        print("CHECK: a user's name wins; clearing it shows the model title")

        // Accepting a suggestion uses setTag; dismissing one sticks through a re-read.
        let stripe = try item(stripeID)
        let offered = index.suggestedTags(for: stripe, libraryTags: model.tags)
        let accepted = try require(offered.first), dismissed = try require(offered.dropFirst().first)
        model.selection = [stripeID]
        model.setTag(accepted, applied: true)
        try await waitUntil("accepted tag lands", timeout: .seconds(5)) { (try? item(stripeID).tags) == [accepted] }
        index.dismissSuggestion(dismissed, for: try item(stripeID))
        let after = index.suggestedTags(for: try item(stripeID), libraryTags: model.tags)
        try check(!after.contains(accepted) && !after.contains(dismissed), "Accepted or dismissed tag still offered: \(after)")
        try await Task.sleep(for: .milliseconds(300))
        try check(store.loadAll()[stripeID]?.dismissedSuggestions == [CaptureInsightRules.fold(dismissed)], "Dismissal not saved")
        let stripeTitle = index.entries[stripeID]?.insight?.title
        let stripeURL = try item(stripeID).fileURL
        try writePNG(fixtures[0].lines + ["Edited: arrow added"], to: stripeURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: stripeURL.path)
        model.refresh()
        try await waitUntil("edited screenshot read again") { index.entries[stripeID]?.paragraphs.contains { $0.contains("arrow") } == true }
        try check(index.entries[stripeID]?.insight?.title == stripeTitle, "An edit dropped the model title")
        try check(!index.suggestedTags(for: try item(stripeID), libraryTags: model.tags).contains(dismissed), "A re-read brought a dismissal back")
        try check(store.loadAll()[stripeID]?.dismissedSuggestions == [CaptureInsightRules.fold(dismissed)], "Re-read lost the dismissal on disk")
        print("CHECK: accepted \"\(accepted)\" via setTag, dismissed \"\(dismissed)\", both hold through a re-read")

        // A recording: its first frame and its captions.
        let session = try RecordingSessionStore.createSession()
        try await movie(["Keynote", "Product roadmap 2027", "Launch timeline and pricing tiers"], at: session.screenURL)
        var manifest = CaptureManifest()
        manifest.duration = 6; manifest.pixelWidth = 1280; manifest.pixelHeight = 720
        try session.writeCaptureManifest(manifest)
        var document = RecordingEditDocument(style: RecordingStudioStyle(), zoomEnabled: false, zoomCues: [])
        document.subtitleCues = [RecordingSubtitleCue(start: 0, end: 3, text: "Today I'll walk through the 2027 roadmap"),
                                 RecordingSubtitleCue(start: 3, end: 6, text: "and how the new pricing tiers work")]
        try session.writeEditDocument(document)
        try session.updateProjectMetadata { $0.source = CaptureSource(bundleIdentifier: "com.apple.Keynote", appName: "Keynote", windowTitle: "Roadmap 2027") }
        await history.importRecordingSession(session)
        let recordingID = "recording:\(session.directoryURL.standardizedFileURL.path)"
        try await waitUntil("recording described") { index.entries[recordingID]?.insight != nil }
        let recordingInsight = try require(index.entries[recordingID]?.insight)
        print("MODEL: recording: title \(recordingInsight.title ?? "nil"), category \(recordingInsight.category ?? "nil"), keywords \(recordingInsight.keywords), declined \(recordingInsight.declined)")
        try check(recordingInsight.title != nil, "Recording has no title")
        let recording = try item(recordingID)
        let recordingTag = try require(index.suggestedTags(for: recording, libraryTags: model.tags).first)
        model.selection = [recordingID]
        model.setTag(recordingTag, applied: true)
        try await waitUntil("recording tag lands", timeout: .seconds(5)) { (try? item(recordingID).tags) == [recordingTag] }
        try check(try item(recordingID).customName == nil && session.loadProjectMetadata()?.displayName == nil,
                  "The model title was stored as the recording's name")
        print("CHECK: recording titled and \"\(recordingTag)\" accepted into its project")

        try await declineChecks(scratch: scratch, store: store)
        try await gateChecks(scratch: scratch, store: store, titled: stripeID)
        try await existingChecks(scratch: scratch)
    }

    /// A refusal or guardrail stores the declined mark and isn't asked
    /// again; a busy model isn't asked again this session either.
    static func declineChecks(scratch: URL, store: CaptureTextIndexStore) async throws {
        let index = CaptureLibraryIndex.shared
        let history = ScreenshotHistoryStore.shared
        let real = index.describer
        defer { index.describer = real }
        for (name, error) in [("guardrail", LanguageModelError.guardrailViolation(.init(debugDescription: "harness"))),
                              ("refusal", LanguageModelError.refusal(.init(explanation: "No", debugDescription: "harness")))] as [(String, any Error)] {
            var calls = 0
            index.describer = { _, _, _ in calls += 1; return CaptureIntelligence.outcome(for: error) }
            try writePNG(["Declined \(name) fixture"], to: scratch.appendingPathComponent("\(name).png"))
            history.importScreenshot(from: scratch.appendingPathComponent("\(name).png"))
            let id = try require(history.items.first).id.uuidString
            try await waitUntil("\(name) marked") { index.entries[id]?.insight?.declined == true }
            for _ in 0..<3 {
                CaptureLibraryModel.shared.refresh()
                try await Task.sleep(for: .milliseconds(400))
            }
            try check(calls == 1, "\(name): asked \(calls) times")
            try check(store.loadAll()[id]?.insight?.declined == true, "\(name): declined mark not saved")
            try check(try item(id).title == (try item(id)).dateTitle, "\(name): declined capture got a title")
            print("CHECK: \(name) stored as declined, asked once")
        }
        var calls = 0
        index.describer = { _, _, _ in
            calls += 1
            return CaptureIntelligence.outcome(for: LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "harness")))
        }
        try writePNG(["Rate limited fixture"], to: scratch.appendingPathComponent("busy.png"))
        history.importScreenshot(from: scratch.appendingPathComponent("busy.png"))
        let busyID = try require(history.items.first).id.uuidString
        try await waitUntil("busy asked") { calls == 1 }
        for _ in 0..<3 {
            CaptureLibraryModel.shared.refresh()
            try await Task.sleep(for: .milliseconds(400))
        }
        try check(calls == 1 && index.entries[busyID]?.insight == nil && index.insightsPending == 0, "Busy model: asked \(calls) times or stored")
        print("CHECK: a busy model isn't stored or asked again this session")
    }

    /// With the model gone (a fake provider, as after removing it to free
    /// disk space), stored titles and suggestions keep showing, nothing new is
    /// asked and Settings hides the switch. The switch off hides them, with
    /// the model or without it, and keeps them.
    static func gateChecks(scratch: URL, store: CaptureTextIndexStore, titled id: String) async throws {
        let index = CaptureLibraryIndex.shared
        let history = ScreenshotHistoryStore.shared
        let tags = { CaptureLibraryModel.shared.tags }
        let stored = try require(index.entries[id]?.insight)
        let storedSuggestions = index.suggestedTags(for: try item(id), libraryTags: tags())
        index.modelAvailability = { false }
        index.settingsDidChange()
        try await Task.sleep(for: .seconds(1))
        try check(!index.modelAvailable, "Settings would still show the switch")
        try check(try item(id).title == stored.title, "A stored title hid when the model went away")
        try check(index.suggestedTags(for: try item(id), libraryTags: tags()) == storedSuggestions, "Stored suggestions changed when the model went away")
        try check(index.entries[id]?.insight == stored && store.loadAll()[id]?.insight == stored, "Unavailable changed stored output")
        var calls = 0
        let real = index.describer
        index.describer = { item, entry, image in calls += 1; return await real(item, entry, image) }
        defer { index.describer = real }
        let source = CaptureSource(bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: nil)
        try writePNG(["Unavailable model fixture", "Safari reading list"], to: scratch.appendingPathComponent("gate.png"))
        history.importScreenshot(from: scratch.appendingPathComponent("gate.png"), source: source)
        let gateID = try require(history.items.first).id.uuidString
        try await waitUntil("gate fixture read") { index.entries[gateID] != nil }
        try await Task.sleep(for: .seconds(2))
        try check(calls == 0 && index.entries[gateID]?.insight == nil, "Asked the model while it was unavailable")
        try check(index.suggestedTags(for: try item(gateID), libraryTags: tags()) == ["Safari"], "App name not offered without the model")
        print("CHECK: unavailable keeps showing stored titles (\"\(stored.title ?? "nil")\") and suggestions \(storedSuggestions), asks nothing new, still offers the app")
        // The switch off while Settings hides it (its last value holds): hidden and kept.
        UserDefaults.standard.set(false, forKey: ScreendropPreferences.libraryUsesIntelligenceKey)
        index.settingsDidChange()
        try await waitUntil("titles hidden", timeout: .seconds(5)) { (try? item(id).title) == (try? item(id).dateTitle) }
        let appOnly = CaptureInsightRules.suggestions(appName: try item(id).source?.appName, insight: nil, tags: try item(id).tags,
                                                      libraryTags: tags(), dismissed: index.entries[id]?.dismissedSuggestions ?? [])
        try check(index.suggestedTags(for: try item(id), libraryTags: tags()) == appOnly, "Model suggestions showed with the switch off")
        try check(store.loadAll()[id]?.insight == stored, "Switch off erased stored output")
        // The model back, the switch still off: still hidden, nothing asked.
        index.modelAvailability = { CaptureIntelligence.isModelAvailable }
        index.settingsDidChange()
        try await Task.sleep(for: .seconds(1))
        try check(try item(id).title == (try item(id)).dateTitle && calls == 0, "Switch off still titled or asked")
        print("CHECK: switch off hides stored output and asks nothing, with or without the model")
        // On again: titles return and the capture missed meanwhile is described.
        UserDefaults.standard.set(true, forKey: ScreendropPreferences.libraryUsesIntelligenceKey)
        index.settingsDidChange()
        try await waitUntil("titles back") { (try? item(id).title) == stored.title && index.entries[gateID]?.insight != nil }
        print("CHECK: switch on restores titles and describes what was missed")
    }

    /// Captures from before the model first ran wait for the user's opt-in.
    static func existingChecks(scratch: URL) async throws {
        let index = CaptureLibraryIndex.shared
        let history = ScreenshotHistoryStore.shared
        // Pretend the model first ran an hour from now, so this capture is "older".
        UserDefaults.standard.set(Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate, forKey: "libraryInsightsSince")
        try writePNG(["Older capture", "Grocery list: oat milk, lemons, basil"], to: scratch.appendingPathComponent("older.png"))
        history.importScreenshot(from: scratch.appendingPathComponent("older.png"))
        let id = try require(history.items.first).id.uuidString
        try await waitUntil("older read") { index.entries[id] != nil }
        CaptureLibraryModel.shared.refresh()
        try await Task.sleep(for: .seconds(2))
        try check(index.entries[id]?.insight == nil, "An older capture was described without the opt-in: \(String(describing: index.entries[id]?.insight))")
        try check(index.olderWithoutInsight > 0, "Older captures not counted for the opt-in")
        print("CHECK: \(index.olderWithoutInsight) older captures wait for the opt-in")
        index.includeExistingCaptures()
        try await waitUntil("older described after the opt-in") { index.entries[id]?.insight != nil }
        try check(index.olderWithoutInsight == 0, "Older count not cleared")
        let insight = try require(index.entries[id]?.insight)
        print("MODEL: older: title \(insight.title ?? "nil"), category \(insight.category ?? "nil"), keywords \(insight.keywords)")
        print("CHECK: Title and tag existing captures runs the older ones")
    }
}
