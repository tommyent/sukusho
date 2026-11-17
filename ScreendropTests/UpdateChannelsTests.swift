// The update channels Sparkle is told to allow: "beta" with Settings › About › Get beta updates on. Until the
// person chooses, the switch is on only in a beta build. Read from a throwaway defaults domain, never the app's.
import Foundation
import Testing

@Suite struct UpdateChannelsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "SukushoUpdateChannelsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func betaIsAllowedOnlyWhenTheSwitchIsOn() throws {
        try withDefaults { defaults in
            #expect(UpdateChannels.allowed(defaults: defaults, version: "1.3.0").isEmpty)
            defaults.set(true, forKey: UpdateChannels.betaKey)
            #expect(UpdateChannels.allowed(defaults: defaults, version: "1.3.0") == ["beta"])
            defaults.set(false, forKey: UpdateChannels.betaKey)
            #expect(UpdateChannels.allowed(defaults: defaults, version: "1.3.0").isEmpty)
        }
    }

    /// The owner, 2026-11-17: on by default in a beta build, off in a regular one, and a choice always wins.
    @Test func theDefaultFollowsTheBuildAndAChoiceWins() throws {
        try withDefaults { defaults in
            // Nothing stored: a beta build is on, a regular build is off, and neither writes anything.
            #expect(UpdateChannels.getsBetas(defaults: defaults, version: "1.3.0 beta 1"))
            #expect(!UpdateChannels.getsBetas(defaults: defaults, version: "1.3.0"))
            #expect(defaults.object(forKey: UpdateChannels.betaKey) == nil)

            // Turned off on a beta: stays off.
            defaults.set(false, forKey: UpdateChannels.betaKey)
            #expect(!UpdateChannels.getsBetas(defaults: defaults, version: "1.3.0 beta 1"))
            #expect(UpdateChannels.allowed(defaults: defaults, version: "1.3.0 beta 2").isEmpty)

            // Turned on, then updated to a regular release: stays on.
            defaults.set(true, forKey: UpdateChannels.betaKey)
            #expect(UpdateChannels.getsBetas(defaults: defaults, version: "1.3.0"))
            #expect(UpdateChannels.allowed(defaults: defaults, version: "1.4.0") == ["beta"])
        }
    }

    /// Only the shape scripts/release.sh stamps counts as a beta.
    @Test func aBetaIsTheReleaseScriptsVersionShape() {
        #expect(UpdateChannels.isBeta("1.3.0 beta 1"))
        #expect(UpdateChannels.isBeta("1.3.0 beta 12"))
        for version in ["1.3.0", "1.3.0-beta.1", "beta", "1.3.0 beta", "1.3.0 Beta 1", "", nil] as [String?] {
            #expect(!UpdateChannels.isBeta(version))
        }
    }
}
