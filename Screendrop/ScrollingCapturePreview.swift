//
//  ScrollingCapturePreview.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// The live preview of a Scrolling Capture: the whole capture so far, scaled to fit a strip
/// beside the region, growing as the page is scrolled. It takes no clicks and is left out of
/// every capture, like the bar.
struct ScrollingCapturePreview: View {
    /// The strip's width in points, and the widest the shrunk capture is made, in pixels.
    static let width: CGFloat = 132
    static let pixelWidth = 320
    static let margin: CGFloat = 12

    @State private var presenter = ScrollingCapturePresenter.shared

    var body: some View {
        VStack(spacing: 0) {
            if let image = presenter.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 5))
                    .padding(5)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Self.margin)
        .accessibilityHidden(true)
    }

    /// The strip's panel: right of the region, else left of it; nil when neither side has room.
    /// It starts at the region's bottom edge and is at least `minimumHeight` tall where the
    /// screen allows, unless that would run over the bar (`avoiding`).
    static func makePanel(beside rect: CGRect, on screen: NSScreen?, avoiding bar: CGRect?) -> NSPanel? {
        guard let frame = ScrollingCapturePreviewPlacement.frame(beside: rect, visible: screen?.visibleFrame ?? rect,
                                                                 avoiding: bar, width: width + margin * 2) else { return nil }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingView = NSHostingView(rootView: ScrollingCapturePreview())
        // The panel sets the size and the hosting view follows, as in the bar's panel.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = hostingView
        return panel
    }
}
