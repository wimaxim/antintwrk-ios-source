// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@preconcurrency import KeychainAccess
import SwiftUI

struct AntintwrkPersistedSocialCookies: Codable {
    struct Cookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let expires: Date?
        
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            secure = true; httpOnly = cookie.isHTTPOnly; expires = cookie.expiresDate
        }
        
        var restored: HTTPCookie? {
            guard secure, expires.map({ $0 > Date() }) ?? true else { return nil }
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard ["antimsg.com", "antintwrk.com"].contains(host) else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
            if httpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let expires {
                properties[.expires] = expires
            }
            return HTTPCookie(properties: properties)
        }
    }
    
    let actor: String
    let cookies: [Cookie]
    var custodyVerified: Bool?
}

@MainActor
protocol AntintwrkSocialCookieVaultProtocol {
    func load() throws -> AntintwrkPersistedSocialCookies?
    func store(_ value: AntintwrkPersistedSocialCookies) throws
    func clear() throws
}

@MainActor
final class AntintwrkSocialCookieVault: AntintwrkSocialCookieVaultProtocol {
    private let keychain = Keychain(service: InfoPlistReader.main.baseBundleIdentifier + ".social-session", accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        .accessibility(.afterFirstUnlockThisDeviceOnly)
    func load() throws -> AntintwrkPersistedSocialCookies? {
        guard let data = try keychain.getData("cookies"), data.count <= 65536 else { return nil }
        let result = try JSONDecoder().decode(AntintwrkPersistedSocialCookies.self, from: data)
        guard result.actor.range(of: "^@u[1-9][0-9]{0,17}:antintwrk\\.com$", options: .regularExpression) != nil, result.cookies.count <= 64 else { return nil }
        return result
    }
    
    func store(_ value: AntintwrkPersistedSocialCookies) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65536, value.cookies.count <= 64 else { throw AntintwrkSocialClient.Failure.invalidResponse }
        try keychain.set(data, key: "cookies")
    }
    
    func clear() throws {
        try keychain.remove("cookies")
    }
}
