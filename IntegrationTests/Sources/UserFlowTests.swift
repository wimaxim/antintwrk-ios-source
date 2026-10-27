// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest

@MainActor
final class UserFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }
    
    func testSignedOutNavigation() {
        checkSignedOutNavigation(language: "en")
    }
    
    func testSignedOutNavigationRussianLargeText() {
        checkSignedOutNavigation(language: "ru", largeText: true)
    }
    
    func testSignedOutNavigationArabic() {
        checkSignedOutNavigation(language: "ar")
    }
    
    private func checkSignedOutNavigation(language: String, largeText: Bool = false) {
        let app = Application.launch(language: language, largeText: largeText)
        defer { app.terminate() }
        let signIn = app.buttons["antintwrk-welcome-sign-in"]
        tapWhenVisible(signIn, in: app)
        
        let email = app.textFields["antintwrk-auth-email"]
        let password = app.secureTextFields["antintwrk-auth-password"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertTrue(password.exists)
        email.tap()
        email.typeText("invalid-address")
        // On compact screens at accessibility sizes, the keyboard can cover the next field's tap centre.
        app.keyboards.buttons["Return"].tap()
        password.tap()
        password.typeText("ANTINTWRK_UI_PASSWORD_MUST_NOT_APPEAR_2026")
        app.keyboards.buttons["Return"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        // Missing @ is rejected locally, before any authentication request.
        tapWhenVisible(app.buttons["antintwrk-auth-submit"], in: app)
        XCTAssertTrue(app.staticTexts["antintwrk-auth-error"].waitForExistence(timeout: 10))
        
        tapWhenVisible(app.buttons["antintwrk-auth-reset"], in: app)
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertTrue(password.waitForNonExistence(timeout: 10))
        tapWhenVisible(app.buttons["antintwrk-auth-back"], in: app)
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        
        tapWhenVisible(app.buttons["antintwrk-welcome-register"], in: app)
        XCTAssertTrue(app.textFields["antintwrk-auth-first-name"].waitForExistence(timeout: 10))
        tapWhenVisible(app.buttons["antintwrk-auth-switch-form"], in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["antintwrk-auth-first-name"].waitForNonExistence(timeout: 10))
        tapWhenVisible(app.buttons["antintwrk-auth-back"], in: app)
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        // Reopening must remain signed out, with no form error or password carried over.
        app.terminate()
        app.launch()
        tapWhenVisible(signIn, in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["antintwrk-auth-error"].exists)
        XCTAssertEqual(password.value as? String ?? "", password.placeholderValue ?? "")
        tapWhenVisible(app.buttons["antintwrk-auth-back"], in: app)
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    }
}
