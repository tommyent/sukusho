//
//  CommandPalettePanel.swift
//  Screendrop
//
//  The command palette's window: borderless, a child of the window it opens over, and able to hold the keyboard for
//  its field. The tests compile this file.
//

import AppKit

/// Runs its action once on the main queue's next turn, however often it's asked before then: never inside the layout
/// pass that asked, where AppKit throws if a view's constraints change (the 2026-11-25 crash).
@MainActor
final class PaletteDeferredUpdate {
    private let action: () -> Void
    private var isScheduled = false

    init(_ action: @escaping () -> Void) { self.action = action }

    func request() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.action()
        }
    }
}

final class CommandPalettePanel: NSPanel {
    static let width: CGFloat = 600

    var onResign: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        hidesOnDeactivate = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // The window server's shadow, from the palette's own shape, as the ⌃⌘V popup has.
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        setAccessibilityLabel("Command palette")
        // In captures as the window under it is: Settings' "Include Sukusho windows in captures" decides for Sukusho's
        // own, and other apps see it. A private window is left out of every capture (m1's pass, 2026-11-25).
        PreviewWindowCaptureExclusion.shared.register(window: self)
    }

    /// Where the panel goes: under the window's toolbar, centered on it, inside the window's height, and always inside
    /// the screen it's on. A window partly off the screen, across two displays, or low on it would put the list out of
    /// sight (Sol's reviews): the list is never shorter than 220 pt, and the panel rises over the toolbar to fit it.
    static func place(height: CGFloat, windowFrame: NSRect, contentTop: CGFloat, contentHeight: CGFloat,
                      visible: NSRect?) -> (rect: NSRect, maxHeight: CGFloat) {
        let margin: CGFloat = 8, shortest: CGFloat = 220
        var top = contentTop - margin
        var x = windowFrame.midX - width / 2
        var maxHeight = max(shortest, contentHeight - 24)
        if let visible {
            x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
            maxHeight = min(maxHeight, max(shortest, top - visible.minY - margin), visible.height - 2 * margin)
            let shown = min(height, maxHeight)
            top = min(max(top, visible.minY + margin + shown), visible.maxY - margin)
        }
        let shown = min(height, maxHeight)
        return (NSRect(x: x, y: top - shown, width: width, height: shown), maxHeight)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
