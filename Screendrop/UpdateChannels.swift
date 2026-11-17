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
    static func allowed(defaults: UserDefaults = .standard) -> Set<String> {
        defaults.bool(forKey: betaKey) ? [beta] : []
    }
}
