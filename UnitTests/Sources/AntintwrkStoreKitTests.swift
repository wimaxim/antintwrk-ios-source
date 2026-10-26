// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Foundation
@preconcurrency import KeychainAccess
import StoreKit
import Testing

struct AntintwrkStoreKitTests {
    @Test func paymentFinishesOnlyAfterServerCredit() async throws {
        let fixture = Fixture()
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 1)
        #expect(fixture.driver.finished == [1])
        #expect(fixture.server.events == ["prepare", "settle"])
    }
    
    @Test func pendingServerCreditDoesNotFinishOrShowSuccess() async throws {
        let fixture = Fixture()
        fixture.server.state = .pending
        #expect(try await fixture.store.purchase(fixture.request) == .pending)
        #expect(fixture.driver.finished.isEmpty)
    }
    
    @Test func verificationFailureLeavesPaidTransactionRecoverable() async throws {
        let fixture = Fixture()
        fixture.server.reject = true
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.finished.isEmpty)
        fixture.server.reject = false
        fixture.driver.restorable = [fixture.receipt]
        try await fixture.store.restore(userInitiated: false)
        #expect(fixture.driver.purchases == 1 && fixture.driver.finished == [1])
        #expect(fixture.driver.syncs == 0)
    }
    
    @Test func cancellationNeverSettlesOrFinishes() async throws {
        let fixture = Fixture()
        fixture.driver.result = .cancelled
        #expect(try await fixture.store.purchase(fixture.request) == .cancelled)
        #expect(fixture.server.events == ["prepare"] && fixture.driver.finished.isEmpty)
    }
    
    @Test func askToBuyRemainsPending() async throws {
        let fixture = Fixture()
        fixture.driver.result = .pending
        #expect(try await fixture.store.purchase(fixture.request) == .pending)
        #expect(fixture.server.events == ["prepare"] && fixture.driver.finished.isEmpty)
        #expect(try fixture.store.hasPendingIntent(productID: "kindness"))
        fixture.store.activate(actor: "other")
        #expect(try !fixture.store.hasPendingIntent(productID: "kindness"))
    }
    
    @Test func thrownSystemCancellationReleasesOnlyTheCancelledIntentAndAllowsRetry() async throws {
        let fixture = Fixture()
        fixture.driver.purchaseFailure = StoreKitError.userCancelled
        #expect(try await fixture.store.purchase(fixture.request) == .cancelled)
        #expect(try !fixture.pending.contains(actor: "fixture-actor", productID: "kindness"))
        #expect(fixture.server.events == ["prepare"] && fixture.driver.finished.isEmpty)
        fixture.driver.purchaseFailure = nil
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 2 && fixture.driver.finished == [1])
    }
    
    @Test func ambiguousStoreFailureKeepsIntentAcrossCoordinatorRecreation() async throws {
        let fixture = Fixture()
        fixture.driver.purchaseFailure = StoreKitError.networkError(URLError(.networkConnectionLost))
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(try fixture.pending.contains(actor: "fixture-actor", productID: "kindness"))
        let replacement = AntintwrkStoreKit(driver: fixture.driver, server: fixture.server, pending: fixture.pending)
        replacement.activate(actor: "fixture-actor")
        fixture.driver.purchaseFailure = nil
        #expect(try await replacement.purchase(fixture.request) == .pending)
        #expect(fixture.driver.purchases == 1 && fixture.driver.finished.isEmpty)
        #expect(fixture.server.events == ["prepare", "prepare"])
    }
    
    @Test func lateSystemCancellationCannotClearAnotherActorsPendingPurchase() async throws {
        let fixture = Fixture()
        try fixture.pending.begin(.init(actor: "other", productID: "kindness", request: fixture.request, accountToken: UUID(), checkoutAllowed: true))
        fixture.driver.duringPurchase = { fixture.store.activate(actor: "other") }
        fixture.driver.purchaseFailure = StoreKitError.userCancelled
        await #expect(throws: AntintwrkStoreKit.Failure.accountChanged) { try await fixture.store.purchase(fixture.request) }
        #expect(try !fixture.pending.contains(actor: "fixture-actor", productID: "kindness"))
        #expect(try fixture.pending.contains(actor: "other", productID: "kindness"))
        #expect(fixture.server.events == ["prepare"] && fixture.driver.finished.isEmpty)
    }
    
    @Test func existingOrderNeverTriggersAnotherCharge() async throws {
        let fixture = Fixture()
        fixture.server.checkoutAllowed = false
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare", "status"])
    }
    
    @Test func reversedOrderNeverReportsPendingOrOpensAnotherPayment() async throws {
        let fixture = Fixture()
        fixture.server.checkoutAllowed = false
        fixture.server.state = .reversed
        #expect(try await fixture.store.purchase(fixture.request) == .reversed)
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare", "status"])
    }
    
    @Test func crashAfterApplePaymentRecoversBeforeOpeningAnotherCheckout() async throws {
        let fixture = Fixture()
        fixture.driver.restorable = [fixture.receipt]
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 0 && fixture.driver.finished == [1])
        #expect(fixture.server.events == ["prepare", "settle"])
    }
    
    @Test func interruptedPaymentStillPendingOnServerCannotChargeAgain() async throws {
        let fixture = Fixture()
        fixture.driver.restorable = [fixture.receipt]
        fixture.server.state = .pending
        #expect(try await fixture.store.purchase(fixture.request) == .pending)
        #expect(fixture.driver.purchases == 0 && fixture.driver.finished.isEmpty)
    }
    
    @Test func failedInterruptedPaymentVerificationCannotChargeAgain() async {
        let fixture = Fixture()
        fixture.driver.restorable = [fixture.receipt]
        fixture.server.reject = true
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.driver.finished.isEmpty)
    }
    
    @Test func wrongProductOnExistingOrderCannotChargeAgain() async {
        let fixture = Fixture()
        fixture.driver.restorable = [.init(transactionID: 1, productID: "other", accountToken: fixture.token, signedTransaction: "fixture-only", revoked: false)]
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare"])
    }
    
    @Test func ambiguousUnfinishedOrderCannotChargeAgain() async {
        let fixture = Fixture()
        fixture.driver.restorable = [fixture.receipt, fixture.receipt]
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare"])
    }
    
    @Test func unavailableUnfinishedTransactionsPreventAnotherCharge() async {
        let fixture = Fixture()
        fixture.driver.unfinishedFailure = true
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare"])
    }
    
    @Test func logoutDuringUnfinishedLookupCannotStartPayment() async {
        let fixture = Fixture()
        fixture.driver.duringUnfinished = { fixture.store.activate(actor: nil) }
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare"])
    }
    
    @Test func anotherOrderDoesNotPreventTheChosenCheckout() async throws {
        let fixture = Fixture()
        fixture.driver.restorable = [.init(transactionID: 2, productID: "kindness", accountToken: UUID(), signedTransaction: "fixture-only", revoked: false)]
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 1 && fixture.driver.finished == [1])
    }
    
    @Test func wrongOrderActorCannotStartPayment() async throws {
        let fixture = Fixture()
        fixture.server.responseActor = "other"
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0)
    }
    
    @Test func mismatchedStoreTokenDoesNotReachSettlement() async throws {
        let fixture = Fixture()
        fixture.driver.result = .purchased(.init(transactionID: 1, productID: "kindness", accountToken: UUID(), signedTransaction: "fixture-only", revoked: false))
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.server.events == ["prepare"] && fixture.driver.finished.isEmpty)
    }
    
    @Test func wrongSettlementActorDoesNotFinish() async throws {
        let fixture = Fixture()
        fixture.server.settlementActor = "other"
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.finished.isEmpty)
    }
    
    @Test func logoutDuringSettlementCannotFinishForTheNewActor() async throws {
        let fixture = Fixture()
        fixture.server.duringSettlement = { fixture.store.activate(actor: "other") }
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.finished.isEmpty)
    }
    
    @Test func serverCannotChangeTheChosenPublicationBeforeCheckout() async throws {
        let fixture = Fixture()
        fixture.server.requestOverride = .init(key: "kindness", requestKey: "different", applicationID: 0, gratitude: .init(kind: "publication", id: "different"))
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0)
    }
    
    @Test func restoreCallsStoreSyncOnlyForExplicitAction() async throws {
        let fixture = Fixture()
        fixture.driver.restorable = [fixture.receipt]
        try await fixture.store.restore(userInitiated: true)
        #expect(fixture.driver.syncs == 1 && fixture.driver.purchases == 0 && fixture.driver.finished == [1])
    }
    
    @Test func revokedReceiptRequiresConfirmedServerReversal() async throws {
        let fixture = Fixture()
        fixture.driver.restorable = [.init(transactionID: 1, productID: "kindness", accountToken: fixture.token, signedTransaction: "fixture-only", revoked: true)]
        try await fixture.store.restore(userInitiated: false)
        #expect(fixture.driver.finished.isEmpty)
        fixture.server.state = .reversed
        let restored = try await fixture.store.restore(userInitiated: false)
        #expect(fixture.driver.finished == [1])
        #expect(restored.reversed == 1 && restored.pending == 0 && restored.credited == 0 && restored.failed == 0)
    }
    
    @Test func logoutWhileStoreProductLoadsCannotOpenOldAccountCheckout() async {
        let fixture = Fixture()
        fixture.driver.beforeSheet = { fixture.store.activate(actor: nil) }
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.server.events == ["prepare"])
    }
    
    @Test func restoreReportsPendingAndFailuresWithoutFalseSuccess() async throws {
        let fixture = Fixture()
        fixture.driver.restorable = [fixture.receipt]
        fixture.server.state = .pending
        let pending = try await fixture.store.restore(userInitiated: false)
        #expect(pending.credited == 0 && pending.pending == 1 && pending.failed == 0)
        fixture.server.reject = true
        let failed = try await fixture.store.restore(userInitiated: false)
        #expect(failed.credited == 0 && failed.failed == 1 && fixture.driver.finished.isEmpty)
    }
    
    @Test func guestCannotPurchaseOrRestore() async {
        let fixture = Fixture()
        fixture.store.activate(actor: nil)
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        await #expect(throws: (any Error).self) { try await fixture.store.restore(userInitiated: true) }
        #expect(fixture.server.events.isEmpty && fixture.driver.syncs == 0)
    }
    
    @Test func pendingApprovalCannotLaunchAnotherPaymentAfterCoordinatorRecreation() async throws {
        let fixture = Fixture()
        fixture.driver.result = .pending
        #expect(try await fixture.store.purchase(fixture.request) == .pending)
        let replacement = AntintwrkStoreKit(driver: fixture.driver, server: fixture.server, pending: fixture.pending)
        replacement.activate(actor: "fixture-actor")
        #expect(try await replacement.purchase(fixture.request) == .pending)
        #expect(fixture.driver.purchases == 1)
    }
    
    @Test func knownCancellationAllowsTheSameIntentToBeRetried() async throws {
        let fixture = Fixture()
        fixture.driver.result = .cancelled
        #expect(try await fixture.store.purchase(fixture.request) == .cancelled)
        fixture.driver.result = .purchased(fixture.receipt)
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 2)
    }
    
    @Test func failedIntentPersistenceNeverOpensPaymentAndCanRetryAfterRepair() async throws {
        let fixture = Fixture()
        fixture.pending.beginFailure = true
        await #expect(throws: (any Error).self) { try await fixture.store.purchase(fixture.request) }
        #expect(fixture.driver.purchases == 0 && fixture.driver.finished.isEmpty)
        fixture.pending.beginFailure = false
        #expect(try await fixture.store.purchase(fixture.request) == .credited)
        #expect(fixture.driver.purchases == 1)
    }
    
    @Test func pendingKeychainSurvivesRecreationAndKeepsActorIsolation() throws {
        let suite = "antintwrk-store-pending-qa-" + UUID().uuidString
        let keychain = Keychain(service: suite).accessibility(.afterFirstUnlockThisDeviceOnly)
        defer { try? keychain.removeAll() }
        let fixture = Fixture()
        let order = AntintwrkStoreOrder(actor: "fixture-actor", productID: "kindness", request: fixture.request, accountToken: fixture.token, checkoutAllowed: true)
        try AntintwrkStorePendingKeychain(keychain: keychain).begin(order)
        let restored = AntintwrkStorePendingKeychain(keychain: keychain)
        #expect(try restored.contains(actor: order.actor, productID: order.productID))
        #expect(try !restored.contains(actor: "other-actor", productID: order.productID))
        try restored.remove(actor: "other-actor", token: fixture.token)
        #expect(try restored.contains(actor: order.actor, productID: order.productID))
        try restored.remove(actor: order.actor, token: fixture.token)
        #expect(try !restored.contains(actor: order.actor, productID: order.productID))
        try keychain.set(Data("broken".utf8), key: "antintwrk.store.pending.v1")
        #expect(throws: (any Error).self) { try restored.contains(actor: order.actor, productID: order.productID) }
    }
    
    @Test func checkoutEnvironmentNeverFallsBackBetweenAppleRealms() {
        #expect(AntintwrkAppleStoreDriver.environmentMatches("Production", actual: .production))
        #expect(AntintwrkAppleStoreDriver.environmentMatches("Sandbox", actual: .sandbox))
        #expect(!AntintwrkAppleStoreDriver.environmentMatches("Production", actual: .sandbox))
        #expect(!AntintwrkAppleStoreDriver.environmentMatches("Sandbox", actual: .production))
        #expect(!AntintwrkAppleStoreDriver.environmentMatches("Production", actual: .xcode))
        #expect(!AntintwrkAppleStoreDriver.environmentMatches("LocalTesting", actual: .xcode))
    }
    
    @Test func regionalNavigationIsProtectedUntilCheckoutFinishes() async throws {
        let fixture = Fixture()
        fixture.driver.result = .cancelled
        #expect(!fixture.store.isCheckingOut)
        fixture.driver.beforeSheet = { #expect(fixture.store.isCheckingOut) }
        #expect(try await fixture.store.purchase(fixture.request) == .cancelled)
        #expect(!fixture.store.isCheckingOut)
    }
    
    private final class Fixture {
        let token = UUID()
        let request = AntintwrkStoreRequest(key: "kindness", requestKey: "fixture", applicationID: 0, gratitude: .init(kind: "publication", id: "fixture"))
        let server: Server
        let driver: Driver
        let store: AntintwrkStoreKit
        let pending = AntintwrkStorePendingMemory()
        var receipt: AntintwrkStoreReceipt {
            .init(transactionID: 1, productID: "kindness", accountToken: token, signedTransaction: "fixture-only", revoked: false)
        }
        
        init() {
            server = Server(token: token)
            driver = Driver()
            store = AntintwrkStoreKit(driver: driver, server: server, pending: pending)
            driver.result = .purchased(receipt)
            store.activate(actor: "fixture-actor")
        }
    }
    
    private final class Driver: AntintwrkStoreDriver {
        var result: AntintwrkStoreKit.PurchaseResult = .pending
        var purchases = 0
        var beforeSheet: (() -> Void)?
        var finished: [UInt64] = []
        var restorable: [AntintwrkStoreReceipt] = []
        var syncs = 0
        var unfinishedFailure = false
        var purchaseFailure: (any Error)?
        var duringPurchase: (() -> Void)?
        var duringUnfinished: (() -> Void)?
        func purchase(_ order: AntintwrkStoreOrder, authorize: @escaping @MainActor () throws -> Void) async throws -> AntintwrkStoreKit.PurchaseResult {
            beforeSheet?()
            try authorize()
            purchases += 1
            duringPurchase?()
            if let purchaseFailure {
                throw purchaseFailure
            }
            return result
        }
        
        func unfinished() async throws -> [AntintwrkStoreReceipt] {
            duringUnfinished?()
            guard !unfinishedFailure else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            return restorable
        }
        
        func updates() -> AsyncStream<AntintwrkStoreReceipt> {
            AsyncStream { $0.finish() }
        }
        
        func finish(_ transactionID: UInt64) async {
            finished.append(transactionID)
        }
        
        func sync() async throws {
            syncs += 1
        }
    }
    
    private final class Server: AntintwrkStoreServer {
        let token: UUID
        var state: AntintwrkStoreSettlement.State = .credited
        var reject = false
        var checkoutAllowed = true
        var responseActor: String?
        var settlementActor: String?
        var requestOverride: AntintwrkStoreRequest?
        var duringSettlement: (() -> Void)?
        var events: [String] = []
        init(token: UUID) {
            self.token = token
        }
        
        func prepare(_ request: AntintwrkStoreRequest, actor: String) async throws -> AntintwrkStoreOrder {
            events.append("prepare")
            return .init(actor: responseActor ?? actor, productID: "kindness", request: requestOverride ?? request, accountToken: token, checkoutAllowed: checkoutAllowed)
        }
        
        func settle(_ receipt: AntintwrkStoreReceipt, actor: String) async throws -> AntintwrkStoreSettlement {
            events.append("settle")
            duringSettlement?()
            if reject {
                throw AntintwrkStoreKit.Failure.unavailable
            }
            return .init(actor: settlementActor ?? actor, transactionID: receipt.transactionID, state: state)
        }
        
        func status(_ order: AntintwrkStoreOrder, actor: String) async throws -> AntintwrkStoreSettlement {
            events.append("status")
            return .init(actor: settlementActor ?? actor, transactionID: 1, state: state)
        }
    }
}

@MainActor
private final class AntintwrkStorePendingMemory: AntintwrkStorePending {
    private var entries: [UUID: (String, String)] = [:]
    var beginFailure = false
    func contains(actor: String, productID: String) throws -> Bool {
        entries.values.contains { $0.0 == actor && $0.1 == productID }
    }
    
    func begin(_ order: AntintwrkStoreOrder) throws {
        guard !beginFailure else { throw AntintwrkStoreKit.Failure.unavailable }
        guard try !contains(actor: order.actor, productID: order.productID) else { throw AntintwrkStoreKit.Failure.busy }
        entries[order.accountToken] = (order.actor, order.productID)
    }
    
    func remove(actor: String, token: UUID) throws {
        guard entries[token]?.0 == actor else { return }
        entries[token] = nil
    }
}
