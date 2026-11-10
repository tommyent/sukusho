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
}
