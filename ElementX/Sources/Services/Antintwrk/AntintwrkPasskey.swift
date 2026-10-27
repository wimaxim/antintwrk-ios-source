// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import AuthenticationServices
import SwiftUI

struct AntintwrkPasskeyOptions {
    let ticket: String
    let challenge: Data
    let allowed: [Data]
    init(_ json: [String: Any]) throws {
        guard let ticket = json["ticket"] as? String, ticket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let options = json["options"] as? [String: Any], options["rpId"] as? String == "antintwrk.com",
              let challenge = options["challenge"] as? String, let bytes = Self.decode(challenge), (16...1024).contains(bytes.count) else { throw AntintwrkSocialClient.Failure.invalidResponse }
        self.ticket = ticket; self.challenge = bytes
        let descriptors: [[String: Any]]
        if let rawDescriptors = options["allowCredentials"] {
            guard let parsed = rawDescriptors as? [[String: Any]] else { throw AntintwrkSocialClient.Failure.invalidResponse }
            descriptors = parsed
        } else {
            descriptors = []
        }
        guard descriptors.count <= 64 else { throw AntintwrkSocialClient.Failure.invalidResponse }
        allowed = try descriptors.map {
            guard $0["type"] as? String == "public-key", let id = $0["id"] as? String, let data = Self.decode(id), !data.isEmpty else { throw AntintwrkSocialClient.Failure.invalidResponse }
            return data
        }
    }
    
    private static func decode(_ value: String) -> Data? {
        guard value.count <= 2048, value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
}

@MainActor
final class AntintwrkPasskey: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private var controller: ASAuthorizationController?
    private let anchor: UIWindow
    init(anchor: UIWindow) {
        self.anchor = anchor
    }
    
    func assertion(options: AntintwrkPasskeyOptions) async throws -> String {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "antintwrk.com")
        let request = provider.createCredentialAssertionRequest(challenge: options.challenge)
        request.allowedCredentials = options.allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        request.userVerificationPreference = .required
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self; controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { finish(.failure(AntintwrkSocialClient.Failure.invalidResponse)); return }
        let encode: (Data) -> String = { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["id": encode(assertion.credentialID), "rawId": encode(assertion.credentialID), "type": "public-key",
                                                                   "response": ["authenticatorData": encode(assertion.rawAuthenticatorData), "clientDataJSON": encode(assertion.rawClientDataJSON), "signature": encode(assertion.signature), "userHandle": encode(assertion.userID)], "clientExtensionResults": [:]])
            guard let text = String(data: data, encoding: .utf8) else { throw AntintwrkSocialClient.Failure.invalidResponse }
            finish(.success(text))
        } catch { finish(.failure(error)) }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
    
    private func finish(_ result: Result<String, Error>) {
        let continuation = continuation; self.continuation = nil; controller = nil
        continuation?.resume(with: result)
    }
}
