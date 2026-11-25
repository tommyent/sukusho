//
//  CommandPalettePanel.swift
//  Screendrop
//
//  The command palette's window: borderless, a child of the window it opens over, and able to hold the keyboard for
//  its field. The tests compile this file.
//

import AppKit

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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
