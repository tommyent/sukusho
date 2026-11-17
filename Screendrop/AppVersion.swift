//
//  AppVersion.swift
//  Screendrop
//

import Foundation

/// The app's version as shown in Settings and About, and as copied for a bug report.
nonisolated enum AppVersion {
    static let displayString = display(info: Bundle.main.infoDictionary ?? [:])

    /// What the copy button puts on the clipboard: the app, its version and build, and the
    /// macOS it runs on, since a bug report needs all of them.
    static let reportString = report(info: Bundle.main.infoDictionary ?? [:],
                                     system: ProcessInfo.processInfo.operatingSystemVersionString)

    static func display(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0"
        guard let build = info["CFBundleVersion"] as? String else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    /// The macOS this build is made and tested on. Below it, launch shows a notice that some
    /// features may be missing; on it or anything newer, betas included, nothing.
    static let testedMacOSMajor = 27

    /// "26.5.1", or "26.5" without a patch.
    static func macOSString(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// The notice shows below the tested macOS until it's dismissed for that exact version.
    static func showsUnsupportedNotice(on version: OperatingSystemVersion, dismissedFor: String?) -> Bool {
        version.majorVersion < testedMacOSMajor && dismissedFor != macOSString(version)
    }

    /// `system` is `ProcessInfo.operatingSystemVersionString`, "Version 27.3 (Build 26C5035r)".
    static func report(info: [String: Any], system: String) -> String {
        let name = info["CFBundleName"] as? String ?? "Sukusho"
        let macOS = system.replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
        return "\(name) \(display(info: info).replacingOccurrences(of: "Version ", with: "")), macOS \(macOS)"
    }
}
