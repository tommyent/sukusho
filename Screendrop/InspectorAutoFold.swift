//
//  InspectorAutoFold.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// A view's own window, for its @State or modifiers: held weakly, since the window holds the view.
final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow? = nil) {
        self.window = window
    }
}

/// Folds an inspector away on its own whenever its window is made narrower while below `foldBelow`,
/// so the window can keep getting narrower, and brings it back once there is room again, unless
/// someone hid it themselves in the meantime. Read the window frame only after initial placement.
struct InspectorAutoFold: ViewModifier {
    @Binding var isPresented: Bool
    let foldBelow: CGFloat
    let host: WeakWindow
    let windowID: ObjectIdentifier?
    let fold: InspectorFoldBox

    func body(content: Content) -> some View {
        content
            .onChange(of: windowID, initial: true) { _, id in
                if id != nil, let window = host.window { resize(to: window.frame.width) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
                if windowID != nil, let window = host.window, notification.object as? NSWindow === window {
                    resize(to: window.frame.width)
                }
            }
            .onChange(of: isPresented) { _, presented in
                // Shown by hand while folded: it stays until the next fold.
                if presented { fold.state.isFolded = false }
            }
    }

    private func resize(to width: CGFloat) {
        guard let presented = fold.resize(to: width, foldBelow: foldBelow, isPresented: isPresented) else { return }
        withAnimation(.snappy(duration: 0.2)) { isPresented = presented }
    }
}

/// The fold rule's bookkeeping, kept out of SwiftUI's state. It changes on every resize, and AppKit posts
/// resizes from inside a layout pass (SwiftUI sizing the window in `windowDidLayout`): as state, each one
/// invalidated the whole Library and laid it out again, until AppKit stopped the loop by crashing
/// (sd-kutk). Now only a fold or unfold, through `isPresented`, touches the view graph.
final class InspectorFoldBox {
    var state = InspectorFoldState()

    /// The inspector's new visibility when this width folds or unfolds it; nil leaves it as it is.
    func resize(to width: CGFloat, foldBelow: CGFloat, isPresented: Bool) -> Bool? {
        guard width > 0 else { return nil }
        let next = state.resized(to: width, foldBelow: foldBelow, isPresented: isPresented)
        state = next.state
        return next.isPresented == isPresented ? nil : next.isPresented
    }
}

/// The fold rule, apart from the view so it can be tested.
nonisolated struct InspectorFoldState: Equatable {
    var width: CGFloat?
    var isFolded = false

    /// Room the window needs past the fold point before the inspector comes back, so a drag
    /// that hovers at the edge doesn't flicker it.
    static let returnMargin: CGFloat = 40

    func resized(
        to width: CGFloat,
        foldBelow: CGFloat,
        isPresented: Bool
    ) -> (state: Self, isPresented: Bool) {
        var next = self
        next.width = width
        // Any shrink below the point folds it, so an inspector shown by hand (or pulled out by
        // its divider) at a narrow width stays until the window is made narrower again.
        let isShrinking = width < (self.width ?? .infinity)
        if isPresented, isShrinking, width < foldBelow {
            next.isFolded = true
            return (next, false)
        }
        if isFolded, !isPresented, width >= foldBelow + Self.returnMargin {
            next.isFolded = false
            return (next, true)
        }
        return (next, isPresented)
    }
}

/// Reads and writes a window's remembered inspector visibility while ignoring
/// redundant writes (such as AppKit echoing an automatic fold).
enum InspectorVisibilityStore {
    static func initial(forKey key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func binding(
        _ isPresented: Binding<Bool>,
        key: String,
        defaults: UserDefaults = .standard
    ) -> Binding<Bool> {
        Binding(
            get: { isPresented.wrappedValue },
            set: { visible in
                guard visible != isPresented.wrappedValue else { return }
                isPresented.wrappedValue = visible
                defaults.set(visible, forKey: key)
            }
        )
    }
}

private struct OwnedInspectorAutoFold: ViewModifier {
    @Binding var isPresented: Bool
    let foldBelow: CGFloat
    let host: WeakWindow
    let windowID: ObjectIdentifier?
    @State private var fold = InspectorFoldBox()

    func body(content: Content) -> some View {
        content.modifier(InspectorAutoFold(
            isPresented: $isPresented,
            foldBelow: foldBelow,
            host: host,
            windowID: windowID,
            fold: fold
        ))
    }
}

extension View {
    func inspectorAutoFold(
        isPresented: Binding<Bool>,
        below width: CGFloat,
        host: WeakWindow,
        windowID: ObjectIdentifier?
    ) -> some View {
        modifier(OwnedInspectorAutoFold(
            isPresented: isPresented,
            foldBelow: width,
            host: host,
            windowID: windowID
        ))
    }

    func inspectorAutoFold(
        isPresented: Binding<Bool>,
        below width: CGFloat,
        host: WeakWindow,
        windowID: ObjectIdentifier?,
        fold: InspectorFoldBox
    ) -> some View {
        modifier(InspectorAutoFold(
            isPresented: isPresented,
            foldBelow: width,
            host: host,
            windowID: windowID,
            fold: fold
        ))
    }
}

extension Binding where Value: Equatable {
    /// Drops writes of the value already there. SwiftUI writes some bindings back unchanged on every scene
    /// update (MenuBarExtra's `isInserted` does), and an unchanged write to an `@AppStorage` still changes
    /// UserDefaults: SwiftUI's change log showed it invalidating the Library through its own, unrelated
    /// `@AppStorage("clipboard.libraryShowsList")`, whose layout updated the scene again, in a loop that hung
    /// the app while its inspector folded (sd-kutk).
    func ignoringUnchangedWrites() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { if $0 != wrappedValue { wrappedValue = $0 } })
    }
}
