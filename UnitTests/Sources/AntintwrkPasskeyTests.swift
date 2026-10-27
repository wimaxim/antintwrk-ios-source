// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Foundation
import Testing

struct AntintwrkPasskeyTests {
    @Test func unavailableSigningContextDoesNotOfferBrokenPlatformLogin() {
        #expect(!AntintwrkClientConfiguration.canOfferPasskeys(enabled: true, signingTeam: nil))
        #expect(!AntintwrkClientConfiguration.canOfferPasskeys(enabled: true, signingTeam: "SIMULATOR"))
        #expect(!AntintwrkClientConfiguration.canOfferPasskeys(enabled: true, signingTeam: "OTHERTEAM"))
        #expect(!AntintwrkClientConfiguration.canOfferPasskeys(enabled: false, signingTeam: "FBV226YGHR"))
        #expect(AntintwrkClientConfiguration.canOfferPasskeys(enabled: true, signingTeam: "FBV226YGHR"))
    }
    
    private var validOptions: [String: Any] {
        ["rpId": "antintwrk.com", "challenge": String(repeating: "A", count: 43),
         "allowCredentials": [["type": "public-key", "id": "AQID"]]]
    }
    
    private var valid: [String: Any] {
        ["ticket": String(repeating: "a", count: 64), "options": validOptions]
    }
    
    @Test func acceptsCanonicalOptionsAndDiscoverableCredentials() throws {
        let options = try AntintwrkPasskeyOptions(valid)
        #expect(options.allowed == [Data([1, 2, 3])])
        #expect(options.challenge.count == 32)
        var input = valid
        input["options"] = ["rpId": "antintwrk.com", "challenge": String(repeating: "A", count: 43)]
        #expect(try AntintwrkPasskeyOptions(input).allowed.isEmpty)
    }
    
    @Test(arguments: ["antimsg.com", "evil.antintwrk.com", "antintwrk.com.evil.test", "https://antintwrk.com", ""])
    func rejectsForeignRelyingParties(rp: String) {
        var input = valid
        var options = validOptions
        options["rpId"] = rp; input["options"] = options
        #expect(throws: (any Error).self) { try AntintwrkPasskeyOptions(input) }
    }
    
    @Test(arguments: ["", "AA", String(repeating: "A", count: 2049), "invalid+encoding="])
    func rejectsInvalidChallenges(challenge: String) {
        var input = valid
        var options = validOptions
        options["challenge"] = challenge; input["options"] = options
        #expect(throws: (any Error).self) { try AntintwrkPasskeyOptions(input) }
    }
    
    @Test func rejectsInvalidTicketsAndCredentialDescriptors() {
        var input = valid
        input["ticket"] = String(repeating: "A", count: 64)
        #expect(throws: (any Error).self) { try AntintwrkPasskeyOptions(input) }
        input = valid
        var options = validOptions
        for descriptors in [[["type": "password", "id": "AQID"]],
                            [["type": "public-key", "id": ""]],
                            Array(repeating: ["type": "public-key", "id": "AQID"], count: 65)] {
            options["allowCredentials"] = descriptors; input["options"] = options
            #expect(throws: (any Error).self) { try AntintwrkPasskeyOptions(input) }
        }
        options["allowCredentials"] = "invalid descriptor list"; input["options"] = options
        #expect(throws: (any Error).self) { try AntintwrkPasskeyOptions(input) }
    }
}
