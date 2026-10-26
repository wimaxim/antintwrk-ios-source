// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import MatrixRustSDK
import SwiftUI
import WebKit

nonisolated struct AntintwrkMatrixFactoryHook: AccountManagedClientFactoryHook {
    let proxyURL: String?
    
    func configure(_ builder: ClientBuilder, toRestore session: Session?) -> ClientBuilder {
        let transportBuilder = proxyURL.map { builder.proxy(url: $0) } ?? builder
        return transportBuilder.autoEnableBackups(autoEnableBackups: false)
            .roomKeyRecipientStrategy(strategy: .identityBasedStrategy)
            .dmRoomDefinition(dmRoomDefinition: .matrixSpec)
            .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
            .enableShareHistoryOnInvite(enableShareHistoryOnInvite: true)
    }
    
    func updateAuthenticationClient(_ client: ClientProtocol) -> ClientProtocol {
        client
    }
}

@MainActor
final class AntintwrkMessengerBootstrap: NSObject, WKNavigationDelegate {
    enum Failure: Error { case admission, oauth, recovery, cancelled }
    private var stage = "admission"
    static let callbackURL = URL(string: "https://antintwrk.com/oauth/ios/com.antintwrk.app")!
    private var continuation: CheckedContinuation<URL, Error>?
    private var oauthView: WKWebView?
    private var processing = false
    private var social: AntintwrkSocialClient?
    private var actor: String?
    private var sdk: ClientProtocol?
    private var rawSync: SyncService?
    private var syncObserver: TaskHandle?
    private var syncRunning = false
    private var cancelled = false
    private let store: UserSessionStoreProtocol
    private let settings: AppSettings
    private let hooks: AppHooks
    private let keychain: KeychainController
    
    init(store: UserSessionStoreProtocol, settings: AppSettings, hooks: AppHooks) {
        self.store = store; self.settings = settings; self.hooks = hooks
        keychain = KeychainController(service: .sessions, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        hooks.registerClientFactoryHook(AntintwrkMatrixFactoryHook(proxyURL: AntintwrkRegionalTransport.enabled ? AntintwrkRegionalTransport.shared.proxyURL : nil))
    }
    
    func prepare(social: AntintwrkSocialClient, admission: AntintwrkSocialAdmission) async throws -> UserSessionProtocol {
        do {
            return try await prepareSession(social: social, admission: admission)
        } catch {
            MXLog.error("Managed messenger preparation failed at \(stage); category \(String(describing: type(of: error)))")
            await cancel()
            throw error
        }
    }
    
    private func prepareSession(social: AntintwrkSocialClient, admission: AntintwrkSocialAdmission) async throws -> UserSessionProtocol {
        if AntintwrkRegionalTransport.enabled {
            try await AntintwrkRegionalTransport.shared.start()
            hooks.registerClientFactoryHook(AntintwrkMatrixFactoryHook(proxyURL: AntintwrkRegionalTransport.shared.proxyURL))
        }
        guard let actor = admission.matrixUserId, admission.stage == .authenticated || social.cachedMessengerActor == actor else { throw Failure.admission }
        self.social = social; self.actor = actor
        stage = "sdk_client"
        let credentials = keychain.restorationTokens().first {
            $0.userID == actor && $0.restorationToken.sessionDirectories.isNonTransientUserDataValid()
        }
        let directories = credentials?.restorationToken.sessionDirectories ?? SessionDirectories()
        let passphrase = credentials?.restorationToken.passphrase ?? EncryptionKeyProvider().generateKey().base64EncodedString()
        let sdk: ClientProtocol
        if let credentials {
            sdk = try await ClientFactory().makeAppClient(credentials: credentials, clientSessionDelegate: store.clientSessionDelegate, appSettings: settings, appHooks: hooks)
        } else {
            guard admission.stage == .authenticated else { throw Failure.admission }
            sdk = try await ClientFactory().makeAuthenticationClient(serverNameOrBaseURL: AntintwrkClientConfiguration.messengerOrigin.absoluteString, sessionDirectories: directories, passphrase: passphrase,
                                                                     clientSessionDelegate: store.clientSessionDelegate, appSettings: settings, appHooks: hooks)
            let config = MatrixRustSDK.OAuthConfiguration(clientName: "ANTINTWRK", redirectUri: Self.callbackURL.absoluteString, clientUri: "https://antintwrk.com",
                                                          logoUri: nil, tosUri: "https://antintwrk.com/en/terms", policyUri: "https://antintwrk.com/en/privacy", staticRegistrations: [:])
            stage = "oauth_request"
            let authorization = try await sdk.urlForOauth(oauthConfiguration: config, prompt: .consent, loginHint: nil, deviceId: nil, additionalScopes: nil)
            do {
                stage = "oauth_handoff"
                let callback = try await authorize(URL(string: authorization.loginUrl())!)
                try checkCancellation()
                try await sdk.loginWithOauthCallback(callbackUrl: callback.absoluteString)
            } catch {
                MXLog.error("Managed messenger failed at \(stage)")
                await sdk.abortOauthAuth(authorizationData: authorization)
                throw Failure.oauth
            }
        }
        self.sdk = sdk
        guard try sdk.userId() == actor else { throw Failure.admission }
        await sdk.enableAllSendQueues(enable: false)
        let token = try RestorationToken(session: sdk.session(), sessionDirectories: directories, passphrase: passphrase, pusherNotificationClientIdentifier: credentials?.restorationToken.pusherNotificationClientIdentifier)
        keychain.setRestorationToken(token, forUsername: actor)
        guard keychain.restorationTokenForUsername(actor)?.session == token.session else { throw Failure.recovery }
        rawSync = try await sdk.syncService().withOfflineMode().finish()
        syncObserver = rawSync?.state(listener: SDKListener.onMainActor { [weak self] state in self?.syncRunning = state == .running })
        await rawSync?.start()
        do {
            stage = "account_recovery"
            try await recover(sdk, actor: actor, social: social)
            try checkCancellation()
            await rawSync?.stop()
            rawSync = nil; syncObserver = nil
            let session = try await store.userSession(for: sdk, sessionDirectories: directories, passphrase: passphrase).get()
            await session.clientProxy.resumeServices()
            guard try sdk.userId() == actor, sdk.encryption().verificationState() == .verified else { throw Failure.recovery }
            return session
        } catch {
            MXLog.error("Managed messenger failed at \(stage)")
            await rawSync?.stop()
            await sdk.enableAllSendQueues(enable: false)
            throw Failure.recovery
        }
    }
    
    func cancel() async {
        cancelled = true
        finish(.failure(Failure.cancelled))
        await rawSync?.stop()
        if let sdk {
            await sdk.enableAllSendQueues(enable: false)
        }
    }
    
    func logout() async throws {
        if let sdk {
            try await sdk.encryption().waitForBackupUploadSteadyState(progressListener: nil)
            guard sdk.encryption().verificationState() == .verified, sdk.encryption().backupState() == .enabled,
                  sdk.encryption().recoveryState() == .enabled, let actor, let social else { throw Failure.recovery }
            let custodyReady: Bool
            if social.cachedMessengerActor == actor {
                custodyReady = true
            } else {
                custodyReady = try await social.recoverySecret(actor: actor, operation: "read") != nil
            }
            guard custodyReady else { throw Failure.recovery }
            await sdk.enableAllSendQueues(enable: false)
            try await sdk.logout()
        }
        await cancel()
    }
    
    private func recover(_ sdk: ClientProtocol, actor: String, social: AntintwrkSocialClient) async throws {
        let encryption = sdk.encryption()
        await encryption.waitForE2eeInitializationTasks()
        try checkCancellation()
        let until = ContinuousClock.now.advanced(by: .seconds(120))
        while encryption.recoveryState() == .unknown {
            try await pause(until)
        }
        if social.cachedMessengerActor == actor, encryption.verificationState() == .verified,
           encryption.recoveryState() == .enabled, encryption.backupState() == .enabled {
            while !syncRunning {
                try await pause(until)
            }
            return
        }
        let backupExists = try await encryption.backupExistsOnServer()
        let canCreate = encryption.recoveryState() == .disabled && !backupExists
        var secret = try await social.recoverySecret(actor: actor, operation: "read")
        if secret == nil {
            guard canCreate else { throw Failure.recovery }
            secret = try await social.recoverySecret(actor: actor, operation: "create")
        }
        guard let secret else { throw Failure.recovery }
        try checkCancellation()
        if canCreate {
            _ = try await encryption.enableRecovery(waitForBackupsToUpload: true, passphrase: secret, progressListener: SDKListener.onMainActor { (_: EnableRecoveryProgress) in })
        }
        try await encryption.recover(recoveryKey: secret)
        guard try await social.recoverySecret(actor: actor, operation: "read") == secret else { throw Failure.recovery }
        if encryption.backupState() != .enabled {
            do { try await encryption.enableBackups() } catch { /* Imported owner keys must still reach enabled below. */ }
        }
        while encryption.backupState() != .enabled || encryption.recoveryState() != .enabled || encryption.verificationState() != .verified || !syncRunning {
            try await pause(until)
        }
        try await encryption.waitForBackupUploadSteadyState(progressListener: nil)
        try checkCancellation()
        try await social.recordVerifiedCustody(actor: actor)
    }
    
    private func pause(_ until: ContinuousClock.Instant) async throws {
        try checkCancellation()
        guard ContinuousClock.now < until else { throw Failure.recovery }
        try await Task.sleep(for: .milliseconds(100))
    }
    
    private func checkCancellation() throws {
        guard !cancelled, !Task.isCancelled else { throw Failure.cancelled }
    }
    
    static func isOwnCallback(_ url: URL) -> Bool {
        url.scheme == callbackURL.scheme && url.host == callbackURL.host && url.path == callbackURL.path &&
            url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    
    private func authorize(_ url: URL) async throws -> URL {
        guard url.scheme == "https", url.host == "auth.antimsg.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw Failure.oauth }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if AntintwrkRegionalTransport.enabled {
            AntintwrkRegionalTransport.shared.configure(config.websiteDataStore)
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
              let host = window.rootViewController?.view else { throw Failure.oauth }
        let view = WKWebView(frame: host.bounds, configuration: config)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.alpha = 0.01
        view.isOpaque = false
        view.backgroundColor = .clear
        // WebKit must stay attached during the background OAuth navigation.
        host.insertSubview(view, at: 0)
        view.customUserAgent = social?.configuration.socialUserAgent
        view.navigationDelegate = self
        oauthView = view
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finish(.failure(Failure.oauth))
            }
        }
    }
    
    private func finish(_ result: Result<URL, Error>) {
        let waiting = continuation
        continuation = nil
        oauthView?.stopLoading(); oauthView?.navigationDelegate = nil; oauthView?.removeFromSuperview(); oauthView = nil
        waiting?.resume(with: result)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !cancelled, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        MXLog.info("Managed OAuth navigation step: \(Self.oauthStep(url))")
        if Self.isOwnCallback(url), navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.cancel); finish(.success(url)); return
        }
        guard url.scheme == "https", url.host == "auth.antimsg.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            decisionHandler(.cancel); finish(.failure(Failure.oauth)); return
        }
        if url.path == "/social-identity/authorize", navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.cancel)
            guard !processing, let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, let social, let actor else { return }
            processing = true
            Task { [weak self] in
                do {
                    let next = try await social.authorizeMessenger(query: query, actor: actor)
                    guard let self, !cancelled else { return }
                    processing = false
                    webView.load(URLRequest(url: next))
                } catch {
                    if let failure = error as? AntintwrkSocialClient.Failure {
                        MXLog.error("Managed OAuth social handoff failed: \(failure)")
                    } else if let failure = error as? URLError {
                        MXLog.error("Managed OAuth social handoff transport failed: \(failure.code.rawValue)")
                    } else {
                        MXLog.error("Managed OAuth social handoff failed: invalid contract")
                    }
                    self?.finish(.failure(Failure.oauth))
                }
            }
            return
        }
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            MXLog.info("Managed OAuth document step: \(Self.oauthStep(url))")
        }
        guard let url = webView.url, url.host == "auth.antimsg.com", url.path.range(of: "^/consent/[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil else { return }
        webView.evaluateJavaScript("""
        (() => { const form=document.querySelector('form.cpd-form-root[method=POST]'); if(!form || !form.querySelector('input[name=csrf]') || !form.querySelector('button[type=submit]')) return;
        const action=new URL(form.action,location.href);
        if(action.origin===location.origin && action.pathname===location.pathname) form.requestSubmit(); })();
        """)
    }
    
    private static func oauthStep(_ url: URL) -> String {
        if isOwnCallback(url) {
            return "app_callback"
        }
        guard url.host == "auth.antimsg.com" else { return "foreign_origin" }
        if url.path == "/social-identity/authorize" {
            return "social_handoff"
        }
        if url.path.hasPrefix("/upstream/callback/") {
            return "provider_callback"
        }
        if url.path.hasPrefix("/upstream/authorize/") {
            return "provider_authorize"
        }
        if url.path.hasPrefix("/consent/") {
            return "consent"
        }
        if url.path == "/authorize" {
            return "authorize"
        }
        if url.path.hasPrefix("/login") {
            return "login"
        }
        return "other_auth_document"
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isExpectedNavigationCancellation(error, handoffActive: processing) else { return }
        finish(.failure(Failure.oauth))
    }
    
    static func isExpectedNavigationCancellation(_ error: Error, handoffActive: Bool) -> Bool {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled {
            return true
        }
        // Cancelling the intercepted redirect reports WebKit's policy interruption, not a transport error.
        return handoffActive && failure.domain == "WebKitErrorDomain" && failure.code == 102
    }
}
