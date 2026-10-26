// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main
struct ClientConfigurationChecks {
    static func main() throws {
        let configuration = try AntintwrkClientConfiguration(productVersion: "1.0.26")
        precondition(configuration.socialUserAgent == "ANTINTWRK iOS native-client/1.0 app/1.0.26 (+https://qwertynetworks.com)")
        for version in ["", "1..2", "1.2.3.4", "1.0R", "1\r\nX-Injected: yes", "１.２"] {
            do {
                _ = try AntintwrkClientConfiguration(productVersion: version)
                preconditionFailure("Accepted an invalid product version")
            } catch AntintwrkClientConfiguration.ConfigurationError.invalidProductVersion { }
        }
        let fixtures: [(String, Bool)] = [
            ("https://antimsg.com/en/", true),
            ("https://antimsg.com:443/ru/profile", true),
            ("https://antimsg.com/en/profile?next=/goto", true),
            ("https://antimsg.com/goto", false),
            ("https://antimsg.com/en/goto/123", false),
            ("https://antimsg.com/ru/go/123", false),
            ("https://antimsg.com/%67o/123", false),
            ("https://antimsg.com/government", true),
            ("https://antintwrk.com/en/", false),
            ("https://antimsg.com.attacker.example/en/", false),
            ("https://attacker.example/?site=antimsg.com", false),
            ("http://antimsg.com/en/", false),
            ("https://antimsg.com:8443/en/", false),
            ("https://user:secret@antimsg.com/en/", false)
        ]
        for (rawURL, expected) in fixtures {
            guard let url = URL(string: rawURL) else { preconditionFailure("Invalid fixture URL") }
            precondition(configuration.mayLoadEmbedded(url, origin: .russian) == expected,
                         "Unexpected route policy for \(rawURL)")
        }
        precondition(configuration.mayLoadEmbedded(URL(string: "https://antintwrk.com/zh/")!, origin: .global))
        precondition(!configuration.mayLoadEmbedded(URL(string: "https://antimsg.com/zh/")!, origin: .global))
        precondition(AntintwrkClientConfiguration.SocialOrigin.russian.versionSuffix == "R")
        precondition(AntintwrkClientConfiguration.SocialOrigin.global.versionSuffix == "G")
        try checkSocialRoutes(configuration: configuration)
        FileHandle.standardOutput.write(Data("ANTINTWRK client configuration: User-Agent, version validation and 16 route fixtures passed.\n".utf8))
    }
    
    static func checkSocialRoutes(configuration: AntintwrkClientConfiguration) throws {
        let policy = AntintwrkSocialWebPolicy(origin: .russian, configuration: configuration)
        func url(_ path: String) -> URL {
            guard let url = URL(string: "https://antimsg.com\(path)") else { preconditionFailure("Invalid fixture") }
            return url
        }
        for path in ["/en/hero-feed", "/ru/communities", "/zh/profile", "/ar/people", "/de/support", "/en/hero/18"] {
            precondition(policy.embeddedURL(url(path)) != nil)
        }
        for path in ["/go.html", "/en/goto/123", "/ru/go/123", "/unknown/hero-feed", "/en/admin",
                     "/en/hero-feed?auth=1", "/en/profile?app_ref=secret", "/en/hero/logoff"] {
            precondition(policy.embeddedURL(url(path)) == nil)
        }
        precondition(policy.section(url("/en/hero-feed")) == .feed)
        precondition(policy.section(url("/en/communities")) == .communities)
        precondition(policy.section(url("/en/profile")) == .profile)
        for path in ["/en/people", "/en/support", "/en/hero/18", "/en/communities/child"] {
            precondition(policy.section(url(path)) == nil)
        }
        precondition(policy.messengerDestination(url("/en/messages")) == .chats)
        precondition(policy.messengerDestination(url("/en/messages?with=18")) == .user("18"))
        precondition(policy.messengerDestination(url("/en/messages/abcdefghijklmnop")) == .legacyRoom("abcdefghijklmnop"))
        for path in ["/en/messages?with=18&with=19", "/en/messages?with=0", "/en/messages?with=01",
                     "/en/messages?with=-1", "/en/messages?with=", "/en/messages?with=１８",
                     "/en/messages?with=1234567890123456789", "/en/messages/short",
                     "/en/messages/abcdefghijklmnop?with=18", "/en/messages?with=18&auth=1"] {
            precondition(policy.messengerDestination(url(path)) == nil)
            precondition(policy.embeddedURL(url(path)) == nil)
        }
        guard let embedded = policy.embeddedURL(url("/en/hero-feed?app=0&app=2&filter=recent&filter=mine")),
              let components = URLComponents(url: embedded, resolvingAgainstBaseURL: false) else {
            preconditionFailure("Missing normalized embedded URL")
        }
        precondition(components.queryItems?.filter { $0.name == "app" } == [URLQueryItem(name: "app", value: "1")])
        precondition(components.queryItems?.filter { $0.name == "filter" }.count == 2)
        guard let otherOrigin = URL(string: "https://antintwrk.com/en/messages?with=18") else { preconditionFailure("Invalid fixture") }
        precondition(policy.messengerDestination(otherOrigin) == nil)
        FileHandle.standardOutput.write(Data("ANTINTWRK social routes: section isolation, messenger intent validation and query preservation passed.\n".utf8))
    }
}
