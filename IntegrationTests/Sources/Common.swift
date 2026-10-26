// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest

extension XCTestCase {
    @MainActor
    func tapWhenVisible(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // A cold guest bootstrap includes regional transport and a bounded live session request.
        XCTAssertTrue(element.waitForExistence(timeout: 60), file: file, line: line)
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 where !element.isHittable {
            guard scrollView.exists else { break }
            if element.frame.midY < scrollView.frame.midY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
        element.tap()
    }
}
