// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import GoogleSignIn
import SwiftUI

struct AntintwrkGoogleOptions: Decodable {
    let clientId: String
    let nonce: String
    let ticket: String
    
    func validated(serverClientID: String) throws -> Self {
        guard clientId == serverClientID,
              clientId.hasSuffix(".apps.googleusercontent.com"),
              nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              ticket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw AntintwrkSocialClient.Failure.invalidResponse }
        return self
    }
}

struct AntintwrkGoogleRegistration: Error, Decodable {
    let registrationTicket: String
    let email: String
    let firstName: String
    let surname: String
    
    func validated() throws -> Self {
        guard registrationTicket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              email.utf8.count <= 254, email.contains("@"), firstName.count <= 50, surname.count <= 50 else { throw AntintwrkSocialClient.Failure.invalidResponse }
        return self
    }
}

@MainActor
struct AntintwrkGoogleSignIn {
    private static var credentialInProgress = false
    
    static var serverClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String ?? ""
    }
    
    func credential(options: AntintwrkGoogleOptions, presenting: UIViewController) async throws -> String {
        guard !Self.credentialInProgress else { throw AntintwrkSocialClient.Failure.rejected }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String, clientID.hasSuffix(".apps.googleusercontent.com") else { throw AntintwrkSocialClient.Failure.invalidResponse }
        Self.credentialInProgress = true
        let google = GIDSignIn.sharedInstance
        google.signOut()
        defer {
            google.signOut()
            Self.credentialInProgress = false
        }
        google.configuration = GIDConfiguration(clientID: clientID, serverClientID: options.clientId)
        let result = try await google.signIn(withPresenting: presenting, hint: nil, additionalScopes: nil, nonce: options.nonce)
        try Task.checkCancellation()
        guard let token = result.user.idToken?.tokenString, token.utf8.count <= 16000,
              token.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw AntintwrkSocialClient.Failure.invalidResponse }
        return token
    }
}
