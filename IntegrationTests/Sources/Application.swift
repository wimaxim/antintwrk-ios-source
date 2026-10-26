// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest

@MainActor
enum Application {
    static func launch(language: String = "en", largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["IS_RUNNING_INTEGRATION_TESTS": "1"]
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }
}
