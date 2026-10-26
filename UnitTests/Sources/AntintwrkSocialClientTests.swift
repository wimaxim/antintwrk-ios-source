// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Testing
import WebKit

@MainActor
struct AntintwrkSocialClientTests {
    @Test func backgroundInvalidatesProofEvenWhenAppLockIsDisabled() {
        let model = AntintwrkAppModel()
        let service = AppLockServiceMock.mock(pinCode: nil, biometryType: .faceID)
        model.appLockService = service
        model.activityChanged(.active)
        model.activityChanged(.inactive)
        #expect(service.applicationDidEnterBackgroundCallsCount == 0)
        model.activityChanged(.background)
        #expect(service.applicationDidEnterBackgroundCallsCount == 1)
    }
    
    @Test func recentStrongAuthenticationOpensSettingsWithoutPINScreen() {
        let service = AppLockServiceMock.mock(pinCode: "fixture", biometryType: .faceID)
        service.hasRecentStrongAuthentication = true
        let presentation = AntintwrkAppLockPresentation(service: service) { _ in }
        #expect(presentation.navigation.rootCoordinator is AppLockSetupSettingsScreenCoordinator)
        #expect(presentation.navigation.sheetCoordinator == nil)
    }
    
    @Test func fullSocialLogoutClearsLocalLockAndItsPresentation() async {
        let previousLogout = UserDefaults.standard.object(forKey: "antintwrk.explicitlyLoggedOut")
        defer { UserDefaults.standard.set(previousLogout, forKey: "antintwrk.explicitlyLoggedOut") }
        let model = AntintwrkAppModel()
        let service = AppLockServiceMock.mock(pinCode: nil, biometryType: .faceID)
        model.appLockService = service
        model.page = .social
        model.openAppLockSettings()
        #expect(model.appLockPresentation != nil)
        await model.logout()
        #expect(service.disableCallsCount == 1)
        #expect(model.appLockPresentation == nil && !model.commonSettingsPresented)
        #expect(model.page == .welcome && model.messenger == nil)
    }
    
    @Test func appLockSetupDoesNotRequireMessengerAndCannotOpenTwice() {
        let model = AntintwrkAppModel()
        model.page = .social
        model.appLockService = AppLockServiceMock.mock(pinCode: nil, biometryType: .faceID)
        model.openAppLockSettings()
        let first = model.appLockPresentation
        #expect(first != nil && model.messenger == nil)
        #expect(first?.navigation.rootCoordinator != nil)
        #expect(first?.navigation.sheetCoordinator == nil)
        model.openAppLockSettings()
        #expect(model.appLockPresentation === first)
    }
    
    @Test func appLockSetupIsUnavailableOnGuestOrDuringLogout() {
        let model = AntintwrkAppModel()
        model.appLockService = AppLockServiceMock.mock(pinCode: nil, biometryType: .touchID)
        model.page = .login
        model.openAppLockSettings()
        #expect(model.appLockPresentation == nil)
        model.page = .social; model.busy = true
        model.openAppLockSettings()
        #expect(model.appLockPresentation == nil)
    }
    
    @Test func interceptedHandoffCancellationDoesNotAbortOAuth() {
        let interruption = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(AntintwrkMessengerBootstrap.isExpectedNavigationCancellation(interruption, handoffActive: true))
        #expect(!AntintwrkMessengerBootstrap.isExpectedNavigationCancellation(interruption, handoffActive: false))
        #expect(!AntintwrkMessengerBootstrap.isExpectedNavigationCancellation(NSError(domain: NSURLErrorDomain, code: 102), handoffActive: true))
        #expect(!AntintwrkMessengerBootstrap.isExpectedNavigationCancellation(URLError(.timedOut), handoffActive: true))
        #expect(AntintwrkMessengerBootstrap.isExpectedNavigationCancellation(URLError(.cancelled), handoffActive: false))
    }
    
    @Test func webKitRecognizesNavigationAndDialogDelegates() throws {
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: .nonPersistent())
        let surface = AntintwrkSocialSurface(client: client, origin: .global, language: "en", loadInitially: false)
        defer { surface.invalidate() }
        for selector in ["webView:decidePolicyForNavigationAction:decisionHandler:",
                         "webView:decidePolicyForNavigationResponse:decisionHandler:",
                         "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
                         "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
                         "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:"] {
            #expect(surface.responds(to: NSSelectorFromString(selector)))
        }
        #expect(AntintwrkMessengerBootstrap.instancesRespond(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
    }
    
    @Test func accountFormSwitchClearsSecretsAndGoogleCompletion() {
        let model = AntintwrkAppModel()
        model.page = .register
        model.email = "fixture@example.invalid"
        model.password = "fixture"; model.code = "123456"; model.agreed = true
        model.googleRegistrationTicket = String(repeating: "a", count: 64)
        model.error = "fixture"
        model.switchAccountForm(to: .login)
        #expect(model.page == .login && model.email == "fixture@example.invalid")
        #expect(model.password.isEmpty && model.code.isEmpty && !model.agreed)
        #expect(model.googleRegistrationTicket == nil && model.error == nil)
        model.switchAccountForm(to: .register)
        #expect(model.page == .register && !model.agreed)
    }
    
    @Test func accountFormCannotSwitchWhileAnAuthenticationResponseIsPending() {
        let model = AntintwrkAppModel()
        model.page = .login; model.busy = true; model.password = "fixture"
        model.switchAccountForm(to: .register)
        #expect(model.page == .login && model.password == "fixture" && model.busy)
    }
    
    @Test func admissionRejectsForeignActorAndMalformedCSRF() throws {
        let csrf = String(repeating: "a", count: 64)
        #expect(throws: (any Error).self) { try admission(actor: "@u1:evil.test", csrf: csrf).validated() }
        #expect(throws: (any Error).self) { try admission(actor: "@u01:antintwrk.com", csrf: csrf).validated() }
        #expect(throws: (any Error).self) { try admission(actor: "@u1:antintwrk.com", csrf: "short").validated() }
        #expect(try admission(actor: "@u18:antintwrk.com", csrf: csrf).validated().stage == .authenticated)
    }
    
    @Test func logoutDeletesDomainPathAndHTTPOnlyCookies() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: store)
        for (domain, path) in [(".antimsg.com", "/"), ("antimsg.com", "/en"), (".antintwrk.com", "/")] {
            let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "fixture", .domain: domain, .path: path, .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
            await store.httpCookieStore.setCookie(cookie)
        }
        #expect(await store.httpCookieStore.allCookies().count == 3)
        await client.logout(admission: nil, origin: .russian)
        #expect(await store.httpCookieStore.allCookies().isEmpty)
    }
    
    @Test func retainedNavigationDoesNotReplaceOtherRoots() throws {
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: .nonPersistent())
        let surface = AntintwrkSocialSurface(client: client, origin: .global, language: "en", loadInitially: false)
        surface.invalidate()
        let feed = surface.pages[0]
        let communities = surface.pages[1]
        let profile = surface.pages[2]
        #expect(feed !== communities && communities !== profile)
        #expect(surface.rootURL(0).host == "antintwrk.com")
        #expect(surface.rootURL(1).path == "/en/communities")
        #expect(surface.rootURL(2).path == "/en/profile")
    }
    
    @Test func unauthenticatedLegalReaderHasItsOwnNarrowPolicy() throws {
        let policy = try AntintwrkSocialWebPolicy(origin: .russian, configuration: .init(productVersion: "1.0.26"))
        let termsURL = try #require(URL(string: "https://antimsg.com/ru/useragreement?app=1"))
        let profileURL = try #require(URL(string: "https://antimsg.com/ru/profile"))
        let foreignURL = try #require(URL(string: "https://evil.test/ru/terms"))
        let legal = try #require(policy.legalReaderURL(termsURL))
        #expect(legal.query == "native_legal=1")
        #expect(policy.legalReaderURL(profileURL) == nil)
        #expect(policy.legalReaderURL(foreignURL) == nil)
    }
    
    @Test func sessionCookieRestoresWithoutExtendingServerExpiryAndLogoutRemovesVault() async throws {
        let previousLogout = UserDefaults.standard.object(forKey: "antintwrk.explicitlyLoggedOut")
        UserDefaults.standard.set(false, forKey: "antintwrk.explicitlyLoggedOut")
        defer { UserDefaults.standard.set(previousLogout, forKey: "antintwrk.explicitlyLoggedOut") }
        let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "fixture", .domain: ".antimsg.com", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
        let vault = CookieVaultFixture()
        vault.value = .init(actor: "@u18:antintwrk.com", cookies: [.init(cookie)])
        let data = try JSONEncoder().encode(vault.value)
        let decoded = try JSONDecoder().decode(AntintwrkPersistedSocialCookies.self, from: data)
        let restored = try #require(decoded.cookies.first?.restored)
        #expect(restored.isSecure && restored.isHTTPOnly)
        #expect(restored.expiresDate == nil)
        let store = WKWebsiteDataStore.nonPersistent()
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: store, cookieVault: vault)
        try await client.restoreCookiesIfNeeded()
        #expect(await store.httpCookieStore.allCookies().count == 1)
        await client.logout(admission: nil, origin: .russian)
        #expect(vault.value == nil)
        #expect(await store.httpCookieStore.allCookies().isEmpty)
    }
    
    @Test func admittedSessionPersistsBothDomainsAndRejectsAccountConflict() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let vault = CookieVaultFixture()
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: store, cookieVault: vault)
        for domain in [".antimsg.com", ".antintwrk.com", "foreign.test"] {
            let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "fixture", .domain: domain, .path: "/", .secure: "TRUE"]))
            await store.httpCookieStore.setCookie(cookie)
        }
        let first = admission(actor: "@u18:antintwrk.com", csrf: String(repeating: "a", count: 64))
        try await client.recordAdmission(first, origin: .russian)
        #expect(vault.value?.cookies.count == 1)
        try await client.recordAdmission(first, origin: .global)
        #expect(vault.value?.cookies.count == 2)
        do {
            try await client.recordAdmission(admission(actor: "@u19:antintwrk.com", csrf: first.csrf), origin: .global)
            Issue.record("A foreign actor must not replace the admitted vault")
        } catch { }
        #expect(vault.value?.actor == first.matrixUserId)
        try await client.clearForExplicitLogin()
        #expect(vault.value == nil)
    }
    
    @Test func verifiedCustodySurvivesSocialLoginExpiryButNotExplicitLogout() async throws {
        let previousLogout = UserDefaults.standard.object(forKey: "antintwrk.explicitlyLoggedOut")
        UserDefaults.standard.set(false, forKey: "antintwrk.explicitlyLoggedOut")
        defer { UserDefaults.standard.set(previousLogout, forKey: "antintwrk.explicitlyLoggedOut") }
        let vault = CookieVaultFixture()
        vault.value = .init(actor: "@u18:antintwrk.com", cookies: [], custodyVerified: true)
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.0"), websiteDataStore: .nonPersistent(), cookieVault: vault)
        try await client.restoreCookiesIfNeeded()
        #expect(client.cachedMessengerActor == "@u18:antintwrk.com")
        try await client.recordAdmission(.init(stage: .login, csrf: String(repeating: "a", count: 64), profileIdentity: nil, matrixUserId: nil, domainBinding: nil), origin: .russian)
        #expect(client.cachedMessengerActor == "@u18:antintwrk.com")
        try await client.clearForExplicitLogin()
        #expect(client.cachedMessengerActor == nil)
        #expect(vault.value == nil)
    }
    
    @Test func custodyCannotBeClaimedForAnotherAccount() async throws {
        let vault = CookieVaultFixture()
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.0"), websiteDataStore: .nonPersistent(), cookieVault: vault)
        try await client.recordAdmission(admission(actor: "@u18:antintwrk.com", csrf: String(repeating: "a", count: 64)), origin: .russian)
        #expect(client.cachedMessengerActor == nil)
        do {
            try await client.recordVerifiedCustody(actor: "@u19:antintwrk.com")
            Issue.record("Custody must belong to the admitted account")
        } catch { }
        #expect(client.cachedMessengerActor == nil)
        try await client.recordVerifiedCustody(actor: "@u18:antintwrk.com")
        #expect(client.cachedMessengerActor == "@u18:antintwrk.com")
    }
    
    @Test func realDeviceOnlyKeychainVaultRoundTrip() throws {
        let vault = AntintwrkSocialCookieVault()
        try vault.clear()
        defer { try? vault.clear() }
        let cookie = try #require(HTTPCookie(properties: [.name: "fixture", .value: "fixture", .domain: ".antimsg.com", .path: "/", .secure: "TRUE"]))
        try vault.store(.init(actor: "@u18:antintwrk.com", cookies: [.init(cookie)]))
        let loaded = try vault.load()
        let restored = try #require(loaded)
        #expect(restored.actor == "@u18:antintwrk.com")
        #expect(restored.cookies.count == 1)
        try vault.clear()
        #expect(try vault.load() == nil)
    }
    
    @Test func expiredAndForeignCookiesNeverRestore() throws {
        let expired = try #require(HTTPCookie(properties: [.name: "session", .value: "fixture", .domain: "antimsg.com", .path: "/", .secure: "TRUE", .expires: Date.distantPast]))
        let foreign = try #require(HTTPCookie(properties: [.name: "session", .value: "fixture", .domain: "evil.test", .path: "/", .secure: "TRUE"]))
        #expect(AntintwrkPersistedSocialCookies.Cookie(expired).restored == nil)
        #expect(AntintwrkPersistedSocialCookies.Cookie(foreign).restored == nil)
    }
    
    @Test func termsLinkKeepsWordsTogetherOnlyWhenItFits() {
        let font = UIFont.systemFont(ofSize: 13)
        let rules = "Terms of ANTINTWRK"
        let fitting = AntintwrkTermsNotice.text(format: "By signing in, you agree to the %1$@.", rules: rules, font: font, width: 320)
        #expect(String(fitting.characters).replacingOccurrences(of: "\u{2060}", with: "").contains("Terms\u{00A0}of\u{00A0}ANTINTWRK"))
        let overflowing = AntintwrkTermsNotice.text(format: "By signing in, you agree to the %1$@.", rules: rules, font: .systemFont(ofSize: 60), width: 100)
        #expect(String(overflowing.characters).contains(rules))
        #expect(!String(overflowing.characters).contains("\u{00A0}"))
        let chineseRules = "ANTINTWRK 使用条款"
        let chinese = AntintwrkTermsNotice.text(format: "登录即表示您同意%1$@。", rules: chineseRules, font: font, width: 320)
        #expect(String(chinese.characters).contains("\u{2060}"))
        #expect(String(chinese.characters).replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ") == String(format: "登录即表示您同意%1$@。", chineseRules))
    }
    
    @Test func googleOptionsBindAudienceNonceAndOneTimeTicket() throws {
        let audience = "fixture.apps.googleusercontent.com"
        let valid = AntintwrkGoogleOptions(clientId: audience, nonce: String(repeating: "a", count: 43), ticket: String(repeating: "b", count: 64))
        #expect(try valid.validated(serverClientID: audience).ticket == valid.ticket)
        #expect(throws: (any Error).self) { try valid.validated(serverClientID: "foreign.apps.googleusercontent.com") }
        #expect(throws: (any Error).self) { try AntintwrkGoogleOptions(clientId: audience, nonce: "short", ticket: valid.ticket).validated(serverClientID: audience) }
        #expect(throws: (any Error).self) { try AntintwrkGoogleOptions(clientId: audience, nonce: valid.nonce, ticket: "short").validated(serverClientID: audience) }
    }
    
    @Test func googleRegistrationRequiresAnOpaqueValidTicket() throws {
        let registration = AntintwrkGoogleRegistration(registrationTicket: String(repeating: "c", count: 64), email: "fixture@example.com", firstName: "Fixture", surname: "Account")
        #expect(try registration.validated().email == registration.email)
        #expect(throws: (any Error).self) { try AntintwrkGoogleRegistration(registrationTicket: "bad", email: registration.email, firstName: "", surname: "").validated() }
    }
    
    @Test func licencesIncludeBundledChildNoticesAndGoogleSDK() {
        let rows = AntintwrkLicencesScreen.acknowledgementRows()
        #expect(rows.contains { $0["Title"] as? String == "DeviceKit" && !($0["FooterText"] as? String ?? "").isEmpty })
        #expect(rows.contains { $0["Title"] as? String == "googlesignin-ios" && ($0["FooterText"] as? String ?? "").contains("Apache") })
    }
    
    private func admission(actor: String, csrf: String) -> AntintwrkSocialAdmission {
        .init(stage: .authenticated, csrf: csrf, profileIdentity: "fixture", matrixUserId: actor, domainBinding: nil)
    }
}

@MainActor
private final class CookieVaultFixture: AntintwrkSocialCookieVaultProtocol {
    var value: AntintwrkPersistedSocialCookies?
    func load() -> AntintwrkPersistedSocialCookies? {
        value
    }
    
    func store(_ value: AntintwrkPersistedSocialCookies) {
        self.value = value
    }
    
    func clear() {
        value = nil
    }
}
