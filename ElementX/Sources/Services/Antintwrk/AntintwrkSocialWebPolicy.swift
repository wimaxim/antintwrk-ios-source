// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkSocialWebPolicy {
    enum Section {
        case feed
        case communities
        case profile
    }
    
    enum MessengerDestination: Equatable, CustomStringConvertible {
        case chats
        case user(String)
        case legacyRoom(String)
        
        var description: String {
            switch self {
            case .chats: "chats"
            case .user: "user"
            case .legacyRoom: "legacyRoom"
            }
        }
    }
    
    private static let routes: Set = [
        "hero-feed", "hero", "channel", "group", "discover", "reels", "stories", "hero-compose",
        "communities", "create-community", "communities-people", "profile", "deleteaccount",
        "notifications", "friend-requests", "people", "messages", "monetization", "my-referrals",
        "kindness", "support-project", "ukraine", "how-it-works", "sms-consent", "about", "contacts",
        "support", "terms", "useragreement", "privacy", "privacypolicy", "dmca", "community",
        "safety", "verification"
    ]
    
    let origin: AntintwrkClientConfiguration.SocialOrigin
    private let configuration: AntintwrkClientConfiguration
    
    init(origin: AntintwrkClientConfiguration.SocialOrigin, configuration: AntintwrkClientConfiguration) {
        self.origin = origin
        self.configuration = configuration
    }
    
    func embeddedURL(_ url: URL) -> URL? {
        guard configuration.mayLoadEmbedded(url, origin: origin),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        guard path.count >= 2,
              AntintwrkClientConfiguration.supportedLanguages.contains(path[0]),
              Self.routes.contains(path[1]),
              !path.contains(where: { ["activitycheck", "g2fa", "logoff"].contains($0) }),
              !query.contains(where: { ["auth", "app_ref"].contains($0.name) }) else { return nil }
        if path[1] == "messages", messengerDestination(url) == nil {
            return nil
        }
        components.queryItems = query.filter { $0.name != "app" } + [URLQueryItem(name: "app", value: "1")]
        return components.url
    }
    
    /// Scoped assistance referrals retain the immutable signed gift policy.
    func assistanceURL(_ value: String) -> URL? {
        guard value.utf8.count <= 1800, let url = URL(string: value),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard path.count >= 2, AntintwrkClientConfiguration.supportedLanguages.contains(path[0]) else { return nil }
        let query = parts.queryItems ?? []
        let signed: String?
        if parts.host == "antintwrk.com", path.count == 2, path[1] == "ukraine", query.count == 1, query[0].name == "app_ref" {
            signed = query[0].value
        } else if (parts.host == "cerebralpalsycommunity.org" && path.count == 2 && path[1] == "give") ||
            (parts.host == "helpcp.org" && path.count == 3 && path[1] == "help" && path[2] == "davidnewman"),
            query.count == 2, Set(query.map(\.name)) == ["source", "ref"], query.first(where: { $0.name == "source" })?.value == "heroworld" {
            signed = query.first(where: { $0.name == "ref" })?.value
        } else {
            return nil
        }
        guard signed?.range(of: "^[A-Za-z0-9_-]{1,1456}\\.[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
        return url
    }
    
    func appleBillingURL(_ value: String) -> URL? {
        guard ["https://apps.apple.com/account/subscriptions", "https://reportaproblem.apple.com/"].contains(value) else { return nil }
        return URL(string: value)
    }
    
    func legalReaderURL(_ url: URL) -> URL? {
        guard configuration.mayLoadEmbedded(url, origin: origin),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.count == 2, AntintwrkClientConfiguration.supportedLanguages.contains(path[0]),
              ["terms", "useragreement", "privacy", "privacypolicy"].contains(path[1]) else { return nil }
        components.queryItems = [URLQueryItem(name: "native_legal", value: "1")]
        components.fragment = nil
        return components.url
    }
    
    func section(_ url: URL) -> Section? {
        guard embeddedURL(url) != nil else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count == 2 else { return nil }
        switch path[1] {
        case "hero-feed": return .feed
        case "communities": return .communities
        case "profile": return .profile
        default: return nil
        }
    }
    
    func messengerDestination(_ url: URL) -> MessengerDestination? {
        guard configuration.mayLoadEmbedded(url, origin: origin),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard (2...3).contains(path.count),
              AntintwrkClientConfiguration.supportedLanguages.contains(path[0]), path[1] == "messages" else { return nil }
        let query = components.queryItems ?? []
        guard !query.contains(where: { ["auth", "app_ref"].contains($0.name) }) else { return nil }
        let recipients = query.filter { $0.name == "with" }
        if path.count == 3 {
            guard recipients.isEmpty, (16...128).contains(path[2].count),
                  path[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            return .legacyRoom(path[2])
        }
        if recipients.isEmpty {
            return .chats
        }
        guard recipients.count == 1, let recipient = recipients[0].value,
              (1...18).contains(recipient.count), recipient.first != "0",
              recipient.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return .user(recipient)
    }
}
