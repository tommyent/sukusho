// The update channels Sparkle is told to allow: none by default, "beta" with Settings › About › Get beta
// updates on. Read from a throwaway defaults domain, never the app's.
import Foundation
import Testing

@Suite struct UpdateChannelsTests {
    @Test func betaIsAllowedOnlyWhenTheSwitchIsOn() throws {
        let name = "SukushoUpdateChannelsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(UpdateChannels.allowed(defaults: defaults).isEmpty)
        defaults.set(true, forKey: UpdateChannels.betaKey)
        #expect(UpdateChannels.allowed(defaults: defaults) == ["beta"])
        defaults.set(false, forKey: UpdateChannels.betaKey)
        #expect(UpdateChannels.allowed(defaults: defaults).isEmpty)
    }
}
