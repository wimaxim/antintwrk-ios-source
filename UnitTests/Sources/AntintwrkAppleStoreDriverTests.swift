// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import KeychainAccess
import StoreKit
import StoreKitTest
import SwiftUI
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
        session.resetToDefaultState()
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
        session.resetToDefaultState()
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
    
    @MainActor
    func testLocalDeclinedApprovalDoesNotBecomeFalseRestorationOrAnotherCharge() async throws {
        let fixture = try await approvalFixture()
        defer { fixture.store.activate(actor: nil); fixture.window.isHidden = true; fixture.window.rootViewController = nil; fixture.session.resetToDefaultState(); fixture.session.clearTransactions(); try? fixture.keychain.removeAll() }
        let request = AntintwrkStoreRequest(key: "kindness_1000", requestKey: "local-approval", applicationID: 0, gratitude: nil)
        let outcome = try await fixture.store.purchase(request)
        XCTAssertEqual(outcome, .pending)
        let transaction = try XCTUnwrap(fixture.session.allTransactions().first(where: \.pendingAskToBuyConfirmation))
        try fixture.session.declineAskToBuyTransaction(identifier: transaction.identifier)
        let recovery = try await fixture.store.restore(userInitiated: true)
        XCTAssertEqual(recovery.pending, 1)
        XCTAssertEqual(recovery.credited, 0)
        XCTAssertEqual(try fixture.pending.tokens(actor: "local-test"), [fixture.server.token])
        let transactionsBeforeRetry = fixture.session.allTransactions().count
        let pendingOutcome = try await fixture.store.purchase(request)
        XCTAssertEqual(pendingOutcome, .pending)
        XCTAssertEqual(fixture.session.allTransactions().count, transactionsBeforeRetry)
        XCTAssertEqual(fixture.server.settlements, 0)
        fixture.store.activate(actor: nil)
    }
    
    @MainActor
    func testLocalApprovedRequestSettlesOnceAndRemovesDurablePendingBinding() async throws {
        let fixture = try await approvalFixture()
        defer { fixture.store.activate(actor: nil); fixture.window.isHidden = true; fixture.window.rootViewController = nil; fixture.session.resetToDefaultState(); fixture.session.clearTransactions(); try? fixture.keychain.removeAll() }
        let settled = expectation(description: "Approved receipt settled")
        fixture.store.onSettlement = { actor in
            XCTAssertEqual(actor, "local-test")
            settled.fulfill()
        }
        let request = AntintwrkStoreRequest(key: "kindness_1000", requestKey: "local-approval", applicationID: 0, gratitude: nil)
        let pendingOutcome = try await fixture.store.purchase(request)
        XCTAssertEqual(pendingOutcome, .pending)
        let transaction = try XCTUnwrap(fixture.session.allTransactions().first(where: \.pendingAskToBuyConfirmation))
        try fixture.session.approveAskToBuyTransaction(identifier: transaction.identifier)
        await fulfillment(of: [settled], timeout: 15)
        for await result in StoreKit.Transaction.unfinished {
            switch result {
            case let .verified(transaction):
                XCTAssertGreaterThan(transaction.id, 0, "Approved local receipt must have a nonzero transaction identifier")
                XCTAssertFalse(result.jwsRepresentation.isEmpty)
                XCTAssertTrue(transaction.appAccountToken == fixture.server.token, "Approved local receipt must preserve its actor-bound token")
                XCTAssertTrue(transaction.appBundleID == "com.antintwrk.app" && transaction.purchasedQuantity == 1)
            case .unverified:
                XCTFail("Apple's local approval returned an unverifiable receipt")
            }
        }
        XCTAssertEqual(fixture.server.settlements, 1)
        XCTAssertTrue(try fixture.pending.tokens(actor: "local-test").isEmpty)
        let recovery = try await fixture.store.restore(userInitiated: false)
        XCTAssertEqual(recovery.pending, 0)
        XCTAssertEqual(recovery.failed, 0)
        XCTAssertEqual(fixture.server.settlements, 1)
        fixture.store.activate(actor: nil)
    }
    
    @MainActor
    private func approvalFixture() async throws -> ApprovalFixture {
        guard ProcessInfo.processInfo.environment["ANTINTWRK_STOREKIT_LOCAL_TEST"] == "1" else {
            throw XCTSkip("Local StoreKit fixture is opt-in")
        }
        let url = try XCTUnwrap(Bundle(for: TestBundleMarker.self).url(forResource: "AntintwrkTestStore", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        // Xcode starts synthetic IDs at zero, which the real financial ledger rejects.
        let seed = try await session.buyProduct(identifier: "kindness_1000")
        await seed.finish()
        session.askToBuyEnabled = true
        let keychain = Keychain(service: "antintwrk-local-approval-qa-" + UUID().uuidString)
        let pending = AntintwrkStorePendingKeychain(keychain: keychain)
        let server = ApprovalServer()
        let store = AntintwrkStoreKit(driver: AntintwrkAppleStoreDriver(), server: server, pending: pending)
        store.activate(actor: "local-test")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        return .init(session: session, store: store, pending: pending, server: server, keychain: keychain, window: window)
    }
    
    @MainActor
    private struct ApprovalFixture {
        let session: SKTestSession
        let store: AntintwrkStoreKit
        let pending: AntintwrkStorePendingKeychain
        let server: ApprovalServer
        let keychain: Keychain
        let window: UIWindow
    }
    
    @MainActor
    private final class ApprovalServer: AntintwrkStoreServer {
        let token = UUID()
        var settlements = 0
        func prepare(_ request: AntintwrkStoreRequest, actor: String) async throws -> AntintwrkStoreOrder {
            .init(actor: actor, productID: request.key, request: request, accountToken: token, checkoutAllowed: true)
        }
        
        func settle(_ receipt: AntintwrkStoreReceipt, actor: String) async throws -> AntintwrkStoreSettlement {
            guard actor == "local-test", receipt.accountToken == token else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            settlements += 1
            return .init(actor: actor, transactionID: receipt.transactionID, state: .credited)
        }
        
        func status(_ order: AntintwrkStoreOrder, actor: String) async throws -> AntintwrkStoreSettlement {
            .init(actor: actor, transactionID: 0, state: .pending)
        }
    }
    
    private final class TestBundleMarker: NSObject { }
}
