// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import StoreKit
import StoreKitTest
import XCTest

/// Run separately: StoreKit Test owns one shared local environment, without Apple billing.
final nonisolated class AntintwrkAppleStoreDriverTests: XCTestCase {
    @MainActor
    func testLocalStorePurchasePreservesBindingUntilExplicitFinish() async throws {
        guard ProcessInfo.processInfo.environment["ANTINTWRK_STOREKIT_LOCAL_TEST"] == "1" else {
            throw XCTSkip("Local StoreKit fixture is opt-in")
        }
        let url = try XCTUnwrap(Bundle(for: TestBundleMarker.self).url(forResource: "AntintwrkTestStore", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let driver = AntintwrkAppleStoreDriver()
        let token = UUID()
        let request = AntintwrkStoreRequest(key: "kindness_1000", requestKey: "local-test", applicationID: 0, gratitude: nil)
        let order = AntintwrkStoreOrder(actor: "local-test", productID: "kindness_1000", request: request, accountToken: token, checkoutAllowed: true)
        let result = try await driver.purchase(order, authorize: { })
        guard case let .purchased(receipt) = result else {
            XCTFail("The local StoreKit fixture did not complete its purchase")
            return
        }
        XCTAssertEqual(receipt.productID, order.productID)
        XCTAssertEqual(receipt.accountToken, token)
        XCTAssertFalse(receipt.signedTransaction.isEmpty)
        XCTAssertFalse(receipt.revoked)
        let unfinished = try await driver.unfinished()
        XCTAssertTrue(unfinished.contains { $0.transactionID == receipt.transactionID })
        await driver.finish(receipt.transactionID)
        let remaining = try await driver.unfinished()
        XCTAssertFalse(remaining.contains { $0.transactionID == receipt.transactionID })
    }
    
    @MainActor
    func testLocalBadgeProductsPreserveOwnedApplicationTokens() async throws {
        guard ProcessInfo.processInfo.environment["ANTINTWRK_STOREKIT_LOCAL_TEST"] == "1" else {
            throw XCTSkip("Local StoreKit fixture is opt-in")
        }
        let url = try XCTUnwrap(Bundle(for: TestBundleMarker.self).url(forResource: "AntintwrkTestStore", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let expected: [(String, Product.ProductType)] = [("verification_lifetime", .nonConsumable), ("verification_monthly", .autoRenewable)]
        let products = try await Product.products(for: expected.map(\.0))
        for (productID, type) in expected {
            XCTAssertEqual(products.first { $0.id == productID }?.type, type)
            let driver = AntintwrkAppleStoreDriver()
            let token = UUID()
            let request = AntintwrkStoreRequest(key: productID, requestKey: "local-badge", applicationID: 101, gratitude: nil)
            let order = AntintwrkStoreOrder(actor: "local-test", productID: productID, request: request, accountToken: token, checkoutAllowed: true)
            let result = try await driver.purchase(order, authorize: { })
            guard case let .purchased(receipt) = result else {
                XCTFail("The local badge fixture did not complete its purchase")
                return
            }
            XCTAssertEqual(receipt.productID, productID)
            XCTAssertEqual(receipt.accountToken, token)
            XCTAssertFalse(receipt.signedTransaction.isEmpty)
            let unfinished = try await driver.unfinished()
            XCTAssertTrue(unfinished.contains { $0.transactionID == receipt.transactionID })
            await driver.finish(receipt.transactionID)
            let remaining = try await driver.unfinished()
            XCTAssertFalse(remaining.contains { $0.transactionID == receipt.transactionID })
        }
    }
    
    private final class TestBundleMarker: NSObject { }
}
