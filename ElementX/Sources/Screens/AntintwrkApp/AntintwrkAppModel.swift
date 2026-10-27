// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import SwiftUI

@MainActor
@Observable
final class AntintwrkAppModel {
    enum Page { case welcome, login, register, reset, challenge, mailSent, social }
    var page: Page = .welcome
    var needsSocialLogin = false
    var accountPage: Page {
        needsSocialLogin && page == .social ? .login : page
    }
    
    var busy = false
    var booting = true
    var error: String?
    var email = ""
    var password = ""
    var firstName = ""
    var surname = ""
    var birthday = Calendar(identifier: .gregorian).date(byAdding: .year, value: -18, to: Date()) ?? .distantPast
    var agreed = false
    var code = ""
    var googleRegistrationTicket: String?
    var appleRegistrationTicket: String?
    var hasProviderRegistration: Bool {
        googleRegistrationTicket != nil || appleRegistrationTicket != nil
    }
    
    var registered = false
    var admission: AntintwrkSocialAdmission?
    var social: AntintwrkSocialSurface?
    var legalURL: URL?
    var licencesPresented = false
    var commonSettingsPresented = false
    var appLockPresentation: AntintwrkAppLockPresentation?
    var appLockService: AppLockServiceProtocol?
    var settingsPresentation: AntintwrkSettingsPresentation?
    var messenger: AntintwrkMessengerPresentation?
    private let sharedDefaults = UserDefaults(suiteName: InfoPlistReader.main.appGroupIdentifier)
    var accountActor: String? {
        admission?.matrixUserId ?? client.cachedMessengerActor
    }
    
    var notificationsCount = 0
    var profileName: String?
    var profileImage: UIImage?
    private var profileSource: String?
    private var statusTask: Task<Void, Never>?
    var unreadCount: UInt = 0
    private var unreadSubscription: AnyCancellable?
    var messengerFailed = false
    private var messengerTask: Task<Void, Never>?
    private var actorEpoch = UUID()
    private var pendingShare: ShareExtensionPayload?
    private var pendingSDKRoute: AppRoute?
    private var pendingDestination: AntintwrkSocialWebPolicy.MessengerDestination?
    private var destinationTask: Task<Void, Never>?
    private let prepareMessenger: ((AntintwrkSocialClient, AntintwrkSocialAdmission) async throws -> AntintwrkMessengerPresentation)?
    private let messengerReady: ((AntintwrkMessengerPresentation) -> Void)?
    private let messengerEnded: (() -> Void)?
    private let storeBridge: AntintwrkStoreBridge
    let socialPush: AntintwrkSocialPush
    private var pendingSocialNotification: [AnyHashable: Any]?
    let client: AntintwrkSocialClient
    let welcome = AntintwrkWelcomeScreenViewModel()
    let loading = AntintwrkWelcomeScreenViewModel(isLoading: true)
    var language: String
    private var geographyMonitor: AntintwrkGeographyMonitor?
    private struct PreparedOrigin {
        let origin: AntintwrkClientConfiguration.SocialOrigin
        let actor: String
        let epoch: UUID
        let date: Date
    }
    
    private var pendingOrigin: PreparedOrigin?
    private var visibleDuration: Duration = .zero
    private var foregroundEpoch = UUID()
    private var visibleSince: ContinuousClock.Instant?
    
    init(prepareMessenger: ((AntintwrkSocialClient, AntintwrkSocialAdmission) async throws -> AntintwrkMessengerPresentation)? = nil,
         messengerReady: ((AntintwrkMessengerPresentation) -> Void)? = nil, messengerEnded: (() -> Void)? = nil) {
        self.prepareMessenger = prepareMessenger; self.messengerReady = messengerReady; self.messengerEnded = messengerEnded
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        guard let configuration = try? AntintwrkClientConfiguration(productVersion: version) else { fatalError("Invalid product version in app bundle") }
        client = AntintwrkSocialClient(configuration: configuration)
        socialPush = AntintwrkSocialPush(client: client)
        let store = AntintwrkStoreKit(driver: AntintwrkAppleStoreDriver(), server: AntintwrkHTTPStoreServer(transport: client), pending: AntintwrkStorePendingKeychain())
        storeBridge = AntintwrkStoreBridge(transport: client, store: store)
        let requested = (UserDefaults.standard.string(forKey: "antintwrk.language") ?? Locale.preferredLanguages.first ?? "en").split(separator: "-").first.map(String.init) ?? "en"
        language = AntintwrkClientConfiguration.supportedLanguages.contains(requested) ? requested : "en"
    }
    
    func bootstrap() async {
        MXLog.info("Social startup: preparing transport")
        do { try await client.prepareRegionalTransport() }
        catch { self.error = text("screen_ant_auth_request_error"); booting = false; return }
        geographyMonitor = AntintwrkGeographyMonitor { [weak self] in await self?.prepareGeography() }
        geographyMonitor?.setActive(visibleSince != nil)
        if !UserDefaults.standard.bool(forKey: "antintwrk.socialInstallation") {
            sharedDefaults?.removeObject(forKey: "antintwrk.activeMessengerActor")
            do { try await client.clearForExplicitLogin() }
            catch { self.error = text("screen_ant_auth_request_error"); booting = false; return }
            UserDefaults.standard.set(true, forKey: "antintwrk.socialInstallation")
        }
        if !UserDefaults.standard.bool(forKey: "antintwrk.explicitlyLoggedOut") {
            MXLog.info("Social startup: restoring admission")
            let existing = try? await client.session()
            MXLog.info("Social startup: admission request complete")
            if let existing, existing.stage != .login {
                await accept(existing)
            } else if let actor = client.cachedMessengerActor {
                needsSocialLogin = true
                sharedDefaults?.set(actor, forKey: "antintwrk.activeMessengerActor")
                let cached = AntintwrkSocialAdmission(stage: .login, csrf: existing?.csrf ?? "", profileIdentity: nil, matrixUserId: actor, domainBinding: nil)
                admission = cached; social = makeSocialSurface(origin: .russian); page = .social
                startMessenger(cached)
            }
        }
        MXLog.info("Social startup: waiting for minimum visible duration")
        while visibleDuration + (visibleSince?.duration(to: .now) ?? .zero) < .seconds(2) {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        booting = false
        MXLog.info("Social startup: ready")
        if let pendingSocialNotification {
            self.pendingSocialNotification = nil
            handleSocialNotification(pendingSocialNotification)
        }
    }
    
    func applicationActivityChanged(_ state: UIApplication.State) {
        switch state {
        case .active: activityChanged(.active)
        case .inactive: activityChanged(.inactive)
        case .background: activityChanged(.background)
        @unknown default: activityChanged(.inactive)
        }
    }
    
    func activityChanged(_ phase: ScenePhase) {
        MXLog.verbose("Social lifecycle: \(String(describing: phase)), startup \(booting)")
        if phase == .background {
            foregroundEpoch = UUID()
            if let appLockService, !appLockService.isEnabled {
                appLockService.applicationDidEnterBackground()
            }
        }
        geographyMonitor?.setActive(phase == .active)
        if phase == .active, admission?.stage == .authenticated {
            Task { await socialPush.requestPermission(); await socialPush.refresh() }
        }
        guard booting else { return }
        if let visibleSince {
            visibleDuration += visibleSince.duration(to: .now)
        }
        visibleSince = phase == .active ? .now : nil
    }
    
    func switchAccountForm(to destination: Page) {
        guard !busy, destination == .login || destination == .register || destination == .reset else { return }
        password = ""; code = ""; agreed = false; googleRegistrationTicket = nil; appleRegistrationTicket = nil
        error = nil; legalURL = nil
        page = destination
    }
    
    func submit() async {
        guard !busy else { return }
        error = nil
        busy = true
        defer { busy = false; password = ""; code = "" }
        do {
            switch accountPage {
            case .login:
                guard email.contains("@"), !password.isEmpty else { error = text("screen_ant_auth_login_fields"); return }
                if !needsSocialLogin {
                    UserDefaults.standard.set(true, forKey: "antintwrk.explicitlyLoggedOut")
                    try await client.clearForExplicitLogin()
                }
                try await accept(client.login(email: email, password: password, language: language))
            case .register, .reset:
                let registering = page == .register
                guard email.contains("@") else { error = text("screen_ant_auth_login_fields"); return }
                if registering {
                    guard !firstName.trimmingCharacters(in: .whitespaces).isEmpty, agreed,
                          birthday <= (Calendar(identifier: .gregorian).date(byAdding: .year, value: -18, to: Date()) ?? .distantPast) else { error = text("screen_ant_auth_profile_requirements"); return }
                    guard hasProviderRegistration || ((8...128).contains(password.count) && password.contains(where: \.isUppercase) && password.contains(where: \.isLowercase) && password.contains(where: \.isNumber) && password.contains(where: { !$0.isLetter && !$0.isNumber })) else { error = text("screen_ant_auth_password_requirements"); return }
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.dateFormat = "yyyy-MM-dd"
                if registering, let ticket = appleRegistrationTicket {
                    try await accept(client.registerApple(ticket: ticket, fields: ["yourname": firstName, "surname": surname, "birthdate": formatter.string(from: birthday), "agreement": agreed ? "1" : "0", "lng": language]))
                    appleRegistrationTicket = nil
                    return
                }
                if registering, let ticket = googleRegistrationTicket {
                    try await accept(client.registerGoogle(ticket: ticket, fields: ["yourname": firstName, "surname": surname, "birthdate": formatter.string(from: birthday), "agreement": agreed ? "1" : "0", "lng": language]))
                    googleRegistrationTicket = nil
                    return
                }
                try await client.requestAccount(action: registering ? "register" : "reset", fields: ["email": email, "password": password, "yourname": firstName, "surname": surname, "birthdate": formatter.string(from: birthday), "agreement": agreed ? "1" : "0", "lng": language])
                registered = registering
                page = .mailSent
            case .challenge:
                guard let admission, !code.isEmpty else { return }
                try await accept(client.confirm(admission, code: code))
            default: break
            }
        } catch {
            MXLog.error("Native account request failed; category \(String(describing: type(of: error))); code \((error as NSError).code)")
            self.error = text("screen_ant_auth_request_error")
        }
    }
    
    func google() async {
        guard !busy, let window = social?.active.window ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow), var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        busy = true; error = nil
        defer { busy = false; password = "" }
        do {
            if !needsSocialLogin {
                UserDefaults.standard.set(true, forKey: "antintwrk.explicitlyLoggedOut")
                try await client.clearForExplicitLogin()
            }
            try await accept(client.signInWithGoogle(presenting: presenter))
        } catch let registration as AntintwrkGoogleRegistration {
            appleRegistrationTicket = nil
            googleRegistrationTicket = registration.registrationTicket
            email = registration.email; firstName = registration.firstName; surname = registration.surname
            agreed = false; page = .register
        } catch {
            if (error as NSError).domain == "com.google.GIDSignIn", (error as NSError).code == -5 {
                return
            }
            self.error = text("screen_ant_auth_request_error")
        }
    }
    
    func apple() async {
        guard !busy, let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let authenticationActorEpoch = actorEpoch
        busy = true
        error = nil
        defer { busy = false; password = "" }
        do {
            if !needsSocialLogin {
                UserDefaults.standard.set(true, forKey: "antintwrk.explicitlyLoggedOut")
                try await client.clearForExplicitLogin()
            }
            let admission = try await client.signInWithApple(anchor: window)
            guard authenticationActorEpoch == actorEpoch else { return }
            try await accept(admission)
        } catch let registration as AntintwrkGoogleRegistration {
            guard authenticationActorEpoch == actorEpoch else { return }
            googleRegistrationTicket = nil
            appleRegistrationTicket = registration.registrationTicket
            email = registration.email
            firstName = registration.firstName
            surname = registration.surname
            agreed = false
            page = .register
        } catch is CancellationError { }
        catch {
            guard authenticationActorEpoch == actorEpoch else { return }
            self.error = text("screen_antintwrk_apple_error")
        }
    }
    
    func passkey() async {
        let authenticationForegroundEpoch = foregroundEpoch
        guard !busy, let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if !needsSocialLogin {
                UserDefaults.standard.set(true, forKey: "antintwrk.explicitlyLoggedOut")
                try await client.clearForExplicitLogin()
            }
            let verified = try await client.signInWithPasskey(anchor: window)
            try await accept(verified)
            if verified.stage == .authenticated, let actor = verified.matrixUserId,
               admission?.matrixUserId == actor, page == .social, foregroundEpoch == authenticationForegroundEpoch {
                appLockService?.recordSuccessfulPasskeyAuthentication()
            }
        } catch is CancellationError { }
        catch { self.error = text("screen_ant_auth_request_error") }
    }
    
    func openAppLockSettings() {
        guard page == .social, !busy, appLockPresentation == nil, let appLockService else { return }
        let epoch = actorEpoch
        appLockPresentation = AntintwrkAppLockPresentation(service: appLockService) { [weak self] forceLogout in
            guard let self, actorEpoch == epoch else { return }
            appLockPresentation = nil
            if forceLogout {
                Task { await self.logout() }
            }
        }
    }
    
    func logout() async {
        guard !busy else { return }
        busy = true
        storeBridge.activate(actor: nil)
        do { try await messenger?.logout() } catch {
            if admission?.stage == .authenticated {
                storeBridge.activate(actor: admission?.matrixUserId)
            }
            busy = false; self.error = text("screen_ant_auth_request_error"); return
        }
        actorEpoch = UUID()
        storeBridge.activate(actor: nil)
        sharedDefaults?.removeObject(forKey: "antintwrk.activeMessengerActor")
        messengerTask?.cancel(); messengerTask = nil
        messenger = nil
        pendingSocialNotification = nil
        pendingShare = nil; pendingSDKRoute = nil; pendingDestination = nil; destinationTask?.cancel(); destinationTask = nil
        unreadSubscription = nil; unreadCount = 0
        appLockService?.disable()
        messengerEnded?()
        UserDefaults.standard.set(true, forKey: "antintwrk.explicitlyLoggedOut")
        appLockPresentation = nil; settingsPresentation = nil; commonSettingsPresented = false; pendingOrigin = nil
        statusTask?.cancel(); statusTask = nil; notificationsCount = 0; profileImage = nil; profileName = nil; profileSource = nil
        social?.invalidate()
        social = nil
        await socialPush.deactivate()
        await client.logout(admission: admission, origin: .russian)
        admission = nil; needsSocialLogin = false
        googleRegistrationTicket = nil
        appleRegistrationTicket = nil
        email = ""; password = ""; code = ""; firstName = ""; surname = ""; agreed = false
        page = .welcome
        busy = false
    }
    
    func accept(_ result: AntintwrkSocialAdmission) async {
        admission = result
        switch result.stage {
        case .authenticated:
            storeBridge.activate(actor: result.matrixUserId)
            sharedDefaults?.set(result.matrixUserId, forKey: "antintwrk.activeMessengerActor")
            needsSocialLogin = false
            let target = await client.recommendedOrigin()
            let chosen = await target == .global ? (try? client.transfer(result, to: target)) : result
            let origin: AntintwrkClientConfiguration.SocialOrigin = chosen == nil ? .russian : target
            social = makeSocialSurface(origin: origin)
            UserDefaults.standard.set(false, forKey: "antintwrk.explicitlyLoggedOut")
            page = .social
            socialPush.activate(actor: result.matrixUserId!, language: language)
            if let pendingSocialNotification {
                self.pendingSocialNotification = nil
                handleSocialNotification(pendingSocialNotification)
            }
            startStatus(actor: result.matrixUserId!)
            if let pendingShare {
                self.pendingShare = nil; handleSDKRoute(.share(pendingShare))
            }
            startMessenger(result)
        case .device:
            page = .challenge
            do { try await client.startDevice(result) } catch { self.error = text("screen_ant_auth_request_error") }
        case .totp: page = .challenge
        case .setupRequired: page = .challenge; error = text("screen_ant_auth_setup")
        case .login: page = .welcome
        }
    }
    
    private func startStatus(actor: String) {
        statusTask?.cancel()
        let epoch = actorEpoch
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                guard let self, epoch == actorEpoch, admission?.matrixUserId == actor else { return }
                if UIApplication.shared.applicationState == .active {
                    do {
                        let status = try await client.socialStatus(actor: actor)
                        guard epoch == actorEpoch, !Task.isCancelled else { return }
                        notificationsCount = status.count; profileName = status.name; social?.profileIdentity = status.identity
                        if status.avatar != profileSource, let social {
                            let image: UIImage?
                            if let source = status.avatar {
                                image = try await client.avatar(source, origin: social.origin)
                            } else {
                                image = nil
                            }
                            guard epoch == actorEpoch, !Task.isCancelled else { return }
                            profileImage = image; profileSource = status.avatar
                        }
                    } catch { /* Optional counters must not change account admission or reset the feed. */ }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    
    private func prepareGeography() async {
        let epoch = actorEpoch
        let target = await client.recommendedOrigin()
        guard let social, social.origin != target, let actor = admission?.matrixUserId else { return }
        do {
            let current = try await client.session()
            guard current.stage == .authenticated, current.matrixUserId == actor else { return }
            if target == .global {
                _ = try await client.transfer(current, to: target)
            }
            guard epoch == actorEpoch, admission?.matrixUserId == actor else { return }
            pendingOrigin = PreparedOrigin(origin: target, actor: actor, epoch: epoch, date: Date())
        } catch { /* A failed geography preparation keeps the working surface. */ }
    }
    
    private func makeSocialSurface(origin: AntintwrkClientConfiguration.SocialOrigin) -> AntintwrkSocialSurface {
        let surface = AntintwrkSocialSurface(client: client, origin: origin, language: language)
        if let identity = admission?.profileIdentity, identity.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil {
            surface.profileIdentity = identity
        }
        surface.beforeNavigation = { [weak self] route in self?.applyPreparedOrigin(route: route) ?? false }
        surface.onNavigationFailure = { [weak self] in self?.error = AntintwrkStrings.value("screen_ant_auth_request_error") }
        surface.onShareFailure = { [weak self] in self?.error = AntintwrkStrings.value("screen_ant_share_failed") }
        let storeActor = admission?.matrixUserId
        surface.onStoreRequest = { [weak self, weak surface] message in
            guard let self, let surface, social === surface, !busy, admission?.stage == .authenticated, let actor = storeActor, admission?.matrixUserId == actor else { throw AntintwrkStoreKit.Failure.accountChanged }
            return try await storeBridge.request(message, actor: actor)
        }
        storeBridge.onUpdated = { [weak self] actor in
            guard let self, admission?.stage == .authenticated, admission?.matrixUserId == actor else { return }
            social?.notifyStoreUpdated()
        }
        return surface
    }
    
    private func applyPreparedOrigin(route: String) -> Bool {
        guard !storeBridge.protectsNavigation, let pendingOrigin, pendingOrigin.epoch == actorEpoch, pendingOrigin.actor == admission?.matrixUserId,
              Date().timeIntervalSince(pendingOrigin.date) < 180, let social, !social.keyboardVisible, social.protectedInput.isEmpty,
              !["kindness", "verification"].contains(social.active.url?.path.split(separator: "/").dropFirst().first.map(String.init) ?? "") else { return false }
        self.pendingOrigin = nil
        social.invalidate()
        let replacement = makeSocialSurface(origin: pendingOrigin.origin)
        self.social = replacement
        if route == "communities" {
            replacement.select(1)
        } else if route == "profile" {
            replacement.select(2)
        } else if route != "hero-feed" {
            replacement.open(route)
        }
        return true
    }
    
    func revealIncomingCall(actor: String?) {
        guard let actor, actor == accountActor, let messenger,
              messenger.session.clientProxy.userID == actor, let social else { return }
        destinationTask?.cancel(); destinationTask = nil
        pendingDestination = nil; pendingSDKRoute = nil
        social.messengerDestination = nil
        commonSettingsPresented = false; licencesPresented = false; settingsPresentation = nil
        social.messenger = true
    }
    
    func handleSDKRoute(_ route: AppRoute) {
        if case .share(let payload) = route, payload.roomID == nil {
            if let social {
                do { try social.openShare(AntintwrkIncomingShare(payload)) }
                catch { self.error = text("screen_ant_auth_request_error") }
            } else {
                pendingShare = payload
            }
            return
        }
        if case .settings = route {
            openSettings(); return
        }
        if case .chatBackupSettings = route {
            openSettings(); return
        }
        pendingSDKRoute = route
        guard let messenger else { return }
        social?.messenger = true
        messenger.flow.handleAppRoute(route, animated: false)
        pendingSDKRoute = nil
    }
    
    func messengerAuthFailed() {
        messengerFailed = true
        let failedPresentation = messenger
        let epoch = actorEpoch
        Task { [weak self] in
            guard let self else { return }
            await failedPresentation?.bootstrap.cancel()
            await failedPresentation?.session.clientProxy.pauseServices()
            guard epoch == actorEpoch else { return }
            messenger = nil
            unreadSubscription = nil; unreadCount = 0
            messengerEnded?()
        }
    }
    
    var preferredLanguage: String {
        UserDefaults.standard.string(forKey: "antintwrk.language") ?? ""
    }
    
    func changeLanguage(_ selected: String) {
        guard selected.isEmpty || AntintwrkClientConfiguration.supportedLanguages.contains(selected), let social else { return }
        if selected.isEmpty {
            UserDefaults.standard.removeObject(forKey: "antintwrk.language")
            let system = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en"
            language = AntintwrkClientConfiguration.supportedLanguages.contains(system) ? system : "en"
        } else {
            language = selected; UserDefaults.standard.set(selected, forKey: "antintwrk.language")
        }
        socialPush.updateLanguage(language)
        if social.protectedInput.isEmpty, !social.keyboardVisible {
            social.invalidate(); self.social = makeSocialSurface(origin: social.origin)
        }
    }
    
    func handleSocialNotification(_ info: [AnyHashable: Any]) {
        guard let binding = AntintwrkSocialPushBinding.load(from: sharedDefaults), binding.matches(info) else { return }
        if booting {
            pendingSocialNotification = info; return
        }
        guard admission?.stage == .authenticated, admission?.matrixUserId == binding.actor else { return }
        commonSettingsPresented = false
        social?.messenger = false
        social?.open("notifications")
    }
    
    func openSettings() {
        commonSettingsPresented = true
    }
    
    func openMessengerSettings() {
        guard let messenger else { social?.messenger = false; social?.open("profile/settings"); return }
        settingsPresentation = messenger.settingsFactory(social?.origin.versionSuffix ?? "R") { [weak self] route in
            guard let self else { return }
            if route == "logout" {
                Task { await self.logout() }; return
            }
            settingsPresentation = nil
            if route == "close" {
                return
            }
            if route.hasPrefix("language:") {
                let selected = String(route.dropFirst(9))
                guard AntintwrkClientConfiguration.supportedLanguages.contains(selected), let social else { return }
                changeLanguage(selected)
            } else {
                social?.messenger = false; social?.open(route)
            }
        }
    }
    
    func openMessenger(_ destination: AntintwrkSocialWebPolicy.MessengerDestination) {
        pendingDestination = destination
        guard let messenger else { return }
        destinationTask?.cancel()
        let epoch = actorEpoch
        destinationTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch destination {
                case .chats: messenger.showChats()
                case .user(let id), .legacyRoom(let id):
                    let target: String
                    if case .legacyRoom = destination {
                        target = "room:" + id
                    } else {
                        target = id
                    }
                    let recipient = try await client.resolveSocialRecipient(target: target, actor: messenger.directory.actor)
                    let roomID = try await messenger.directory.resolve(recipient: recipient)
                    guard !Task.isCancelled, epoch == actorEpoch else { return }
                    AntintwrkHiddenChats(actor: messenger.directory.actor).reveal(roomID)
                    messenger.flow.handleAppRoute(.room(roomID: roomID, via: []), animated: false)
                }
                guard epoch == actorEpoch else { return }
                pendingDestination = nil; social?.messengerDestination = nil
            } catch {
                guard !Task.isCancelled, epoch == actorEpoch else { return }
                self.error = text("screen_ant_auth_request_error")
            }
        }
    }
    
    func retryMessenger() {
        if let admission {
            startMessenger(admission)
        }
    }
    
    private func startMessenger(_ admission: AntintwrkSocialAdmission) {
        guard let prepareMessenger, messenger == nil else { return }
        guard messengerTask == nil else { return }
        messengerFailed = false
        let epoch = actorEpoch
        messengerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == actorEpoch {
                    messengerTask = nil
                }
            }
            for attempt in 0..<5 {
                do {
                    try Task.checkCancellation()
                    let presentation = try await prepareMessenger(client, admission)
                    guard !Task.isCancelled, epoch == actorEpoch, self.accountActor == admission.matrixUserId else {
                        await presentation.bootstrap.cancel()
                        await presentation.session.clientProxy.pauseServices(); return
                    }
                    messenger = presentation
                    unreadSubscription = presentation.session.clientProxy.staticRoomSummaryProvider.roomListPublisher
                        .receive(on: DispatchQueue.main).sink { [weak self] rooms in
                            guard let self, epoch == actorEpoch else { return }
                            unreadCount = rooms.filter {
                                !$0.isSpace && !$0.isTombstoned && !($0.isDirect && AntintwrkHiddenChats(actor: presentation.session.clientProxy.userID).isHidden($0.id, lastMessage: $0.lastMessageDate))
                            }.reduce(0) {
                                $0 + ($1.joinRequestType?.isInvite == true ? max(1, $1.unreadMessagesCount) : $1.unreadMessagesCount)
                            }
                        }
                    messengerReady?(presentation)
                    if let pendingDestination {
                        openMessenger(pendingDestination)
                    }
                    return
                } catch {
                    guard !Task.isCancelled, epoch == actorEpoch else { return }
                    MXLog.error("Managed messenger attempt \(attempt + 1) failed")
                    if attempt < 4 {
                        try? await Task.sleep(for: .seconds(min(30, 2 << attempt)))
                    }
                }
            }
            messengerFailed = true
        }
    }
    
    func text(_ key: String) -> String {
        AntintwrkStrings.value(key)
    }
}
