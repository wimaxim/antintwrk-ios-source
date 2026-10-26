// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Shared by the app and notification extension. Binding is an opaque delivery scope, not a login credential.
nonisolated struct AntintwrkSocialPushBinding: Codable, Equatable, Sendable {
    static let key = "antintwrk.socialPushBinding.v1"
    static let kind = "antintwrk.social.v1"
    let actor: String
    let binding: String
    let language: String
    
    var isValid: Bool {
        actor.range(of: "^@u[1-9][0-9]{0,17}:antintwrk\\.com$", options: .regularExpression) != nil
            && binding.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
            && ["en", "ru", "uk", "de", "es", "fr", "it", "ar", "zh"].contains(language)
    }
    
    static func load(from defaults: UserDefaults?) -> Self? {
        guard let data = defaults?.data(forKey: key), data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid,
              defaults?.string(forKey: "antintwrk.activeMessengerActor") == value.actor else { return nil }
        return value
    }
    
    func matches(_ info: [AnyHashable: Any]) -> Bool {
        isValid && info["kind"] as? String == Self.kind && info["binding"] as? String == binding
    }
}
