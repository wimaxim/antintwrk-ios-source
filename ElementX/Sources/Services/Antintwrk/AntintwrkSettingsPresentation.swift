// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import SwiftUI

@MainActor
final class AntintwrkSettingsPresentation: Identifiable {
    let id = UUID()
    let navigation = NavigationStackCoordinator()
    private let flow: SettingsFlowCoordinator
    private var subscription: AnyCancellable?
    
    init(parameters: CommonFlowParameters, appLockService: AppLockServiceProtocol, suffix: String, route: @escaping (String) -> Void) {
        flow = SettingsFlowCoordinator(appLockService: appLockService, isInSecondaryWindow: false,
                                       navigationStackCoordinator: navigation, flowParameters: parameters,
                                       managedSocialAction: route, socialVersionSuffix: suffix)
        subscription = flow.actions.sink { action in
            switch action {
            case .dismiss: route("close")
            case .runLogoutFlow, .forceLogout: route("logout")
            case .clearCache: break
            }
        }
        flow.handleAppRoute(.settings, animated: false)
    }
}

@MainActor
final class AntintwrkAppLockPresentation: Identifiable {
    let id = UUID()
    let navigation = NavigationStackCoordinator()
    private let flow: AppLockSetupFlowCoordinator
    private var subscription: AnyCancellable?
    
    init(service: AppLockServiceProtocol, completion: @escaping (Bool) -> Void) {
        flow = AppLockSetupFlowCoordinator(presentingFlow: .settings, appLockService: service, navigationStackCoordinator: navigation, useRootPresentation: true)
        subscription = flow.actions.sink { action in
            completion(action == .forceLogout)
        }
        flow.start()
    }
}
