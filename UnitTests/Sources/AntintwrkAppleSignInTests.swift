// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Testing

struct AntintwrkAppleSignInTests {
    @Test func optionsAcceptOnlyTheRegisteredNativeClientAndBoundedChallenge() throws {
        let options = AntintwrkAppleOptions(clientId: "com.antintwrk.app", nonce: String(repeating: "n", count: 43), ticket: String(repeating: "a", count: 64))
        #expect(try options.validated().ticket == options.ticket)
    }
    
    @Test(arguments: ["com.antintwrk.web", "org.other.app", "", "com.antintwrk.app.attacker"])
    func optionsRejectOtherAudiences(clientID: String) {
        #expect(throws: (any Error).self) {
            try AntintwrkAppleOptions(clientId: clientID, nonce: String(repeating: "n", count: 43), ticket: String(repeating: "a", count: 64)).validated()
        }
    }
    
    @Test(arguments: ["", String(repeating: "n", count: 42), String(repeating: "n", count: 44), String(repeating: "+", count: 43)])
    func optionsRejectInvalidNonces(nonce: String) {
        #expect(throws: (any Error).self) {
            try AntintwrkAppleOptions(clientId: "com.antintwrk.app", nonce: nonce, ticket: String(repeating: "a", count: 64)).validated()
        }
    }
    
    @Test(arguments: ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "A", count: 64)])
    func optionsRejectInvalidTickets(ticket: String) {
        #expect(throws: (any Error).self) {
            try AntintwrkAppleOptions(clientId: "com.antintwrk.app", nonce: String(repeating: "n", count: 43), ticket: ticket).validated()
        }
    }
    
    @Test func changingAccountFormsDiscardsBothProviderClaims() {
        let model = AntintwrkAppModel()
        model.googleRegistrationTicket = "google"
        model.appleRegistrationTicket = "apple"
        #expect(model.hasProviderRegistration)
        model.switchAccountForm(to: .login)
        #expect(!model.hasProviderRegistration)
    }
}
