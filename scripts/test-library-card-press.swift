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
        print("Menu and drag both cleared the pressed cell.")
    }
}
