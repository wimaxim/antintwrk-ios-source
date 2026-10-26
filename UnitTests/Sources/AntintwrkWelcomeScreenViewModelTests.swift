// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
@testable import ElementX
import Testing

struct AntintwrkWelcomeScreenViewModelTests {
    @Test
    func previewCannotPublishAuthenticationActions() {
        let viewModel = AntintwrkWelcomeScreenViewModel(isPreview: true)
        var receivedAction = false
        let subscription = viewModel.actionsPublisher.sink { _ in receivedAction = true }
        viewModel.process(viewAction: .signIn)
        #expect(viewModel.state.bindings.alertInfo != nil)
        viewModel.process(viewAction: .register)
        #expect(!receivedAction)
        withExtendedLifetime(subscription) { }
    }
    
    @Test
    func loadingCannotStartAuthentication() {
        let viewModel = AntintwrkWelcomeScreenViewModel(isLoading: true)
        var receivedAction = false
        let subscription = viewModel.actionsPublisher.sink { _ in receivedAction = true }
        viewModel.process(viewAction: .signIn)
        viewModel.process(viewAction: .register)
        #expect(!receivedAction)
        #expect(viewModel.state.bindings.alertInfo == nil)
        withExtendedLifetime(subscription) { }
    }
    
    @Test
    func liveViewEmitsIntentsWithoutCreatingASession() {
        let viewModel = AntintwrkWelcomeScreenViewModel()
        var receivedActions = 0
        let subscription = viewModel.actionsPublisher.sink { _ in receivedActions += 1 }
        viewModel.process(viewAction: .signIn)
        viewModel.process(viewAction: .register)
        #expect(receivedActions == 2)
        #expect(viewModel.state.bindings.alertInfo == nil)
        withExtendedLifetime(subscription) { }
    }
}
