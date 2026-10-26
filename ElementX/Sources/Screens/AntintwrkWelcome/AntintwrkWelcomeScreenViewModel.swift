// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import SwiftUI

typealias AntintwrkWelcomeScreenViewModelType = StateStoreViewModelV2<AntintwrkWelcomeScreenViewState, AntintwrkWelcomeScreenAction>

final class AntintwrkWelcomeScreenViewModel: AntintwrkWelcomeScreenViewModelType, AntintwrkWelcomeScreenViewModelProtocol {
    private let actionsSubject = PassthroughSubject<AntintwrkWelcomeScreenAction, Never>()
    var actionsPublisher: AnyPublisher<AntintwrkWelcomeScreenAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(isLoading: Bool = false, isPreview: Bool = false) {
        super.init(initialViewState: .init(isLoading: isLoading, isPreview: isPreview))
    }
    
    override func process(viewAction: AntintwrkWelcomeScreenAction) {
        guard !state.isLoading else { return }
        if state.isPreview {
            state.bindings.alertInfo = AlertInfo(id: "preview",
                                                 title: AntintwrkStrings.value("screen_antintwrk_welcome"),
                                                 message: AntintwrkStrings.value("screen_antintwrk_unavailable"))
            return
        }
        actionsSubject.send(viewAction)
    }
}
