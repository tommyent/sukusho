// The command palette's states drawn to PNGs, light and dark, in Classic, Chip and Glass, with a stand-in for the app
// behind it (sample captures, clips and a Library selection), for looking at what the palette draws without running the
// app. Compiled with the app's sources by scripts/render-command-palette.sh. Each is drawn in a window kept off every
// display (it stops if one touches a display), at the Mac's own scale. Glass's frost there has nothing behind it, and
// Reduce Transparency and Increase Contrast need the live app.

import AppKit
import SwiftUI

@MainActor
final class SampleHost: CommandPaletteHost {
    var window: PaletteWindow
    var selectionTitle: String? = "Lake at dawn"
    var place: String
    var savedTheme: String

    init(window: PaletteWindow, place: String, savedTheme: String) {
        self.window = window
        self.place = place
        self.savedTheme = savedTheme
    }

    func state(of command: PaletteCommand) -> PaletteCommandState {
        switch command.id {
        case "selection.revert": return .off("not edited yet")
        case "selection.gif", "selection.bugReport", "selection.guide": return .off("recordings only")
        case "selection.copyLink", "selection.openShared", "selection.deleteCloud": return .off("not shared yet")
        case "switch.optimizeNew": return PaletteCommandState(isOn: true)
        case "switch.optimizeCopy", "switch.launchAtLogin", "switch.betaUpdates": return PaletteCommandState(isOn: false)
        case let id where id.hasPrefix("switch."): return PaletteCommandState(isOn: true)
        case "look.theme": return PaletteCommandState(detail: savedTheme.capitalized)
        case "look.appearance": return PaletteCommandState(detail: "System")
        case "look.background": return PaletteCommandState(detail: "Grid")
        case "window.inspector": return PaletteCommandState(title: "Hide Inspector")
        case "library.sidebar": return PaletteCommandState(title: "Hide Sidebar")
        case "tool.rectangle": return PaletteCommandState(detail: "Tool")
        case "editor.save": return .off("no changes to save")
        case "capture.draw": return .off("only while recording")
        default: return .ready
        }
    }

    func keys(for command: PaletteCommand) -> [String] {
        switch command.keys {
        case .none: []
        case .keys(let keys): keys
        case .hotkey(let action): action.defaultShortcut.displayTokens
        }
    }

    func rows(for step: PaletteStep, query: String) -> [PaletteRow] {
        switch step {
        case .changeTheme:
            return ["classic", "chip", "glass"].map {
                PaletteRow(id: "\($0)-\(dark ? "dark" : "light")", title: $0.capitalized, detail: $0 == savedTheme ? "in use" : "",
                           ticked: $0 == savedTheme)
            }
        case .recentCaptures:
            let captures: [(String, String)] = [
                ("Lake at dawn", "Screenshot · 1672 × 941 · Nov 9, 6:57 AM"),
                ("Slow Roads walkthrough", "Recording · 2560 × 1600 · Nov 9, 7:02 AM"),
                ("Home page", "Screenshot · 1440 × 900 · Nov 9, 6:56 AM"),
                ("Northern lights", "Screenshot · 1200 × 800 · Nov 9, 6:54 AM"),
                ("Meadow path", "Screenshot · 1024 × 683 · Nov 9, 6:54 AM"),
            ]
            return captures.map { PaletteRow(id: $0.0, title: $0.0, subtitle: $0.1,
                                             thumbnail: URL(fileURLWithPath: "/System/Library/Desktop Pictures")) }
                + [PaletteRow(id: "all", title: "Show All Captures…", symbol: "square.grid.2x2")]
        case .clipboardHistory:
            return ["npm run build", "https://example.com/pricing", "Meeting notes, Tuesday", "#1F6FEB", "Screenshot 2026-11-24"]
                .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                .map { PaletteRow(id: $0, title: $0, symbol: $0.hasPrefix("Screenshot") ? "photo" : "text.alignleft") }
        case .goTo:
            return ["All Captures", "Screenshots", "Recordings", "Clipboard", "Saved", "Uploads", "Received"].map {
                PaletteRow(id: $0, title: $0, detail: "Library", symbol: "sidebar.left")
            }
        case .addTag:
            var rows = ["bug", "design", "release"].filter { query.isEmpty || $0.contains(query) }
                .map { PaletteRow(id: "tag.\($0)", title: $0, ticked: $0 == "bug") }
            if !query.isEmpty { rows.insert(PaletteRow(id: "new-tag", title: "Add tag “\(query)”"), at: 0) }
            return rows
        default:
            return []
        }
    }

    var dark = false
    func place(for step: PaletteStep) -> String? {
        switch step {
        case .recentCaptures: "10 captures"
        case .changeTheme: dark ? "Dark theme" : "Light theme"
        case .clipboardHistory: "Copies, to paste in any app"
        case .addTag: "Lake at dawn"
        default: nil
        }
    }

    func run(_ command: PaletteCommand) -> PaletteOutcome { .close }
    func choose(_ row: PaletteRow, in step: PaletteStep) -> PaletteOutcome { .close }
    func copy(_ row: PaletteRow, in step: PaletteStep) {}
    func tryOn(_ row: PaletteRow?) {}
    func searchCaptures(for text: String) {}
}

@main
struct RenderCommandPalette {
    /// Kept off every display: AppKit would otherwise pull an ordered window onto one. It also turns down the text field:
    /// with the caret in it, macOS put a 500 × 500 window of its own at a display's corner (seen here 2026-11-24, which
    /// the guard below stopped; inferred to be the caret's input accessory).
    final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if responder is NSText || responder is NSTextField { return false }
            return super.makeFirstResponder(responder)
        }
    }

    /// Stops before anything this process shows could reach a display (and the person using this Mac).
    static func abortIfOnDisplay(_ step: String) {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let screens = displays.map(CGDisplayBounds)
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == getpid() {
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if frame.width > 0, screens.contains(where: { $0.intersects(frame) }) {
                let name = info[kCGWindowName as String] as? String ?? "untitled"
                print("ABORT: a window touched a display at \(step): \(frame), \(name), layer \(info[kCGWindowLayer as String] ?? "?"), "
                      + "on screen \(info[kCGWindowIsOnscreen as String] ?? false), alpha \(info[kCGWindowAlpha as String] ?? "?")")
                exit(5)
            }
        }
    }

    /// The view in a window off every display, laid out and drawn as AppKit draws it, so the field and the scrolling
    /// list draw too (ImageRenderer leaves both out).
    @MainActor static func png<Content: View>(_ content: Content, dark: Bool) -> Data? {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                     styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = host
        window.orderBack(nil)
        abortIfOnDisplay("order in")
        // In short turns, each checked, so nothing could stay on a display for long.
        for _ in 0 ..< 8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            abortIfOnDisplay("layout")
        }
        host.layoutSubtreeIfNeeded()
        abortIfOnDisplay("draw")
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        host.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        typealias Setup = (CommandPaletteModel) -> Void
        let states: [(name: String, window: PaletteWindow, place: String, setup: Setup)] = [
            ("1-library", .library, "Library · Lake at dawn", { _ in }),
            ("2-editor-typing", .editor, "Editor · Lake at dawn", { $0.query = "rec" }),
            ("3-change-theme", .library, "Library · Lake at dawn", { model in
                model.query = "change theme"; model.press(.right); model.press(.down)
            }),
            ("4-recent-captures", .library, "Library · Lake at dawn", { model in model.query = "recent"; model.press(.right) }),
            ("5-settings", .other, "Sukusho · Settings", { _ in }),
            ("6-no-match", .library, "Library · Lake at dawn", { $0.query = "watermrk" }),
            ("7-clipboard-history", .editor, "Editor · Lake at dawn", { model in
                model.query = "clipboard history"; model.press(.right)
            }),
            ("8-add-tag", .library, "Library · Lake at dawn", { model in
                model.query = "add tag"; model.press(.right); model.query = "urgent"
            }),
            ("9-studio", .studio, "Studio · Slow Roads walkthrough", { _ in }),
        ]
        var written = 0
        for theme in ["classic", "chip", "glass"] {
            for dark in [false, true] {
                UserDefaults.standard.set("\(theme)-light", forKey: AppTheme.lightKey)
                UserDefaults.standard.set("\(theme)-dark", forKey: AppTheme.darkKey)
                for state in states {
                    let host = SampleHost(window: state.window, place: state.place, savedTheme: theme)
                    host.dark = dark
                    let model = CommandPaletteModel(host: host)
                    state.setup(model)
                    let view = CommandPaletteView(model: model, maxHeight: 620) { _ in }
                        .padding(28)
                        .background(dark ? Color(white: 0.11) : Color(white: 0.86))
                    guard let png = png(view, dark: dark) else {
                        print("could not render \(state.name)")
                        continue
                    }
                    let file = out.appendingPathComponent("\(state.name)-\(theme)-\(dark ? "dark" : "light").png")
                    try? png.write(to: file)
                    written += 1
                }
            }
        }
        print("Wrote \(written) renders to \(out.path)")
        // The panel's first frame comes from this, before SwiftUI's first layout reports the palette's size.
        let host = SampleHost(window: .library, place: "Library", savedTheme: "classic")
        let hosting = NSHostingView(rootView: CommandPaletteView(model: CommandPaletteModel(host: host), maxHeight: 620) { _ in })
        // As CommandPalettePresenter.show measures it.
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        print("Panel's first size: \(size)")
        if size.width < CommandPalettePresenter.width - 1 || size.height < 100 { print("Panel's first size is wrong"); exit(1) }
    }
}
