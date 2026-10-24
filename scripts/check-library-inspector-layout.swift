import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Security
import SwiftUI
import UniformTypeIdentifiers

// Hosts the real Library inspector off-screen and sweeps the window's height
// around the content's height. At no height may the content's width keep
// changing: a vertical scroll bar that takes width flipped on and off when the
// content sat at the viewport's height, and the inspector shuddered (sd-jppy).
// Windows are borderless, unconstrained, transparent and 30,000 pt off every
// display; exit 5 means one touched a display. Run through
// check-library-inspector-layout.py, which loads harness-guard.c (exit 7: a
// keychain or permission call was stopped).
@main
struct LibraryInspectorLayoutCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }

    final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Every change of the scroll content's width, from its frame notifications.
    final class WidthLog {
        var changes = 0
        var widths: Set<Int> = []
        var last: CGFloat = -1
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

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
                print("ABORT: a window touched a display at \(step): \(frame)")
                exit(5)
            }
        }
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews { if let scroll = scrollView(in: subview) { return scroll } }
        return nil
    }

    static func wait(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A wide screenshot, like the one the user's inspector showed.
    static func writeScreenshot(to url: URL) throws {
        let width = 680, height = 290
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "Cannot draw the fixture") }
        context.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 260, height: 180))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(description: "Cannot encode the fixture") }
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Cannot write the fixture")
    }

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.dropFirst().first == "guard-selftest" {
            // A dummy service, so even an unguarded run finds nothing and can't prompt.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "sukusho-harness-guard-selftest-nonexistent"]
            _ = SecItemCopyMatching(query as CFDictionary, nil)
            print("UNGUARDED: the keychain call went through")
            exit(1)
        }
        guard let root = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw Failure(description: "Run through check-library-inspector-layout.py")
        }
        let home = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        try check(support.hasPrefix(home.path + "/"), "Foundation storage escaped the isolated home")

        // UserDefaults ignores the isolated home: write only this binary's own domain, and empty it after.
        let domain = ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            CFPreferencesAppSynchronize(domain as CFString)
        }
        // Reading text would add and remove a "Reading text…" row mid-sweep.
        UserDefaults.standard.set(false, forKey: ScreendropPreferences.libraryReadsTextKey)

        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()

        let fixture = home.appendingPathComponent("fixture.png")
        try writeScreenshot(to: fixture)
        let store = ScreenshotHistoryStore.shared
        let url = store.importScreenshot(from: fixture, source: CaptureSource(bundleIdentifier: nil, appName: "Rex Beta",
                                                                               windowTitle: "Handoff - floral-cove"))
        guard let stored = store.item(for: url) else { throw Failure(description: "The fixture wasn't imported") }
        for tag in ["Rex Beta", "workspace"] { store.setTag(tag, applied: true, ids: [stored.id]) }

        let model = CaptureLibraryModel.shared
        model.refresh()
        let loadDeadline = Date().addingTimeInterval(10)
        while !(model.hasLoaded && model.items.count == 1), Date() < loadDeadline { wait(0.05) }
        try check(model.items.count == 1, "The Library didn't list the fixture (\(model.items.count) items)")
        model.selection = [model.items[0].id]

        let width: CGFloat = 280
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 1600),
                                     styleMask: [.borderless], backing: .buffered, defer: true)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        let host = NSHostingView(rootView: CaptureLibraryInspector(model: model).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.contentView = host
        window.orderBack(nil)
        abortIfOnDisplay("order in")
        wait(2) // the thumbnail and the size on disk arrive
        abortIfOnDisplay("load")
        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            throw Failure(description: "The inspector has no scroll view")
        }
        let contentHeight = document.frame.height
        let style = scroll.scrollerStyle == .legacy ? "legacy" : "overlay"
        print("CHECK: content \(Int(document.frame.width))×\(Int(contentHeight)) pt at full width, scroller style \(style)")
        try check(contentHeight > 300, "The inspector content didn't lay out (\(contentHeight) pt)")

        let log = WidthLog()
        document.postsFrameChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { _ in
            MainActor.assumeIsolated {
                let current = document.frame.width
                if current != log.last {
                    log.changes += 1
                    log.widths.insert(Int(current.rounded()))
                    log.last = current
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Down through the content's height and a scroll bar's width below it, a point at a time.
        var looping: [(height: Int, changes: Int, widths: [Int])] = []
        for height in stride(from: (contentHeight + 6).rounded(), through: (contentHeight - 30).rounded(), by: -1) {
            window.setContentSize(NSSize(width: width, height: height))
            log.changes = 0
            log.widths = []
            log.last = document.frame.width
            wait(0.4)
            abortIfOnDisplay("height \(Int(height))")
            if log.changes > 2 { looping.append((Int(height), log.changes, log.widths.sorted())) }
        }
        window.orderOut(nil)
        for row in looping { print("LOOP: height \(row.height) pt, width changed \(row.changes) times between \(row.widths)") }
        try check(looping.isEmpty, "The inspector's width kept changing at \(looping.count) window heights")
        print("PASS: the inspector's width settles at every window height from \(Int(contentHeight) + 6) down to \(Int(contentHeight) - 30) pt")
    }
}
