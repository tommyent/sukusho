// Run against a built Debug app, without launching it:
// xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 -I "$products" -F "$products" "$app/Contents/MacOS/Sukusho Dev.debug.dylib" \
//   -Xlinker -rpath -Xlinker "$app/Contents/MacOS" -Xlinker -rpath -Xlinker "$app/Contents/Frameworks" \
//   scripts/test-library-card-press.swift -o /tmp/test-library-card-press && /tmp/test-library-card-press
import AppKit
import SwiftUI
@testable import Screendrop

@main
struct LibraryCardPressTest {
    struct Entry: Identifiable { let id: String }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let collection = LibraryCollectionView()
        let item = LibraryCollectionItem()
        let menu = NSMenu()
        collection.contextMenuProvider = { _ in
            precondition(!item.isPressed, "The press must clear before building the menu")
            return menu
        }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 0)!
        collection.setPressed(item)
        precondition(item.isPressed)
        precondition(collection.menu(for: event) === menu)

        let frame = NSRect(x: 0, y: 0, width: 160, height: 120)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = collection
        let button = NSButton(frame: NSRect(x: 50, y: 40, width: 60, height: 40))
        collection.addSubview(button)
        let controlClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 80, y: 60),
                                              modifierFlags: [.control], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        var menuRequests = 0
        collection.contextMenuProvider = { event in
            precondition(event === controlClick && !item.isPressed)
            menuRequests += 1
            return nil // Exercise the monitor’s mouse-down path without starting a menu tracking loop.
        }
        collection.setPressed(item)
        precondition(collection.trackMouseEvent(controlClick) == nil, "Control-click must not reach normal selection or cell buttons")
        precondition(menuRequests == 1 && !item.isPressed)
        let plainClick = NSEvent.mouseEvent(with: .leftMouseDown, location: controlClick.locationInWindow, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 2, clickCount: 1, pressure: 1)!
        precondition(collection.trackMouseEvent(plainClick) === plainClick && menuRequests == 1)

        let coordinator = CaptureLibraryCollection<Entry>(
            items: [], revision: 0, layout: .grid, cardWidth: 220, selection: .constant([]), isBusy: false,
            cell: { _, _, _ in AnyView(EmptyView()) }, menu: { _ in [] }, onAction: { _ in }
        ).makeCoordinator()
        collection.setPressed(item)
        precondition(item.isPressed)
        // AppKit owns the real drag loop. The delegate only needs the session notification here.
        coordinator.collectionView(collection, draggingSession: NSDraggingSession(),
                                   willBeginAt: .zero, forItemsAt: [IndexPath(item: 0, section: 0)])
        precondition(!item.isPressed, "The drag must clear the pressed cell")
        print("Right-click, Control-click and drag cleared the pressed cell.")
    }
}
