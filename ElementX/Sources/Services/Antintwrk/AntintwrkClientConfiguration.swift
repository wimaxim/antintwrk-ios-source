// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkClientConfiguration {
    enum SocialOrigin: String {
        case russian = "https://antimsg.com"
        case global = "https://antintwrk.com"
        
        var versionSuffix: String {
            self == .russian ? "R" : "G"
        }
    }
    
    enum ConfigurationError: Error {
        case invalidProductVersion
    }
    
    static let supportedLanguages = ["en", "ru", "uk", "de", "es", "fr", "it", "ar", "zh"]
    static let messengerOrigin = URL(string: "https://matrix.antimsg.com")!
    static let nativeOrigin = URL(string: "https://antimsg.com")!
    static let geographyURL = URL(string: "https://antimsg.com/app/geo")!
    
    var passkeysAvailable: Bool {
        Self.canOfferPasskeys(enabled: Bundle.main.object(forInfoDictionaryKey: "ANTINTWRK_PASSKEY_ENABLED") as? Bool == true,
                              signingTeam: Bundle.main.object(forInfoDictionaryKey: "ANTINTWRK_SIGNING_TEAM") as? String)
    }
    
    // Presentation policy only; Apple validates the signed entitlement and domain association.
    static func canOfferPasskeys(enabled: Bool, signingTeam: String?) -> Bool {
        enabled && signingTeam == "FBV226YGHR"
    }
    
    let productVersion: String
    
    var socialUserAgent: String {
        "ANTINTWRK iOS native-client/1.0 app/\(productVersion) (+https://qwertynetworks.com)"
    }
    
    init(productVersion: String) throws {
        let parts = productVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            throw ConfigurationError.invalidProductVersion
        }
        self.productVersion = productVersion
    }
    
    func mayLoadEmbedded(_ url: URL, origin: SocialOrigin) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == URL(string: origin.rawValue)?.host,
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil else { return false }
        
        var path = components.path.split(separator: "/").map(String.init)
        if let language = path.first, Self.supportedLanguages.contains(language) {
            path.removeFirst()
        }
        return path.first.map { !["go", "goto", "go.html"].contains($0) } ?? true
    }
}
