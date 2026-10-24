import AppKit
import Observation
import SwiftUI

// Run with check-editor-idle-save.py against the actual app sources and an isolated home:
//   python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData scripts/check-library-grid-update.swift
// Hosts CaptureLibraryCollection in a windowless NSHostingView with probe cards, not
// Library cards (those reach the cloud keychain). No windows, screen input, network or preferences.
@main
struct LibraryGridUpdateChecks {
    struct Entry: Identifiable, Equatable {
        let id: String
        var title: String
    }

    @Observable @MainActor final class Source {
        var items = (0..<12).map { Entry(id: "c\($0)", title: "Capture \($0)") }
        var revision = 0
    }

    /// What each card last drew. A card's token is made once per SwiftUI hierarchy, like a
    /// thumbnail's loaded image (sd-mtnc), so a new token means the card was rebuilt.
    @MainActor static var drawn: [String: (token: UUID, title: String)] = [:]

    struct Probe: View {
        let entry: Entry
        @State private var token = UUID()

        var body: some View {
            let _ = LibraryGridUpdateChecks.record(entry, token)
            Text(entry.title)
        }
    }

    static func record(_ entry: Entry, _ token: UUID) { drawn[entry.id] = (token, entry.title) }

    struct Host: View {
        let source: Source
        @State private var selection: Set<String> = []

        var body: some View {
            CaptureLibraryCollection(items: source.items, revision: source.revision, layout: .grid, cardWidth: 220,
                                     selection: $selection, isBusy: false,
                                     cell: { entry, _, _ in AnyView(Probe(entry: entry)) },
                                     menu: { _ in [] }, onAction: { _ in })
        }
    }

    static func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let source = Source()
        let view = NSHostingView(rootView: Host(source: source))
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        settle(view)
        let shown = drawn
        precondition(shown.count >= 6, "Only \(shown.count) cards drawn; the harness can't see the grid")
        print("CHECK: \(shown.count) cards drawn at first load")

        // A model title or a tag changes one capture: same IDs, same order.
        source.items[1].title = "Model title"
        source.revision += 1
        settle(view)
        let rebuilt = shown.keys.filter { drawn[$0]?.token != shown[$0]?.token }.sorted()
        precondition(rebuilt.isEmpty, "A title change rebuilt \(rebuilt.count) of \(shown.count) cards: \(rebuilt)")
        precondition(drawn["c1"]?.title == "Model title", "The changed card still shows \(drawn["c1"]?.title ?? "nothing")")
        print("CHECK: a title change redraws its card in place and rebuilds none of \(shown.count)")

        // Negative control: a new capture shifts every card, which still reloads.
        let before = drawn
        source.items.insert(Entry(id: "new", title: "New capture"), at: 0)
        source.revision += 1
        settle(view)
        precondition(drawn["new"] != nil, "The new capture wasn't drawn")
        let kept = before.keys.filter { drawn[$0]?.token == before[$0]?.token }
        precondition(kept.count < before.count, "An insert rebuilt no cards; the harness can't see a reload")
        print("CHECK: an insert still reloads (\(before.count - kept.count) of \(before.count) cards rebuilt)")
        print("PASS: Library grid updates")
    }
}
