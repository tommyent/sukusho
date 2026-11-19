import AppKit
import SwiftUI
import Testing

/// Beta 3: the launch notices are modeless panels. On m1 (beta 2) the shortcut-clash alert's `runModal` held clipboard
/// history for 20 s and more, and the unsupported-macOS panel opened off-center and went behind the Library. The panels
/// are built here but never shown.
@MainActor
struct LaunchNoticeTests {
    @Test func noticesWaitForBothTheirDeadlineAndAnActiveApp() {
        var notices = LaunchNoticeDelivery()
        let beforeDeadline = notices.takeIfDue(isActive: true)
        #expect(!beforeDeadline)
        notices.isDue = true
        let deliveries = [false, true, true].map { notices.takeIfDue(isActive: $0) }
        #expect(deliveries == [false, true, false])
    }

    private func suite() -> (UserDefaults, String) {
        let name = "LaunchNoticeTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func clashPanel(defaults: UserDefaults, perform: @escaping (ShortcutClashNotice.Answer) -> Void) -> LaunchNoticePanel {
        let clash: SystemScreenshotShortcuts.Clash = (.area, CaptureHotkeyAction.area.defaultShortcut)
        return ShortcutClashNotice.makePanel(clashes: [clash], canUseOtherKeys: true, defaults: defaults, perform: perform)
    }

    @Test func aNoticeIsCenteredAtItsOwnSizeAndFloatsOnlyOverSukusho() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let plain = LaunchNoticePanel(title: "Notice", content: Color.clear.frame(width: 370, height: 180))
        let clash = clashPanel(defaults: defaults) { _ in }
        try #require(!NSScreen.screens.isEmpty, "centering needs a display")
        for panel in [plain, clash] {
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

    @Test func theClashNoticeRecordsAnAnswerOnlyWhenOneIsGiven() {
        for answer in [ShortcutClashNotice.Answer.useOtherKeys, .openKeyboardShortcuts, .notNow] {
            let (defaults, name) = suite()
            defer { defaults.removePersistentDomain(forName: name) }
            var carriedOut: [ShortcutClashNotice.Answer] = []

            // Its close button is no answer: the notice comes back at the next launch.
            var closedRan = false
            let closed = clashPanel(defaults: defaults) { carriedOut.append($0) }
            closed.onClose = { closedRan = true }
            closed.close()
            #expect(closedRan)
            #expect(!defaults.bool(forKey: ShortcutClashNotice.shownKey))
            #expect(carriedOut.isEmpty)

            // Any answer, Not Now included, is recorded, closes the notice and is carried out once.
            var answeredClosed = false
            let answered = clashPanel(defaults: defaults) { _ in }
            answered.onClose = { answeredClosed = true }
            ShortcutClashNotice.answer(answer, closing: answered, defaults: defaults) { carriedOut.append($0) }
            #expect(defaults.bool(forKey: ShortcutClashNotice.shownKey))
            #expect(answeredClosed)
            #expect(carriedOut == [answer])
        }
    }
}
