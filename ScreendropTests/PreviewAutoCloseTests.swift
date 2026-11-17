import Foundation
import Testing

/// Fable #2: preview cards close by themselves unless the user chose otherwise.
@MainActor
struct PreviewAutoCloseTests {
    /// Sets the auto-close preference in UserDefaults' argument domain, in memory only, for `body`. Nil leaves it unset
    /// there; the persistent domain of the test process isn't touched.
    private func withAutoClose(_ value: Int?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var domain = previous
        domain[ScreendropPreferences.previewAutoCloseSecondsKey] = value
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        body()
    }

    @Test func cardsCloseAfterTenSecondsUnlessTheUserChose() {
        // The test process has no stored choice, so the default shows through.
        if UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[ScreendropPreferences.previewAutoCloseSecondsKey] == nil {
            withAutoClose(nil) { #expect(ScreendropPreferences.previewAutoCloseSeconds == 10) }
        }
        withAutoClose(0) { #expect(ScreendropPreferences.previewAutoCloseSeconds == 0) }
        withAutoClose(30) { #expect(ScreendropPreferences.previewAutoCloseSeconds == 30) }
    }
}
