// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

enum AntintwrkWelcomeScreenAction {
    case signIn
    case register
}

struct AntintwrkWelcomeScreenViewState: BindableState {
    var isLoading: Bool
    var isPreview: Bool
    var bindings = AntintwrkWelcomeScreenBindings()
}

struct AntintwrkWelcomeScreenBindings {
    var alertInfo: AlertInfo<String>?
}
