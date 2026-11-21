//
//  InspectorAutoFold.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Folds an inspector away on its own whenever its window is made narrower while below `foldBelow`,
/// so the window can keep getting narrower, and brings it back once there is room again, unless
/// someone hid it themselves in the meantime. Read the window frame only after initial placement.
struct InspectorAutoFold: ViewModifier {
    @Binding var isPresented: Bool
    let foldBelow: CGFloat
    let window: NSWindow?
    let onlyDuringLiveResize: Bool

    @State private var state = InspectorFoldState()

    func body(content: Content) -> some View {
        content
            .onChange(of: window, initial: true) { _, window in
                if let window { resize(in: window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
                if let window, notification.object as? NSWindow === window { resize(in: window) }
            }
            .onChange(of: isPresented) { _, presented in
                // Shown by hand while folded: it stays until the next fold.
                if presented { state.isFolded = false }
            }
    }

    private func resize(in window: NSWindow) {
        let width = window.frame.width
        guard width > 0 else { return }
        let next = state.resized(
            to: width,
            foldBelow: foldBelow,
            isPresented: isPresented,
            canFold: !onlyDuringLiveResize || window.inLiveResize
        )
        guard next.state != state else { return }
        state = next.state
        if next.isPresented != isPresented {
            withAnimation(.snappy(duration: 0.2)) { isPresented = next.isPresented }
        }
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
        isPresented: Bool,
        canFold: Bool = true
    ) -> (state: Self, isPresented: Bool) {
        var next = self
        next.width = width
        // Any shrink below the point folds it, so an inspector shown by hand (or pulled out by
        // its divider) at a narrow width stays until the window is made narrower again.
        let isShrinking = width < (self.width ?? .infinity)
        if canFold, isPresented, isShrinking, width < foldBelow {
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

extension View {
    func inspectorAutoFold(
        isPresented: Binding<Bool>,
        below width: CGFloat,
        window: NSWindow?,
        onlyDuringLiveResize: Bool = false
    ) -> some View {
        modifier(InspectorAutoFold(
            isPresented: isPresented,
            foldBelow: width,
            window: window,
            onlyDuringLiveResize: onlyDuringLiveResize
        ))
    }
}
