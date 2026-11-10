import CoreSpotlight
import Foundation
import FoundationModels

// Run with check-capture-plain-search.py. Exercises plain-words Library search
// with the real on-device model, without UI: it indexes made-up captures into
// this check's own Spotlight index (its own bundle ID, never the app's or a
// real Library), asks each sample request, and empties the index again.
// Needs Apple Intelligence, so run it on a Mac that has it (not the VMPal VM).
@main
struct CapturePlainSearchCheck {
    struct Sample {
        var id: String
        var title: String
        var isVideo = false
        var daysAgo: Int
        var tags: [String] = []
        var app: String
        var window: String? = nil
        var text: [String]
    }

    /// Made-up captures. None of their wording appears in the search
    /// instructions (`CapturePlainSearch.instructions`), so a hit isn't an echo.
    static let samples: [Sample] = [
        .init(id: "invoice-stripe", title: "Invoice 2291", daysAgo: 6, tags: ["billing"], app: "Safari", window: "Invoice · Stripe Dashboard",
              text: ["Stripe", "Invoice #2291 paid", "Northwind Traders", "Amount due $1,480.00", "Paid Nov 4"]),
        .init(id: "invoice-old", title: "Invoice 1907", daysAgo: 64, tags: ["billing"], app: "Safari", window: "Invoice · Stripe Dashboard",
              text: ["Stripe", "Invoice #1907 paid", "Blue Yonder Airlines", "Amount due $320.00"]),
        .init(id: "flight", title: "Boarding pass", daysAgo: 12, tags: ["travel"], app: "Mail", window: "Your trip to Lisbon",
              text: ["TAP Air Portugal", "Boston BOS to Lisbon LIS", "Seat 23A", "Boarding 18:05 Gate E7"]),
        .init(id: "crash", title: "Build failure", daysAgo: 1, app: "Xcode", window: "Uploader — UploadQueue.swift",
              text: ["Thread 4: Fatal error: Index out of range", "UploadQueue.swift:118", "retryPending()"]),
        .init(id: "recipe", title: "Oct 2, 7:12 PM", daysAgo: 39, app: "Safari", window: "Slow-roasted tomato soup",
              text: ["Slow-roasted tomato soup", "1 kg ripe tomatoes, halved", "Roast at 160°C for 90 minutes", "Blend with basil"]),
        .init(id: "chart", title: "Weekly signups", daysAgo: 3, tags: ["metrics"], app: "Numbers", window: "Growth.numbers",
              text: ["Weekly signups", "Week 44: 1,204", "Week 45: 1,391", "Conversion 3.8%"]),
        .init(id: "chat", title: "Oct 29, 10:03 AM", daysAgo: 12, app: "Slack", window: "#design-review",
              text: ["Priya: can we move the launch checklist to Thursday?", "Marco: fine by me, the icons are still in review"]),
        .init(id: "map", title: "Route to the cabin", daysAgo: 20, tags: ["travel"], app: "Maps",
              text: ["2 hr 48 min", "via I-93 N", "Franconia Notch", "Arrive 4:15 PM"]),
        .init(id: "wifi", title: "Router settings", daysAgo: 150, app: "Safari", window: "Archer AX55 — Wireless",
              text: ["Wireless Settings", "Network Name (SSID) Birchwood-5G", "Security WPA3-Personal", "Channel Width 80 MHz"]),
        .init(id: "demo", title: "Onboarding walkthrough", isVideo: true, daysAgo: 2, tags: ["demo"], app: "Simulator",
              text: ["Welcome to Tidepool", "Create your first board", "So here I tap the plus button and name the board"]),
        .init(id: "bug-video", title: "Nov 2, 3:40 PM", isVideo: true, daysAgo: 8, tags: ["bug"], app: "Google Chrome", window: "Checkout — Fernwood Books",
              text: ["Checkout", "Apply coupon", "The total jumps back to forty dollars after I apply the coupon"]),
        .init(id: "calendar", title: "December schedule", daysAgo: 0, app: "Calendar",
              text: ["December 2026", "Dentist 9:30 AM", "Quarterly planning offsite", "School concert 6 PM"]),
        .init(id: "receipt", title: "Order confirmation", daysAgo: 25, tags: ["billing"], app: "Mail", window: "Your order has shipped",
              text: ["Order #88213", "Standing desk frame, walnut top", "Total $612.40", "Arrives Oct 21"]),
        .init(id: "terminal", title: "Oct 30, 11:20 PM", daysAgo: 11, app: "Terminal", window: "zsh",
              text: ["$ git rebase --continue", "error: could not apply 3f9c2ab", "CONFLICT (content): Merge conflict in Package.swift"]),
    ]

    /// Requests in the words a person would type, with the captures a good
    /// answer holds. An answer is good when it holds them all and nothing
    /// else, OK when it holds them all among at most three others, else bad.
    static let requests: [(ask: String, expected: Set<String>)] = [
        ("the Stripe invoice from last week", ["invoice-stripe"]),
        ("boarding pass for Lisbon", ["flight"]),
        ("that crash in the upload queue", ["crash"]),
        ("tomato soup recipe", ["recipe"]),
        ("signups chart", ["chart"]),
        ("slack conversation about the launch checklist", ["chat"]),
        ("how long is the drive to the cabin", ["map"]),
        ("wifi password page for the router", ["wifi"]),
        ("recordings from this week", ["demo"]),
        ("video of the coupon bug", ["bug-video"]),
        ("what did I capture in Xcode yesterday", ["crash"]),
        ("standing desk order", ["receipt"]),
        ("merge conflict", ["terminal"]),
        ("anything tagged billing", ["invoice-stripe", "invoice-old", "receipt"]),
        ("dentist appointment", ["calendar"]),
        ("screenshots from Safari older than a month", ["invoice-old", "recipe", "wifi"]),
        ("Northwind", ["invoice-stripe"]),
        ("unicorn spreadsheet", []),
    ]

    /// Written after the instructions were settled and never used to adjust
    /// them: counted apart, as the fairer number.
    static let heldOut: [(ask: String, expected: Set<String>)] = [
        ("Blue Yonder", ["invoice-old"]),
        ("gate number for my flight", ["flight"]),
        ("conversion rate numbers", ["chart"]),
        ("what Priya said", ["chat"]),
        ("the walkthrough video I recorded", ["demo"]),
        ("Fernwood checkout", ["bug-video"]),
        ("screenshots from Terminal", ["terminal"]),
        ("quarterly planning", ["calendar"]),
        ("what did I capture today", ["calendar"]),
        ("billing screenshots from the last two weeks", ["invoice-stripe"]),
    ]

    static func main() async {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".search-check") == true else {
            return print("Run through check-capture-plain-search.py: this check needs its own bundle ID.")
        }
        print("model:", SystemLanguageModel.default.availability, "context:", SystemLanguageModel.default.contextSize)
        guard CapturePlainSearch.isAvailable else { return print("SKIPPED: the on-device model isn't available on this Mac.") }
        let now = Date()
        let backend = CoreSpotlightCaptureBackend()
        let records = samples.map { sample in
            let taken = Calendar.current.date(byAdding: .day, value: -sample.daysAgo, to: now)!
            return CaptureSpotlightRecord(
                id: sample.id, title: sample.title, isVideo: sample.isVideo, createdAt: taken, modifiedAt: taken, tags: sample.tags,
                source: CaptureSource(bundleIdentifier: nil, appName: sample.app, windowTitle: sample.window),
                entry: CaptureTextEntry(id: sample.id, fingerprint: sample.id, paragraphs: sample.text), contentKey: sample.id)
        }
        do {
            try await backend.deleteAll()
            try await backend.index(records, thumbnails: [:])
        } catch {
            return print("FAILED: indexing:", error)
        }
        for (name, requests) in [("first set", requests), ("held out", heldOut)] {
        var counts = (good: 0, ok: 0, bad: 0)
        for request in requests {
            let start = ContinuousClock.now
            var line: String
            do {
                let answer = try await CapturePlainSearch.search(request.ask, now: now)
                let found = Set(answer.ids)
                let extra = found.subtracting(request.expected).count
                let verdict = !request.expected.isSubset(of: found) ? "bad" : extra == 0 ? "good" : extra <= 3 ? "OK" : "bad"
                switch verdict {
                case "good": counts.good += 1
                case "OK": counts.ok += 1
                default: counts.bad += 1
                }
                line = "\(verdict)\t\(request.ask)\t→ \(answer.ids)\t“\(answer.reply.prefix(120))”"
            } catch {
                counts.bad += 1
                line = "bad\t\(request.ask)\t→ error: \(error)"
            }
            print(line, "\t\((ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
        }
        print("RESULT \(name): good \(counts.good) / OK \(counts.ok) / bad \(counts.bad) of \(requests.count)")
        }
        try? await backend.deleteAll()
    }
}
