// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import AuthenticationServices
import SwiftUI

struct AntintwrkAppleOptions: Decodable {
    let clientId: String
    let nonce: String
    let ticket: String
    
    func validated() throws -> Self {
        guard clientId == "com.antintwrk.app",
              nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              ticket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw AntintwrkSocialClient.Failure.invalidResponse }
        return self
    }
}

struct AntintwrkAppleCredential {
    let code: String
    let firstName: String
    let surname: String
}

@MainActor
final class AntintwrkAppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AntintwrkAppleCredential, Error>?
    private var controller: ASAuthorizationController?
    private var state: String?
    private let anchor: UIWindow
    
    init(anchor: UIWindow) {
        self.anchor = anchor
    }
    
    func credential(options: AntintwrkAppleOptions) async throws -> AntintwrkAppleCredential {
        guard continuation == nil else { throw AntintwrkSocialClient.Failure.rejected }
        try Task.checkCancellation()
        let options = try options.validated()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = options.nonce
        request.state = options.ticket
        state = options.ticket
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.controller?.cancel()
                self?.finish(.failure(CancellationError()))
            }
        }
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let state, credential.state == state,
              let data = credential.authorizationCode,
              let code = String(data: data, encoding: .utf8), (8...4096).contains(code.utf8.count),
              !code.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            finish(.failure(AntintwrkSocialClient.Failure.invalidResponse))
            return
        }
        finish(.success(.init(code: code, firstName: String((credential.fullName?.givenName ?? "").prefix(50)), surname: String((credential.fullName?.familyName ?? "").prefix(50)))))
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        finish(.failure((error as? ASAuthorizationError)?.code == .canceled ? CancellationError() : error))
    }
    
    private func finish(_ result: Result<AntintwrkAppleCredential, Error>) {
        let continuation = continuation
        self.continuation = nil
        controller = nil
        state = nil
        continuation?.resume(with: result)
    }
}

struct AntintwrkAppleSignInButton: UIViewRepresentable {
    let enabled: Bool
    let label: String
    let action: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }
    
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .white)
        button.cornerRadius = 8
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }
    
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = enabled
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "antintwrk-auth-apple"
    }
    
    final class Coordinator: NSObject {
        var action: () -> Void
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        @objc func activate() {
            action()
        }
    }
}
