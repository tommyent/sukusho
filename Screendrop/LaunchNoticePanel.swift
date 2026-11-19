//
//  LaunchNoticePanel.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// The window of a notice Sukusho shows at launch: the unsupported-macOS notice and the shortcut clash. It's modeless,
/// so clipboard history, the Library and its Copy keep working while it waits; a modal alert held copies for 20 s and
/// more (m1, beta 2). It floats in front of Sukusho's own windows, the Library included, and hides while another app is
/// in front, so it never covers that app; it comes back with Sukusho.
final class LaunchNoticePanel: NSPanel {
    /// Runs once the notice has closed, by one of its buttons or its close button.
    var onClose: (() -> Void)?

    convenience init(title: String, content: some View) {
        self.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        self.title = title
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = true
        let host = NSHostingController(rootView: content)
        contentViewController = host
        // Sized by its content before it's centered: centered at 0×0, it grew out from the screen's middle (m1, beta 2).
        // Asking for the fitting size makes SwiftUI measure now; layoutIfNeeded() alone left the window 0 wide.
        setContentSize(host.view.fittingSize)
        center()
    }

    override func close() {
        super.close()
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}
