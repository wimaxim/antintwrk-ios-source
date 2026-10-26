// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

nonisolated struct AntintwrkAppSettingsHook: AppSettingsHookProtocol {
    @MainActor func configure(_ settings: AppSettings) -> AppSettings {
        settings.override(accountProviders: [.generic(AntintwrkClientConfiguration.messengerOrigin.absoluteString)], allowOtherAccountProviders: false, hideBrandChrome: true,
                          pushGatewayBaseURL: "https://push.antimsg.com", oAuthRedirectURL: AntintwrkMessengerBootstrap.callbackURL, oAuthClientURIPath: nil,
                          websiteURL: "https://antintwrk.com", logoURL: "https://antintwrk.com/favicon.ico",
                          copyrightURL: "https://github.com/wimaxim/antintwrk-ios-source", acceptableUseURL: "https://antintwrk.com/en/terms", privacyURL: "https://antintwrk.com/en/privacy",
                          encryptionURL: "https://antintwrk.com/en/support", deviceVerificationURL: "https://antintwrk.com/en/support", chatBackupDetailsURL: "https://antintwrk.com/en/support",
                          identityPinningViolationDetailsURL: "https://antintwrk.com/en/support", historySharingDetailsURL: "https://antintwrk.com/en/support",
                          elementWebHosts: ["antintwrk.com"], accountProvisioningHost: "antintwrk.com", bugReportApplicationID: "antintwrk-ios", analyticsTermsURL: nil,
                          mapTilerConfiguration: AppSettings.bundledMapTilerConfiguration)
        if settings.analyticsConsentState == .unknown {
            settings.analyticsConsentState = .optedOut
        }
        return settings
    }
}

@MainActor
final class AntintwrkMessengerPresentation {
    let session: UserSessionProtocol
    let navigation: NavigationRootCoordinator
    let flow: UserSessionFlowCoordinator
    let bootstrap: AntintwrkMessengerBootstrap
    let store: UserSessionStoreProtocol
    let directory: AntintwrkSocialDirectory
    let settingsFactory: (String, @escaping (String) -> Void) -> AntintwrkSettingsPresentation
    
    init(session: UserSessionProtocol, navigation: NavigationRootCoordinator, flow: UserSessionFlowCoordinator, bootstrap: AntintwrkMessengerBootstrap, store: UserSessionStoreProtocol, directory: AntintwrkSocialDirectory, settingsFactory: @escaping (String, @escaping (String) -> Void) -> AntintwrkSettingsPresentation) {
        self.session = session; self.navigation = navigation; self.flow = flow; self.bootstrap = bootstrap; self.store = store; self.directory = directory; self.settingsFactory = settingsFactory
    }
    
    func showChats() {
        flow.handleAppRoute(.roomList, animated: false)
    }
    
    func logout() async throws {
        do { try await bootstrap.logout() }
        catch { await session.clientProxy.resumeServices(); throw error }
        directory.invalidate()
        flow.stop()
        await session.clientProxy.pauseServices()
        store.logout(userSession: session)
    }
}
