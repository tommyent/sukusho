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

    /// `system` is `ProcessInfo.operatingSystemVersionString`, "Version 27.3 (Build 26C5035r)".
    static func report(info: [String: Any], system: String) -> String {
        let name = info["CFBundleName"] as? String ?? "Sukusho"
        let macOS = system.replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
        return "\(name) \(display(info: info).replacingOccurrences(of: "Version ", with: "")), macOS \(macOS)"
    }
}
