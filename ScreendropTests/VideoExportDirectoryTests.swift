import Foundation
import Testing

/// Owner, 2026-11-17: videos go to ~/Movies/Sukusho and images stay in ~/Pictures/Sukusho, unless the user chose a
/// Save folder, which then takes both.
@MainActor
struct VideoExportDirectoryTests {
    private func withSaveFolder(_ path: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var domain = previous
        domain[ScreendropPreferences.exportDirectoryPathKey] = path ?? ""
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        body()
    }

    @Test func videosGoToMoviesUnlessAFolderIsChosen() {
        withSaveFolder(nil) {
            #expect(ScreendropPreferences.videoExportDirectory.deletingLastPathComponent().lastPathComponent == "Movies")
            #expect(ScreendropPreferences.exportDirectory.deletingLastPathComponent().lastPathComponent == "Pictures")
            #expect(ScreendropPreferences.videoExportDirectory.lastPathComponent
                    == ScreendropPreferences.exportDirectory.lastPathComponent)
        }
        withSaveFolder("/tmp/Chosen") {
            #expect(ScreendropPreferences.videoExportDirectory.path == "/tmp/Chosen")
            #expect(ScreendropPreferences.exportDirectory.path == "/tmp/Chosen")
        }
    }
}
