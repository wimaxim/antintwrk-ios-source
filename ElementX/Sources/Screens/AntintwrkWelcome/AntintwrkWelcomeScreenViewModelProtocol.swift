// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Combine

protocol AntintwrkWelcomeScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<AntintwrkWelcomeScreenAction, Never> { get }
    var context: AntintwrkWelcomeScreenViewModelType.Context { get }
}
