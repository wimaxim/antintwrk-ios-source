// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Foundation
import Testing

struct AntintwrkSocialPushPolicyTests {
    @Test func loginScopeAndPayloadMustBothMatch() throws {
        let suite = "antintwrk.push.qa." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let binding = AntintwrkSocialPushBinding(actor: "@u42:antintwrk.com", binding: String(repeating: "a", count: 32), language: "ru")
        try defaults.set(JSONEncoder().encode(binding), forKey: AntintwrkSocialPushBinding.key)
        #expect(AntintwrkSocialPushBinding.load(from: defaults) == nil)
        defaults.set(binding.actor, forKey: "antintwrk.activeMessengerActor")
        let loaded = try #require(AntintwrkSocialPushBinding.load(from: defaults))
        #expect(loaded.matches(["kind": AntintwrkSocialPushBinding.kind, "binding": binding.binding]))
        #expect(!loaded.matches(["kind": AntintwrkSocialPushBinding.kind, "binding": String(repeating: "b", count: 32)]))
        #expect(!loaded.matches(["binding": binding.binding]))
        defaults.set("@u43:antintwrk.com", forKey: "antintwrk.activeMessengerActor")
        #expect(AntintwrkSocialPushBinding.load(from: defaults) == nil)
        defaults.removeObject(forKey: "antintwrk.activeMessengerActor")
        #expect(AntintwrkSocialPushBinding.load(from: defaults) == nil)
    }
    
    @Test(arguments: ["", "@u0:antintwrk.com", "@u42:other.invalid", "@u42:antintwrk.com.evil", "@u42:antintwrk.com\n"])
    func malformedActorIsRejected(_ actor: String) {
        #expect(!AntintwrkSocialPushBinding(actor: actor, binding: String(repeating: "a", count: 32), language: "en").isValid)
    }
    
    @Test(arguments: ["en", "ru", "uk", "de", "es", "fr", "it", "ar", "zh"])
    func everyLocaleHasBothPushTables(_ language: String) throws {
        let locale = language == "zh" ? "zh-Hans" : language
        let url = try #require(Bundle.app.url(forResource: locale, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        for key in ["title", "new", "device", "failed", "loading", "categories", "friends", "messages", "comments", "votes", "important"] {
            let name = "screen_ant_push_" + key
            #expect(bundle.localizedString(forKey: name, value: nil, table: "AntintwrkIOS") != name)
        }
        let localizable = try Data(contentsOf: #require(bundle.url(forResource: "Localizable", withExtension: "strings")))
        let values = try #require(PropertyListSerialization.propertyList(from: localizable, format: nil) as? [String: String])
        #expect(values["Notification"]?.isEmpty == false)
    }
}
