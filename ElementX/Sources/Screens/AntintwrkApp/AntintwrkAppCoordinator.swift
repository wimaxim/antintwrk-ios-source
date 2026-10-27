// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Compound
import SwiftUI

final class AntintwrkAppCoordinator: CoordinatorProtocol {
    private let model: AntintwrkAppModel
    init(prepareMessenger: @escaping (AntintwrkSocialClient, AntintwrkSocialAdmission) async throws -> AntintwrkMessengerPresentation,
         messengerReady: @escaping (AntintwrkMessengerPresentation) -> Void, messengerEnded: @escaping () -> Void, appLockService: AppLockServiceProtocol? = nil) {
        model = AntintwrkAppModel(prepareMessenger: prepareMessenger, messengerReady: messengerReady, messengerEnded: messengerEnded)
        model.appLockService = appLockService
    }
    
    func receivedPushToken(_ token: Data) {
        model.socialPush.received(token: token)
    }
    
    func handleSocialNotification(_ info: [AnyHashable: Any]) {
        model.handleSocialNotification(info)
    }
    
    func openSocialSettings() {
        model.openSettings()
    }
    
    func handleAppRoute(_ route: AppRoute) {
        model.handleSDKRoute(route)
    }
    
    func revealIncomingCall(actor: String?) {
        model.revealIncomingCall(actor: actor)
    }
    
    func logout() {
        Task { await model.logout() }
    }
    
    func messengerAuthFailed() {
        model.messengerAuthFailed()
    }
    
    func openProfile(userID: String, actor: String) {
        guard model.accountActor == actor, let id = AntintwrkSocialDirectory.socialID(userID) else { return }
        model.social?.messenger = false
        model.social?.open("hero/" + id)
        model.social?.returnToMessenger = true
    }
    
    func toPresentable() -> AnyView {
        AnyView(AntintwrkAppScreen(model: model))
    }
}

struct AntintwrkAppScreen: View {
    @Bindable var model: AntintwrkAppModel
    
    var body: some View {
        Group {
            if model.booting {
                AntintwrkWelcomeScreen(context: model.loading.context)
            } else if let social = model.social, model.page == .social || model.needsSocialLogin {
                AntintwrkSocialScreen(surface: social, model: model, logout: { Task { await model.logout() } }, signIn: AnyView(accountForm))
            } else if model.page == .welcome {
                AntintwrkWelcomeScreen(context: model.welcome.context)
                    .onReceive(model.welcome.actionsPublisher) { model.page = $0 == .signIn ? .login : .register }
            } else {
                accountForm
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // WindowManager hosts this view outside SwiftUI's WindowGroup environment.
            model.applicationActivityChanged(UIApplication.shared.applicationState)
            await model.bootstrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.applicationActivityChanged(.active) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.applicationActivityChanged(.inactive) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in model.applicationActivityChanged(.background) }
        .sheet(isPresented: $model.commonSettingsPresented) { AntintwrkCommonSettingsScreen(model: model) }
        .sheet(isPresented: $model.licencesPresented) {
            ElementNavigationStack {
                AntintwrkLicencesScreen {
                    model.licencesPresented = false; model.social?.messenger = false; model.social?.open("hero/2266620")
                }
                .toolbar { Button(model.text("screen_ant_shell_close")) { model.licencesPresented = false } }
            }
        }
        .sheet(item: $model.settingsPresentation) { settings in
            settings.navigation.toPresentable()
                .alert("ANTINTWRK", isPresented: Binding(get: { model.error != nil }, set: {
                    if !$0 {
                        model.error = nil
                    }
                })) {
                    Button("OK", role: .cancel) { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
        .sheet(isPresented: Binding(get: { model.legalURL != nil }, set: {
            if !$0 {
                model.legalURL = nil
            }
        })) {
            if let url = model.legalURL {
                ElementNavigationStack {
                    AntintwrkLegalWebScreen(client: model.client, url: url)
                        .toolbar { Button(model.text("screen_ant_shell_close")) { model.legalURL = nil } }
                }
            }
        }
        .environment(\.locale, Locale(identifier: model.language))
        .environment(\.layoutDirection, model.language == "ar" ? .rightToLeft : .leftToRight)
    }
    
    private var accountForm: some View {
        ElementNavigationStack {
            ZStack(alignment: .bottom) {
                Color(red: 0.059, green: 0.071, blue: 0.078).ignoresSafeArea()
                AntintwrkSignalArtwork(animated: true).frame(height: 300).allowsHitTesting(false).accessibilityHidden(true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image("images/antintwrk-brand-mark").resizable().scaledToFit().frame(width: 36, height: 36).accessibilityHidden(true)
                            Text("anti·ntwrk").font(.title2.bold()).accessibilityLabel("ANTINTWRK")
                        }.environment(\.layoutDirection, .leftToRight).frame(maxWidth: .infinity)
                        Text(title).font(.title2.bold()).frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
                        if model.accountPage == .mailSent {
                            Text(model.text(model.registered ? "screen_ant_auth_register_sent" : "screen_ant_auth_reset_sent"))
                            Text(model.text("screen_ant_auth_email_spam_hint"))
                            Button(model.text("screen_antintwrk_login")) { model.switchAccountForm(to: .login) }.disabled(model.busy)
                        } else {
                            if model.accountPage == .challenge {
                                Text(model.text(model.admission?.stage == .device ? "screen_ant_auth_device" : "screen_ant_auth_totp"))
                                TextField(model.text("screen_ant_auth_code"), text: $model.code, prompt: Text(model.text("screen_ant_auth_code")).foregroundStyle(.white.opacity(0.65))).textContentType(.oneTimeCode).keyboardType(.numberPad)
                            } else {
                                TextField(model.text("screen_antintwrk_email"), text: $model.email, prompt: Text(model.text("screen_antintwrk_email")).foregroundStyle(.white.opacity(0.65))).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.hasProviderRegistration).accessibilityIdentifier("antintwrk-auth-email")
                                if model.accountPage != .reset, !model.hasProviderRegistration {
                                    SecureField(model.text("screen_antintwrk_password"), text: $model.password, prompt: Text(model.text("screen_antintwrk_password")).foregroundStyle(.white.opacity(0.65))).textContentType(model.accountPage == .register ? .newPassword : .password).accessibilityIdentifier("antintwrk-auth-password")
                                }
                                if model.accountPage == .register {
                                    TextField(model.text("screen_antintwrk_first_name"), text: $model.firstName, prompt: Text(model.text("screen_antintwrk_first_name")).foregroundStyle(.white.opacity(0.65))).textContentType(.givenName).accessibilityIdentifier("antintwrk-auth-first-name")
                                    TextField(model.text("screen_antintwrk_surname"), text: $model.surname, prompt: Text(model.text("screen_antintwrk_surname")).foregroundStyle(.white.opacity(0.65))).textContentType(.familyName).accessibilityIdentifier("antintwrk-auth-surname")
                                    DatePicker(model.text("screen_antintwrk_birthdate"), selection: $model.birthday, in: ...Date(), displayedComponents: .date)
                                    Button(model.text("screen_antintwrk_terms")) { model.legalURL = URL(string: "https://antimsg.com/\(model.language)/terms?native_legal=1") }
                                    Toggle(model.text("screen_antintwrk_agree"), isOn: $model.agreed)
                                }
                            }
                            if let error = model.error {
                                Text(error).foregroundStyle(.red).accessibilityIdentifier("antintwrk-auth-error")
                            }
                            if model.accountPage == .login || model.accountPage == .register {
                                let key = model.accountPage == .login ? "screen_ant_auth_login_terms_notice" : "screen_ant_auth_register_terms_notice"
                                AntintwrkTermsNotice(format: model.text(key), rules: model.text("screen_ant_auth_rules_link")) {
                                    model.legalURL = URL(string: "https://antimsg.com/\(model.language)/terms?native_legal=1")
                                }
                            }
                            Button { Task { await model.submit() } } label: {
                                HStack(spacing: 12) {
                                    if model.busy {
                                        ProgressView()
                                    }; Text(model.text("screen_antintwrk_continue"))
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).disabled(model.busy || model.admission?.stage == .setupRequired && model.accountPage == .challenge).accessibilityIdentifier("antintwrk-auth-submit")
                            if model.accountPage == .login {
                                AntintwrkAppleSignInButton(enabled: !model.busy, label: model.text("screen_antintwrk_apple")) {
                                    Task { await model.apple() }
                                }.frame(height: 50)
                                Button { Task { await model.google() } } label: {
                                    HStack(spacing: 12) {
                                        Image("images/google-sign-in-logo").resizable().scaledToFit().frame(width: 24, height: 24).accessibilityHidden(true)
                                        Text(model.text("screen_antintwrk_google")).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }.foregroundStyle(.black).padding(14).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(model.text("screen_antintwrk_google"))
                                if model.client.configuration.passkeysAvailable {
                                    Button { Task { await model.passkey() } } label: {
                                        HStack(spacing: 12) {
                                            CompoundIcon(\.devicePasskey).accessibilityHidden(true)
                                            Text(model.text("screen_antintwrk_passkey")).fixedSize(horizontal: false, vertical: true)
                                        }.frame(maxWidth: .infinity, minHeight: 24)
                                    }
                                    .buttonStyle(.compound(.secondary))
                                    .disabled(model.busy)
                                    .accessibilityIdentifier("antintwrk-auth-passkey")
                                }
                                Button(model.text("screen_antintwrk_reset")) { model.switchAccountForm(to: .reset) }.disabled(model.busy).accessibilityIdentifier("antintwrk-auth-reset")
                            }
                            if model.accountPage == .login || model.accountPage == .register {
                                let registering = model.accountPage == .register
                                VStack(spacing: 6) {
                                    Text(model.text(registering ? "screen_ant_auth_has_account" : "screen_ant_auth_no_account"))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button(model.text(registering ? "screen_antintwrk_login" : "screen_ant_auth_register_link")) {
                                        model.switchAccountForm(to: registering ? .login : .register)
                                    }.disabled(model.busy).accessibilityIdentifier("antintwrk-auth-switch-form")
                                }.frame(maxWidth: .infinity).padding(.top, 6)
                            }
                        }
                    }.foregroundStyle(.white).textFieldStyle(AntintwrkAccountFieldStyle()).padding(24).frame(maxWidth: 480).frame(maxWidth: .infinity)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(model.text("screen_antintwrk_back")) {
                model.password = ""; model.code = ""; model.error = nil; model.googleRegistrationTicket = nil; model.appleRegistrationTicket = nil; if model.needsSocialLogin {
                    model.page = .social; model.social?.messenger = true
                } else {
                    model.admission = nil; model.page = .welcome
                }
            }.disabled(model.busy).accessibilityIdentifier("antintwrk-auth-back") } }
        }.tint(Color(red: 0.94, green: 0.42, blue: 0.33))
    }
    
    private var title: String {
        model.text(model.accountPage == .register ? "screen_antintwrk_register" : model.accountPage == .reset ? "screen_antintwrk_reset" : model.accountPage == .mailSent ? "screen_ant_auth_check_email" : "screen_antintwrk_login")
    }
}

private struct AntintwrkAccountFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .foregroundStyle(.white)
            .padding(14)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.2)))
    }
}
