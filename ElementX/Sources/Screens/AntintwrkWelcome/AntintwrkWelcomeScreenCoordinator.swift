// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import SwiftUI

final class AntintwrkWelcomeScreenCoordinator: CoordinatorProtocol {
    private let viewModel: AntintwrkWelcomeScreenViewModelProtocol
    var actionsPublisher: AnyPublisher<AntintwrkWelcomeScreenAction, Never> {
        viewModel.actionsPublisher
    }
    
    init(isLoading: Bool = false, isPreview: Bool = false) {
        viewModel = AntintwrkWelcomeScreenViewModel(isLoading: isLoading, isPreview: isPreview)
    }
    
    func toPresentable() -> AnyView {
        AnyView(AntintwrkWelcomeScreen(context: viewModel.context))
    }
}
