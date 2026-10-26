// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkCommonSettingsScreen: View {
    @Bindable var model: AntintwrkAppModel
    private let account = [("profile/settings", "screen_ant_settings_profile"), ("verification", "screen_ant_settings_verification"), ("kindness", "screen_ant_settings_kindness")]
    private let participation = [("friend-requests", "screen_ant_settings_friend_requests"), ("my-referrals", "screen_ant_menu_referrals")]
    private let help = [("support", "screen_ant_menu_support"), ("contacts", "screen_ant_settings_contacts")]
    private let information = [("about", "screen_ant_menu_about"), ("hero/maxim-novichkov/1755", "screen_ant_settings_manifesto")]
    private let legal = [("terms", "screen_ant_menu_terms"), ("privacy", "screen_ant_menu_privacy"), ("community", "screen_ant_settings_community_rules"), ("safety", "screen_ant_settings_safety"), ("dmca", "screen_ant_settings_copyright")]
    var body: some View {
        ElementNavigationStack {
            Form {
                Section(AntintwrkStrings.value("screen_ant_settings_language")) {
                    Picker(AntintwrkStrings.value("screen_ant_settings_language"), selection: Binding(get: { model.preferredLanguage }, set: { model.changeLanguage($0) })) {
                        Text(AntintwrkStrings.value("screen_ant_settings_system_language")).tag("")
                        ForEach(AntintwrkClientConfiguration.supportedLanguages, id: \.self) { language in
                            Text(Locale(identifier: language).localizedString(forLanguageCode: language) ?? language).tag(language)
                        }
                    }
                }
                Section {
                    NavigationLink(AntintwrkStrings.value("screen_ant_push_title")) {
                        AntintwrkSocialPushSettingsScreen(service: model.socialPush)
                    }
                }
                Section("Face ID / Touch ID") {
                    Button { model.openAppLockSettings() } label: {
                        Label(L10n.commonScreenLock, systemImage: "lock.shield")
                    }
                    .disabled(model.appLockService == nil || model.busy)
                }
                section("screen_ant_settings_account", rows: account)
                Section { Button(L10n.actionDeleteAccount, role: .destructive) { open("deleteaccount") } }
                Section { ShareLink(item: AntintwrkStrings.value("screen_ant_invite_message")) { Text(AntintwrkStrings.value("screen_ant_invite_friends")) } }
                section("screen_ant_settings_participation", rows: participation)
                Section(L10n.commonSettings) {
                    Button(L10n.commonSettings) { model.openMessengerSettings() }.disabled(model.messenger == nil)
                    if model.messenger == nil {
                        ProgressView().accessibilityLabel(L10n.commonLoading)
                    }
                }
                section("screen_ant_settings_help", rows: help)
                section("screen_ant_settings_information", rows: information)
                section("screen_ant_settings_legal", rows: legal)
                Section {
                    NavigationLink(AntintwrkStrings.value("screen_ant_licences")) {
                        AntintwrkLicencesScreen { model.commonSettingsPresented = false; model.social?.messenger = false; model.social?.open("hero/2266620") }
                    }
                    Text("\(model.client.configuration.productVersion)\(model.social?.origin.versionSuffix ?? "R") (\(InfoPlistReader.main.bundleVersion))").font(.footnote)
                    Button(AntintwrkStrings.value("screen_ant_auth_logout"), role: .destructive) { Task { await model.logout() } }.disabled(model.busy)
                }
            }
            .navigationTitle(L10n.commonSettings)
            .toolbar { Button(AntintwrkStrings.value("screen_ant_shell_close")) { model.commonSettingsPresented = false } }
            .sheet(item: $model.appLockPresentation) { presentation in
                presentation.navigation.toPresentable()
                    .interactiveDismissDisabled()
            }
            .sheet(item: $model.settingsPresentation) { $0.navigation.toPresentable() }
            .alert("ANTINTWRK", isPresented: Binding(get: { model.error != nil }, set: {
                if !$0 {
                    model.error = nil
                }
            })) {
                Button("OK", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .preferredColorScheme(.dark)
    }
    
    private func section(_ key: String, rows: [(String, String)]) -> some View {
        Section(AntintwrkStrings.value(key)) {
            ForEach(rows, id: \.0) { route, label in
                Button { open(route) } label: {
                    HStack {
                        Text(AntintwrkStrings.value(label))
                        if route == "verification" {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Color(red: 56 / 255, green: 151 / 255, blue: 240 / 255))
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
    
    private func open(_ route: String) {
        model.commonSettingsPresented = false
        model.social?.messenger = false
        model.social?.open(route)
    }
}
