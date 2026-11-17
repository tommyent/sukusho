import Foundation
import Testing

@Suite
struct AppVersionTests {
    @Test func theCopiedLineNamesTheAppItsBuildAndTheSystem() {
        let info: [String: Any] = ["CFBundleName": "Sukusho", "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "32.261110.1244"]
        #expect(AppVersion.display(info: info) == "Version 1.2.0 (32.261110.1244)")
        #expect(AppVersion.report(info: info, system: "Version 27.3 (Build 26C5035r)")
            == "Sukusho 1.2.0 (32.261110.1244), macOS 27.3 (26C5035r)")
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "1.2.0"]) == "Version 1.2.0")
        #expect(AppVersion.report(info: [:], system: "Version 27.0") == "Sukusho 0.0, macOS 27.0")
    }

    /// Below macOS 27 launch warns, until dismissed for that exact version; 27 and later,
    /// betas included, never (sd: older macOS, 2026-11-16).
    @Test func theUnsupportedNoticeShowsOnlyBelowTheTestedMacOS() {
        func os(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
        }
        #expect(AppVersion.macOSString(os(26, 5, 1)) == "26.5.1")
        #expect(AppVersion.macOSString(os(26, 4, 0)) == "26.4")
        #expect(AppVersion.showsUnsupportedNotice(on: os(26, 5, 1), dismissedFor: nil))
        #expect(!AppVersion.showsUnsupportedNotice(on: os(26, 5, 1), dismissedFor: "26.5.1"))
        #expect(AppVersion.showsUnsupportedNotice(on: os(26, 6, 0), dismissedFor: "26.5.1"), "a new macOS asks again")
        #expect(!AppVersion.showsUnsupportedNotice(on: os(27, 0, 0), dismissedFor: nil))
        #expect(!AppVersion.showsUnsupportedNotice(on: os(27, 3, 0), dismissedFor: nil))
        #expect(!AppVersion.showsUnsupportedNotice(on: os(28, 0, 0), dismissedFor: nil))
    }
}
