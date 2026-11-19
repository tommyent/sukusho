import AppKit
import SwiftUI
import Testing

/// Beta 3: the launch notices are modeless panels. On m1 (beta 2) the unsupported-macOS panel opened off-center and went
/// behind the Library. The panels are built here but never shown.
@MainActor
struct LaunchNoticeTests {
    @Test func aNoticeIsCenteredAtItsOwnSizeAndFloatsOnlyOverSukusho() throws {
        let plain = LaunchNoticePanel(title: "Notice", content: Color.clear.frame(width: 370, height: 180))
        try #require(!NSScreen.screens.isEmpty, "centering needs a display")
        for panel in [plain] {
            #expect(!panel.isVisible)
            #expect(panel.frame.width >= 370 && panel.frame.height >= 180, "sized by its content before centering")
            // Centered at 0×0 it grew out from the screen's middle, its left edge on the center line (m1, beta 2).
            #expect(NSScreen.screens.contains { abs(panel.frame.midX - $0.visibleFrame.midX) <= 1 })
            // In front of the Library; hidden while another app is in front, so it never floats over that app.
            #expect(panel.isFloatingPanel && panel.level == .floating)
            #expect(panel.hidesOnDeactivate)
            #expect(panel.styleMask.contains(.closable) && !panel.isReleasedWhenClosed)
        }
    }
}
