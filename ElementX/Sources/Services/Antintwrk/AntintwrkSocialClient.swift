// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import ImageIO
import Network
import SwiftUI
import WebKit

struct AntintwrkSocialStatus {
    let count: Int
    let name: String?
    let identity: String?
    let avatar: String?
}

struct AntintwrkSocialAdmission: Decodable {
    enum Stage: String, Decodable { case login = "LOGIN", device = "DEVICE", totp = "TOTP", setupRequired = "SETUP_REQUIRED", authenticated = "AUTHENTICATED" }
    let stage: Stage
    let csrf: String
    let profileIdentity: String?
    let matrixUserId: String?
    let domainBinding: String?
    
    func validated() throws -> Self {
        guard csrf.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw AntintwrkSocialClient.Failure.invalidResponse }
        if stage == .authenticated {
            guard let matrixUserId, matrixUserId.range(of: "^@u[1-9][0-9]{0,17}:antintwrk\\.com$", options: .regularExpression) != nil else { throw AntintwrkSocialClient.Failure.invalidResponse }
        }
        return self
    }
}

private final class AntintwrkHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class AntintwrkSocialClient {
    enum Failure: Error { case invalidResponse, unavailable, rejected, cancelled }
    let configuration: AntintwrkClientConfiguration
    let websiteDataStore: WKWebsiteDataStore
    private let delegate = AntintwrkHTTPDelegate()
    private var epoch = UUID()
    private var http: URLSession
    private let cookieVault: AntintwrkSocialCookieVaultProtocol?
    private var restoredCookies = false
    private var admittedActor: String?
    private var custodyVerified = false
    var cachedMessengerActor: String? {
        custodyVerified ? admittedActor : nil
    }
    
    private var admittedDomains: Set<String> = []
    
    init(configuration: AntintwrkClientConfiguration, websiteDataStore: WKWebsiteDataStore = .default(), settings: URLSessionConfiguration = .ephemeral, cookieVault: AntintwrkSocialCookieVaultProtocol? = nil) {
        self.configuration = configuration
        self.websiteDataStore = websiteDataStore
        self.cookieVault = cookieVault ?? (websiteDataStore.isPersistent ? AntintwrkSocialCookieVault() : nil)
        settings.httpShouldSetCookies = false
        settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 30
        http = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
    }
    
    func session(origin: AntintwrkClientConfiguration.SocialOrigin = .russian) async throws -> AntintwrkSocialAdmission {
        let captured = epoch
        let admission = try await JSONDecoder().decode(AntintwrkSocialAdmission.self, from: post("session", origin: origin)).validated()
        guard captured == epoch else { throw Failure.cancelled }
        try await recordAdmission(admission, origin: origin)
        return admission
    }
    
    func prepareRegionalTransport() async throws {
        guard AntintwrkRegionalTransport.enabled else { return }
        let transport = AntintwrkRegionalTransport.shared
        try await transport.start()
        transport.configure(websiteDataStore)
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false; settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 30
        transport.configure(settings)
        http.invalidateAndCancel()
        http = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
    }
    
    func recordAdmission(_ admission: AntintwrkSocialAdmission, origin: AntintwrkClientConfiguration.SocialOrigin) async throws {
        let validated = try admission.validated()
        if validated.stage == .authenticated {
            guard let actor = validated.matrixUserId, admittedActor == nil || admittedActor == actor else { throw Failure.rejected }
            admittedActor = actor
            admittedDomains.insert(URL(string: origin.rawValue)!.host!)
            try await persistCookies()
        }
    }
    
    func login(email: String, password: String, language: String) async throws -> AntintwrkSocialAdmission {
        let captured = epoch
        let snapshot = await websiteDataStore.httpCookieStore.allCookies()
        let expected = admittedActor
        do { return try await performLogin(email: email, password: password, language: language) }
        catch {
            if expected != nil {
                await restoreSnapshot(snapshot, captured: captured)
            }
            throw error
        }
    }
    
    private func performLogin(email: String, password: String, language: String) async throws -> AntintwrkSocialAdmission {
        let initial = try await session()
        let result = try await post("login", fields: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password, "lng": language, "csrf": initial.csrf])
        try requireOK(result)
        let admission = try await session()
        guard admission.stage != .login else { throw Failure.rejected }
        return admission
    }
    
    func signInWithGoogle(presenting: UIViewController) async throws -> AntintwrkSocialAdmission {
        let captured = epoch
        let expected = admittedActor
        let snapshot = await websiteDataStore.httpCookieStore.allCookies()
        do {
            let initial = try await session()
            let optionsData = try await post("google-options", fields: ["csrf": initial.csrf])
            let options = try JSONDecoder().decode(AntintwrkGoogleOptions.self, from: optionsData).validated(serverClientID: AntintwrkGoogleSignIn.serverClientID)
            let credential = try await AntintwrkGoogleSignIn().credential(options: options, presenting: presenting)
            guard captured == epoch else { throw Failure.cancelled }
            let result = try await post("google", fields: ["credential": credential, "ticket": options.ticket, "csrf": initial.csrf])
            guard captured == epoch else { throw Failure.cancelled }
            if let registration = try? JSONDecoder().decode(AntintwrkGoogleRegistration.self, from: result) {
                guard expected == nil else { throw Failure.rejected }
                throw try registration.validated()
            }
            guard try (JSONSerialization.jsonObject(with: result) as? [String: Any])?["ok"] as? Bool == true else { throw Failure.rejected }
            let admission = try await session()
            guard admission.stage != .login else { throw Failure.rejected }
            return admission
        } catch {
            if expected != nil {
                await restoreSnapshot(snapshot, captured: captured)
            }
            throw error
        }
    }
    
    func signInWithApple(anchor: UIWindow) async throws -> AntintwrkSocialAdmission {
        let captured = epoch
        let expected = admittedActor
        let snapshot = await websiteDataStore.httpCookieStore.allCookies()
        do {
            let initial = try await session()
            guard captured == epoch else { throw Failure.cancelled }
            let data = try await post("apple-options", fields: ["csrf": initial.csrf])
            guard captured == epoch else { throw Failure.cancelled }
            let options = try JSONDecoder().decode(AntintwrkAppleOptions.self, from: data).validated()
            let credential = try await AntintwrkAppleSignIn(anchor: anchor).credential(options: options)
            guard captured == epoch else { throw Failure.cancelled }
            let result = try await post("apple", fields: ["code": credential.code, "ticket": options.ticket, "csrf": initial.csrf, "firstName": credential.firstName, "surname": credential.surname])
            guard captured == epoch else { throw Failure.cancelled }
            if let registration = try? JSONDecoder().decode(AntintwrkGoogleRegistration.self, from: result) {
                guard expected == nil else { throw Failure.rejected }
                throw try registration.validated()
            }
            guard try (JSONSerialization.jsonObject(with: result) as? [String: Any])?["ok"] as? Bool == true else { throw Failure.rejected }
            let admission = try await session()
            guard captured == epoch else { throw Failure.cancelled }
            guard admission.stage != .login else { throw Failure.rejected }
            return admission
        } catch {
            if expected != nil {
                await restoreSnapshot(snapshot, captured: captured)
            }
            throw error
        }
    }
    
    func registerApple(ticket: String, fields: [String: String]) async throws -> AntintwrkSocialAdmission {
        guard ticket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, admittedActor == nil else { throw Failure.rejected }
        let captured = epoch
        let initial = try await session()
        guard captured == epoch else { throw Failure.cancelled }
        var payload = fields
        payload["csrf"] = initial.csrf
        payload["ticket"] = ticket
        let data = try await post("apple-register", fields: payload)
        guard captured == epoch else { throw Failure.cancelled }
        guard try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true else { throw Failure.rejected }
        let admission = try await session()
        guard captured == epoch else { throw Failure.cancelled }
        guard admission.stage != .login else { throw Failure.rejected }
        return admission
    }
    
    func registerGoogle(ticket: String, fields: [String: String]) async throws -> AntintwrkSocialAdmission {
        guard ticket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, admittedActor == nil else { throw Failure.rejected }
        let initial = try await session()
        var payload = fields; payload["csrf"] = initial.csrf; payload["ticket"] = ticket
        let data = try await post("google-register", fields: payload)
        guard try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true else { throw Failure.rejected }
        let admission = try await session()
        guard admission.stage != .login else { throw Failure.rejected }
        return admission
    }
    
    func signInWithPasskey(anchor: UIWindow) async throws -> AntintwrkSocialAdmission {
        let captured = epoch
        let expected = admittedActor
        let snapshot = await websiteDataStore.httpCookieStore.allCookies()
        do {
            let initial = try await session()
            let data = try await post("passkey-options", fields: ["csrf": initial.csrf])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
            let options = try AntintwrkPasskeyOptions(json)
            let provider = AntintwrkPasskey(anchor: anchor)
            let credential = try await provider.assertion(options: options)
            guard captured == epoch else { throw Failure.cancelled }
            let result = try await post("passkey", fields: ["credential": credential, "ticket": options.ticket, "csrf": initial.csrf])
            try requireOK(result)
            let admission = try await session()
            guard admission.stage != .login else { throw Failure.rejected }
            return admission
        } catch {
            if expected != nil {
                await restoreSnapshot(snapshot, captured: captured)
            }
            throw error
        }
    }
    
    private func restoreSnapshot(_ snapshot: [HTTPCookie], captured: UUID) async {
        guard captured == epoch else { return }
        for cookie in await websiteDataStore.httpCookieStore.allCookies() {
            guard captured == epoch else { return }
            await websiteDataStore.httpCookieStore.delete(cookie)
        }
        for cookie in snapshot {
            guard captured == epoch else { return }
            await websiteDataStore.httpCookieStore.setCookie(cookie)
        }
    }
    
    func confirm(_ admission: AntintwrkSocialAdmission, code: String) async throws -> AntintwrkSocialAdmission {
        guard admission.stage == .device || admission.stage == .totp else { throw Failure.invalidResponse }
        let result = try await post(admission.stage == .device ? "device-verify" : "totp", fields: ["code": code, "csrf": admission.csrf])
        if admission.stage == .totp {
            guard (try? JSONSerialization.jsonObject(with: result) as? [String])?.first == "OK" else { throw Failure.rejected }
        } else {
            try requireOK(result)
        }
        return try await session()
    }
    
    func startDevice(_ admission: AntintwrkSocialAdmission) async throws {
        _ = try await post("device-start", fields: ["csrf": admission.csrf])
    }
    
    func requestAccount(action: String, fields: [String: String]) async throws {
        guard ["register", "reset"].contains(action) else { throw Failure.invalidResponse }
        let admission = try await session()
        try await requireOK(post(action, fields: fields.merging(["csrf": admission.csrf]) { _, new in new }))
    }
    
    func recommendedOrigin() async -> AntintwrkClientConfiguration.SocialOrigin {
        var selected: AntintwrkClientConfiguration.SocialOrigin = .russian
        defer {
            if AntintwrkRegionalTransport.enabled {
                AntintwrkRegionalTransport.shared.preferredRegion = selected == .russian ? .russian : .global
            }
        }
        do {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpShouldSetCookies = false; settings.httpCookieStorage = nil
            if AntintwrkRegionalTransport.enabled {
                AntintwrkRegionalTransport.shared.configure(settings)
            }
            let transport = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
            defer { transport.finishTasksAndInvalidate() }
            var request = URLRequest(url: AntintwrkClientConfiguration.geographyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
            request.setValue(configuration.socialUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await boundedResponse(request, limit: 4096, transport: transport)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["version"] as? Int == 1, let detected = json["detected"] as? Bool else { return .russian }
            let country = json["country"] as? String
            guard detected ? (country?.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil && country != "ZZ") : country == nil else { return .russian }
            let expected: AntintwrkClientConfiguration.SocialOrigin = !detected || country == "RU" ? .russian : .global
            selected = json["social_origin"] as? String == expected.rawValue ? expected : .russian
            return selected
        } catch { return .russian }
    }
    
    func transfer(_ admission: AntintwrkSocialAdmission, to target: AntintwrkClientConfiguration.SocialOrigin) async throws -> AntintwrkSocialAdmission {
        guard target == .global, admission.stage == .authenticated else { throw Failure.invalidResponse }
        let receiving = try await session(origin: target)
        if receiving.stage == .authenticated, receiving.matrixUserId == admission.matrixUserId {
            return receiving
        }
        guard let binding = receiving.domainBinding, binding.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw Failure.invalidResponse }
        let data = try await post("social-domain-issue", fields: ["target": target.rawValue, "binding": binding, "csrf": admission.csrf])
        guard let issued = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              issued["matrixUserId"] as? String == admission.matrixUserId,
              let ticket = issued["ticket"] as? String, ticket.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw Failure.invalidResponse }
        let consumed = try await post("social-domain-consume", origin: target, fields: ["ticket": ticket, "csrf": receiving.csrf])
        guard let result = try JSONSerialization.jsonObject(with: consumed) as? [String: Any], result["matrixUserId"] as? String == admission.matrixUserId else { throw Failure.invalidResponse }
        let final = try await session(origin: target)
        guard final.stage == .authenticated, final.matrixUserId == admission.matrixUserId else { throw Failure.invalidResponse }
        return final
    }
    
    func socialStatus(actor: String) async throws -> AntintwrkSocialStatus {
        let admission = try await session()
        guard admission.stage == .authenticated, admission.matrixUserId == actor else { throw Failure.rejected }
        let data = try await post("status", fields: ["csrf": admission.csrf])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let count = json["notifications"] as? Int else { throw Failure.invalidResponse }
        let identity = json["profileIdentity"] as? String
        return AntintwrkSocialStatus(count: min(9999, max(0, count)), name: json["profileName"] as? String, identity: identity?.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil ? identity : nil, avatar: json["profileAvatar"] as? String)
    }
    
    func avatar(_ source: String, origin: AntintwrkClientConfiguration.SocialOrigin) async throws -> UIImage? {
        guard let url = URL(string: source, relativeTo: URL(string: origin.rawValue))?.absoluteURL,
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              ["antimsg.com", "antintwrk.com"].contains(url.host ?? "") else { return nil }
        let captured = epoch
        let cookies = await websiteDataStore.httpCookieStore.allCookies().filter {
            let host = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            return host == url.host && url.path.hasPrefix($0.path)
        }
        var request = URLRequest(url: url)
        request.setValue(configuration.socialUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        let (data, response) = try await boundedResponse(request, limit: 2_000_000)
        guard captured == epoch, (response as? HTTPURLResponse)?.statusCode == 200, let image = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 192] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
    
    func externalDestination(_ initial: URL, origin: AntintwrkClientConfiguration.SocialOrigin) async throws -> URL {
        let captured = epoch
        var current = initial
        for _ in 0..<5 {
            guard current.scheme == "https", current.user == nil, current.password == nil, current.port == nil || current.port == 443 else { throw Failure.invalidResponse }
            if current.host != URL(string: origin.rawValue)?.host {
                return current
            }
            let parts = current.path.split(separator: "/").map(String.init)
            guard parts.contains(where: { ["go", "goto", "go.html"].contains($0) }) else { throw Failure.invalidResponse }
            let cookies = await websiteDataStore.httpCookieStore.allCookies().filter {
                let host = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                return current.host == host && current.path.hasPrefix($0.path) && ($0.expiresDate.map { $0 > Date() } ?? true)
            }
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue(configuration.socialUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
            let (_, response) = try await boundedResponse(request, limit: 4096)
            guard captured == epoch, let response = response as? HTTPURLResponse, [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: current)?.absoluteURL else { throw Failure.invalidResponse }
            current = next
        }
        throw Failure.invalidResponse
    }
    
    func messengerPeople(query: String, actor: String) async throws -> [UserProfile] {
        let admission = try await session()
        guard admission.stage == .authenticated, admission.matrixUserId == actor else { throw Failure.rejected }
        let data = try await post("messenger-search", fields: ["query": String(query.prefix(60)), "csrf": admission.csrf])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["results"] as? [[String: Any]] else { throw Failure.invalidResponse }
        return rows.prefix(24).compactMap { row in
            guard let id = row["userId"] as? String, AntintwrkSocialDirectory.socialID(id) != nil, id != actor else { return nil }
            return UserProfile(userID: id, displayName: row["displayName"] as? String)
        }
    }
    
    func resolveSocialRecipient(target: String, actor: String) async throws -> String {
        let admission = try await session()
        guard admission.stage == .authenticated, admission.matrixUserId == actor else { throw Failure.rejected }
        let data = try await post("messenger-recipient", fields: ["target": target, "csrf": admission.csrf])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["actorUserId"] as? String == actor, let recipient = json["recipientUserId"] as? String,
              AntintwrkSocialDirectory.socialID(recipient) != nil, recipient != actor else { throw Failure.rejected }
        return recipient
    }
    
    func authorizeRecipient(_ recipient: String, actor: String) async throws {
        guard let id = AntintwrkSocialDirectory.socialID(recipient), recipient != actor else { throw Failure.rejected }
        guard try await resolveSocialRecipient(target: id, actor: actor) == recipient else { throw Failure.rejected }
    }
    
    func messengerAssertion(query: String, actor: String) async throws -> String {
        let admission = try await session()
        guard admission.stage == .authenticated, admission.matrixUserId == actor else { throw Failure.rejected }
        let data = try await post("messenger-handoff", fields: ["query": query, "csrf": admission.csrf])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["matrixUserId"] as? String == actor, let assertion = json?["assertion"] as? String,
              assertion.count <= 8192 else { throw Failure.invalidResponse }
        return assertion
    }
    
    func authorizeMessenger(query: String, actor: String) async throws -> URL {
        let captured = epoch
        let assertion = try await messengerAssertion(query: query, actor: actor)
        var request = URLRequest(url: URL(string: "https://auth.antimsg.com/social-identity/authorize")!)
        request.httpMethod = "POST"
        request.setValue(configuration.socialUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "assertion": assertion])
        let (_, response) = try await boundedResponse(request, limit: 8192)
        guard captured == epoch, let response = response as? HTTPURLResponse, response.statusCode == 302,
              let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
              url.scheme == "https", url.host == "auth.antimsg.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.path.hasPrefix("/upstream/callback/") else { throw Failure.invalidResponse }
        return url
    }
    
    func recoverySecret(actor: String, operation: String) async throws -> String? {
        guard ["read", "create"].contains(operation) else { throw Failure.invalidResponse }
        let captured = epoch
        let admission = try await session()
        guard admission.stage == .authenticated, admission.matrixUserId == actor else { throw Failure.rejected }
        let ticketData = try await post("messenger-recovery", fields: ["operation": operation, "csrf": admission.csrf])
        let ticket = try JSONSerialization.jsonObject(with: ticketData) as? [String: Any]
        guard ticket?["matrixUserId"] as? String == actor, let assertion = ticket?["assertion"] as? String else { throw Failure.invalidResponse }
        var request = URLRequest(url: URL(string: "https://auth.antimsg.com/social-identity/recovery")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operation": operation, "assertion": assertion])
        let (data, response) = try await boundedResponse(request, limit: 4096)
        guard captured == epoch, (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["matrixUserId"] as? String == actor else { throw Failure.invalidResponse }
        if result["secret"] is NSNull {
            return nil
        }
        guard let secret = result["secret"] as? String, secret.range(of: "^[A-Za-z0-9_-]{64}$", options: .regularExpression) != nil else { throw Failure.invalidResponse }
        return secret
    }
    
    func logout(admission: AntintwrkSocialAdmission?, origin: AntintwrkClientConfiguration.SocialOrigin) async {
        // Invalidate pending callbacks before revocation; old replies must never repopulate the cookie jar.
        epoch = UUID()
        try? cookieVault?.clear()
        admittedActor = nil; admittedDomains = []; restoredCookies = true; custodyVerified = false
        http.getAllTasks { $0.forEach { $0.cancel() } }
        if let admission {
            _ = try? await post("logout", origin: origin, fields: ["csrf": admission.csrf])
        }
        epoch = UUID()
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    
    func clearForExplicitLogin() async throws {
        epoch = UUID()
        try cookieVault?.clear()
        admittedActor = nil; admittedDomains = []; restoredCookies = true; custodyVerified = false
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        guard await websiteDataStore.httpCookieStore.allCookies().isEmpty else { throw Failure.invalidResponse }
    }
    
    /// Store traffic stays in native transport; signed receipts never enter the page bridge.
    func storeRequest(_ action: String, fields: [String: String], actor: String) async throws -> Data {
        guard ["app-store-catalog", "app-store-order", "app-store-status", "app-store-verify"].contains(action),
              admittedActor == actor else { throw Failure.rejected }
        let captured = epoch
        let admission = try await session()
        guard captured == epoch, admission.stage == .authenticated, admission.matrixUserId == actor, admittedActor == actor else { throw Failure.cancelled }
        let protected = ["csrf": admission.csrf, "actor": actor, "bundle": "com.antintwrk.app"]
        let data = try await post(action, fields: fields.merging(protected) { _, trusted in trusted })
        guard captured == epoch, admittedActor == actor else { throw Failure.cancelled }
        return data
    }
    
    /// Uses the authenticated native API and keeps platform selection out of the web surface.
    func pushRequest(_ action: String, fields: [String: String] = [:], actor: String) async throws -> Data {
        guard ["push-settings", "push-preferences", "push-subscribe", "push-unsubscribe"].contains(action),
              admittedActor == actor else { throw Failure.rejected }
        let captured = epoch
        let admission = try await session()
        guard captured == epoch, admission.stage == .authenticated, admission.matrixUserId == actor, admittedActor == actor else { throw Failure.cancelled }
        let data = try await post(action, fields: fields.merging(["csrf": admission.csrf, "platform": "ios"]) { _, trusted in trusted })
        guard captured == epoch, admittedActor == actor else { throw Failure.cancelled }
        return data
    }
    
    private func post(_ action: String, origin: AntintwrkClientConfiguration.SocialOrigin = .russian, fields: [String: String] = [:]) async throws -> Data {
        try await restoreCookiesIfNeeded()
        let captured = epoch
        let url = URL(string: origin.rawValue + "/antintwrk_mobile.php")!
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        guard captured == epoch else { throw Failure.cancelled }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(origin.rawValue, forHTTPHeaderField: "Origin")
        request.setValue("native", forHTTPHeaderField: "X-Antintwrk-Client")
        request.setValue(configuration.socialUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (url.host == domain || (cookie.domain.hasPrefix(".") && url.host?.hasSuffix("." + domain) == true)) && url.path.hasPrefix(cookie.path) && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        request.setValue(HTTPCookie.requestHeaderFields(with: matching)["Cookie"], forHTTPHeaderField: "Cookie")
        var body = URLComponents()
        body.queryItems = fields.merging(["action": action]) { _, new in new }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await boundedResponse(request, limit: 65536)
        guard captured == epoch else { throw Failure.cancelled }
        guard let response = response as? HTTPURLResponse, data.count <= 65536 else { throw Failure.invalidResponse }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields.reduce(into: [String: String]()) {
            if let key = $1.key as? String, let value = $1.value as? String {
                $0[key] = value
            }
        }, for: url) {
            var properties = cookie.properties ?? [:]
            properties[.secure] = "TRUE"
            guard let secured = HTTPCookie(properties: properties) else { throw Failure.invalidResponse }
            await websiteDataStore.httpCookieStore.setCookie(secured)
            guard captured == epoch else { throw Failure.cancelled }
        }
        if response.statusCode == 302, response.value(forHTTPHeaderField: "Location") == "/", ["login", "passkey", "device-verify"].contains(action) {
            return Data()
        }
        guard (200...299).contains(response.statusCode) else { throw Failure.unavailable }
        return data
    }
    
    func restoreCookiesIfNeeded() async throws {
        guard !restoredCookies else { return }
        restoredCookies = true
        let captured = epoch
        if UserDefaults.standard.bool(forKey: "antintwrk.explicitlyLoggedOut") {
            try cookieVault?.clear(); return
        }
        guard let saved = try cookieVault?.load() else { return }
        for item in saved.cookies {
            guard captured == epoch else { throw Failure.cancelled }
            if let cookie = item.restored {
                await websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
        guard captured == epoch else { throw Failure.cancelled }
        admittedActor = saved.actor
        custodyVerified = saved.custodyVerified == true
        admittedDomains = Set(saved.cookies.compactMap { $0.restored?.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }
    
    func recordVerifiedCustody(actor: String) async throws {
        guard admittedActor == actor else { throw Failure.rejected }
        custodyVerified = true
        try await persistCookies()
    }
    
    private func persistCookies() async throws {
        guard let actor = admittedActor, let cookieVault else { return }
        let captured = epoch
        let cookies = await websiteDataStore.httpCookieStore.allCookies().filter {
            let host = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            return admittedDomains.contains(host)
        }
        guard captured == epoch else { throw Failure.cancelled }
        try cookieVault.store(.init(actor: actor, cookies: cookies.map(AntintwrkPersistedSocialCookies.Cookie.init), custodyVerified: custodyVerified))
    }
    
    private func boundedResponse(_ request: URLRequest, limit: Int, transport: URLSession? = nil) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await (transport ?? http).bytes(for: request)
        guard response.expectedContentLength <= limit else { throw Failure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
    
    private func requireOK(_ data: Data) throws {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == "OK" || text == "" else { throw Failure.rejected }
    }
}
