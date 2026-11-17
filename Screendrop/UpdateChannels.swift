//
//  UpdateChannels.swift
//  Screendrop
//
//  Which of the feed's channels this copy takes. Sparkle offers an appcast
//  item marked <sparkle:channel>beta</sparkle:channel> only to an updater
//  that allows "beta"; items without a channel, the regular releases, reach
//  everyone, so a copy on the beta channel still gets every stable release.
//

import Foundation

nonisolated enum UpdateChannels {
    /// Settings › About › Get beta updates.
    static let betaKey = "getBetaUpdates"
    /// The channel name scripts/release.sh gives a beta's appcast item.
    static let beta = "beta"

    /// The channels allowed besides the default one. Read at each check, so the switch needs no relaunch.
    static func allowed(defaults: UserDefaults = .standard, version: String? = runningVersion) -> Set<String> {
        getsBetas(defaults: defaults, version: version) ? [beta] : []
    }

    /// The switch: what the person chose, either way, and until they choose, on only in a beta build (owner,
    /// 2026-11-17). Nothing is written, so a later regular release never changes a stored choice.
    static func getsBetas(defaults: UserDefaults = .standard, version: String? = runningVersion) -> Bool {
        defaults.object(forKey: betaKey) as? Bool ?? isBeta(version)
    }

    /// A beta's version exactly as scripts/release.sh's BETA mode stamps it: "1.3.0 beta 1", an ASCII x.y.z and a
    /// counter from 1, as BETA=<1-> allows (Sol, round 3: `\d` also took "beta 0", other scripts' digits and "1 beta 1").
    static func isBeta(_ version: String?) -> Bool {
        version?.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+ beta [1-9][0-9]*$"#, options: .regularExpression) != nil
    }

    static var runningVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
}
