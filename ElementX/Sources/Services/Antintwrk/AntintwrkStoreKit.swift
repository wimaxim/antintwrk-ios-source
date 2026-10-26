// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import StoreKit
import SwiftUI

struct AntintwrkStoreRequest: Equatable {
    struct Target: Equatable { let kind: String; let id: String }
    let key: String
    let requestKey: String
    let applicationID: Int
    let gratitude: Target?
}

struct AntintwrkStoreOrder {
    let actor: String
    let productID: String
    let request: AntintwrkStoreRequest
    let accountToken: UUID
    let checkoutAllowed: Bool
    let environment: String
    
    init(actor: String, productID: String, request: AntintwrkStoreRequest, accountToken: UUID, checkoutAllowed: Bool, environment: String = "Production") {
        self.actor = actor; self.productID = productID; self.request = request; self.accountToken = accountToken
        self.checkoutAllowed = checkoutAllowed; self.environment = environment
    }
}

struct AntintwrkStoreReceipt: Sendable {
    let transactionID: UInt64
    let productID: String
    let accountToken: UUID?
    let signedTransaction: String
    let revoked: Bool
}

struct AntintwrkStoreSettlement {
    enum State { case pending, credited, reversed }
    let actor: String
    let transactionID: UInt64
    let state: State
}

protocol AntintwrkStoreServer {
    func prepare(_ request: AntintwrkStoreRequest, actor: String) async throws -> AntintwrkStoreOrder
    func settle(_ receipt: AntintwrkStoreReceipt, actor: String) async throws -> AntintwrkStoreSettlement
    func status(_ order: AntintwrkStoreOrder, actor: String) async throws -> AntintwrkStoreSettlement
}

protocol AntintwrkStoreDriver {
    func purchase(_ order: AntintwrkStoreOrder, authorize: @escaping @MainActor () throws -> Void) async throws -> AntintwrkStoreKit.PurchaseResult
    func unfinished() async throws -> [AntintwrkStoreReceipt]
    func updates() -> AsyncStream<AntintwrkStoreReceipt>
    func finish(_ transactionID: UInt64) async
    func sync() async throws
}

/// Finishes a store transaction only after the authenticated server confirms its ledger result.
final class AntintwrkStoreKit {
    enum Failure: Error { case accountChanged, invalidReceipt, unavailable, busy }
    enum Outcome: Equatable { case credited, pending, reversed, cancelled }
    struct RecoverySummary: Equatable {
        var credited = 0
        var pending = 0
        var reversed = 0
        var failed = 0
    }
    
    enum PurchaseResult { case purchased(AntintwrkStoreReceipt), pending, cancelled }
    
    private let driver: any AntintwrkStoreDriver
    private let server: any AntintwrkStoreServer
    private let pending: any AntintwrkStorePending
    private var actor: String?
    private var epoch = UUID()
    private var checkout: UUID?
    private var processing: [UInt64: UUID] = [:]
    private var listener: Task<Void, Never>?
    var onSettlement: ((String) -> Void)?
    var isCheckingOut: Bool {
        checkout != nil
    }
    
    init(driver: any AntintwrkStoreDriver, server: any AntintwrkStoreServer, pending: any AntintwrkStorePending) {
        self.driver = driver
        self.server = server
        self.pending = pending
    }
    
    deinit { listener?.cancel() }
    
    func activate(actor: String?) {
        guard actor != self.actor else { return }
        self.actor = actor
        epoch = UUID()
        checkout = nil
        listener?.cancel()
        listener = nil
        guard actor != nil else { return }
        let stream = driver.updates()
        listener = Task { [weak self] in
            for await receipt in stream {
                guard !Task.isCancelled else { return }
                try? await self?.process(receipt)
            }
        }
    }
    
    func hasPendingIntent(productID: String) throws -> Bool {
        guard let actor else { throw Failure.accountChanged }
        return try pending.contains(actor: actor, productID: productID)
    }
    
    func purchase(_ request: AntintwrkStoreRequest) async throws -> Outcome {
        guard let actor else { throw Failure.accountChanged }
        guard checkout == nil else { throw Failure.busy }
        let captured = epoch
        let lease = UUID()
        checkout = lease
        defer {
            if checkout == lease {
                checkout = nil
            }
        }
        let order = try await server.prepare(request, actor: actor)
        try requireActor(actor, captured)
        guard order.actor == actor, order.request == request, !order.productID.isEmpty else { throw Failure.invalidReceipt }
        // A crash after Apple charged but before server delivery leaves this order unfinished.
        let unfinished = try await driver.unfinished()
        try requireActor(actor, captured)
        let existing = unfinished.filter { $0.accountToken == order.accountToken }
        guard existing.count <= 1 else { throw Failure.invalidReceipt }
        if let receipt = existing.first {
            guard receipt.productID == order.productID else { throw Failure.invalidReceipt }
            return try await process(receipt)
        }
        // An existing server-bound checkout must never trigger another store payment.
        if !order.checkoutAllowed {
            let state = try await server.status(order, actor: actor)
            try requireActor(actor, captured)
            guard state.actor == actor else { throw Failure.invalidReceipt }
            if state.state != .pending {
                try pending.remove(actor: actor, token: order.accountToken)
            }
            return state.state == .credited ? .credited : state.state == .reversed ? .reversed : .pending
        }
        // Ask to Buy/SCA may not have a transaction yet. A relaunch or another page must not pay again.
        if try pending.contains(actor: actor, productID: order.productID) {
            return .pending
        }
        let result: PurchaseResult
        do {
            result = try await driver.purchase(order, authorize: { [weak self] in
                guard let self else { throw Failure.accountChanged }
                try requireActor(actor, captured)
                try pending.begin(order)
            })
        } catch StoreKitError.userCancelled {
            // StoreKit can report a known cancellation as an error instead of a purchase result.
            try pending.remove(actor: actor, token: order.accountToken)
            try requireActor(actor, captured)
            return .cancelled
        }
        if case .cancelled = result {
            try pending.remove(actor: actor, token: order.accountToken)
        }
        try requireActor(actor, captured)
        switch result {
        case .cancelled: return .cancelled
        case .pending: return .pending
        case let .purchased(receipt):
            guard receipt.productID == order.productID, receipt.accountToken == order.accountToken, !receipt.revoked else { throw Failure.invalidReceipt }
            return try await process(receipt)
        }
    }
    
    /// User-initiated restore uses AppStore.sync; ordinary admission only retries unfinished delivery.
    @discardableResult
    func restore(userInitiated: Bool) async throws -> RecoverySummary {
        guard let actor else { throw Failure.accountChanged }
        let captured = epoch
        if userInitiated {
            try await driver.sync()
        }
        try requireActor(actor, captured)
        var summary = RecoverySummary()
        for receipt in try await driver.unfinished() {
            try requireActor(actor, captured)
            // A failed or different-account receipt remains unfinished; other deliveries can recover.
            do {
                switch try await process(receipt) {
                case .credited: summary.credited += 1
                case .pending: summary.pending += 1
                case .reversed: summary.reversed += 1
                case .cancelled: throw Failure.invalidReceipt
                }
            } catch {
                summary.failed += 1
            }
        }
        try requireActor(actor, captured)
        return summary
    }
    
    private func process(_ receipt: AntintwrkStoreReceipt) async throws -> Outcome {
        guard let actor else { throw Failure.accountChanged }
        guard receipt.accountToken != nil, !receipt.signedTransaction.isEmpty, receipt.transactionID > 0 else { throw Failure.invalidReceipt }
        guard processing[receipt.transactionID] == nil else { return .pending }
        let captured = epoch
        let lease = UUID()
        processing[receipt.transactionID] = lease
        defer {
            if processing[receipt.transactionID] == lease {
                processing[receipt.transactionID] = nil
            }
        }
        let settlement = try await server.settle(receipt, actor: actor)
        try requireActor(actor, captured)
        guard settlement.actor == actor, settlement.transactionID == receipt.transactionID,
              !receipt.revoked || settlement.state == .reversed else { throw Failure.invalidReceipt }
        guard settlement.state != .pending else { return .pending }
        if let token = receipt.accountToken {
            try pending.remove(actor: actor, token: token)
        }
        await driver.finish(receipt.transactionID)
        try requireActor(actor, captured)
        onSettlement?(actor)
        return settlement.state == .credited ? .credited : .reversed
    }
    
    private func requireActor(_ expected: String, _ captured: UUID) throws {
        guard actor == expected, epoch == captured else { throw Failure.accountChanged }
    }
}

final class AntintwrkAppleStoreDriver: AntintwrkStoreDriver {
    private var transactions: [UInt64: StoreKit.Transaction] = [:]
    
    func purchase(_ order: AntintwrkStoreOrder, authorize: @escaping @MainActor () throws -> Void) async throws -> AntintwrkStoreKit.PurchaseResult {
        guard AppStore.canMakePayments,
              let product = try await Product.products(for: [order.productID]).first,
              product.id == order.productID else { throw AntintwrkStoreKit.Failure.unavailable }
        guard case let .verified(app) = try await AppTransaction.shared, app.bundleID == "com.antintwrk.app" else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        #if DEBUG
        let localFixture = ProcessInfo.processInfo.environment["ANTINTWRK_STOREKIT_LOCAL_TEST"] == "1" && ProcessInfo.processInfo.environment["IS_RUNNING_UNIT_TESTS"] == "1" && app.environment == .xcode
        #else
        let localFixture = false
        #endif
        guard localFixture || Self.environmentMatches(order.environment, actual: app.environment) else { throw AntintwrkStoreKit.Failure.unavailable }
        try authorize()
        // Product's system sheet provides the real localized price. No client-synthesized price.
        switch try await product.purchase(options: [.appAccountToken(order.accountToken)]) {
        case let .success(result): return try .purchased(receipt(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw AntintwrkStoreKit.Failure.unavailable
        }
    }
    
    static func environmentMatches(_ expected: String, actual: AppStore.Environment) -> Bool {
        (expected == "Production" && actual == .production) || (expected == "Sandbox" && actual == .sandbox)
    }
    
    func unfinished() async throws -> [AntintwrkStoreReceipt] {
        var receipts: [AntintwrkStoreReceipt] = []
        for await result in StoreKit.Transaction.unfinished {
            // An unverifiable paid transaction must not disappear from the duplicate-charge check.
            try receipts.append(receipt(result))
        }
        return receipts
    }
    
    func updates() -> AsyncStream<AntintwrkStoreReceipt> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled else { break }
                    if let value = try? self?.receipt(result) {
                        continuation.yield(value)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    func finish(_ transactionID: UInt64) async {
        guard let transaction = transactions[transactionID] else { return }
        await transaction.finish()
        transactions[transactionID] = nil
    }
    
    func sync() async throws {
        try await AppStore.sync()
    }
    
    private func receipt(_ result: VerificationResult<StoreKit.Transaction>) throws -> AntintwrkStoreReceipt {
        guard case let .verified(transaction) = result, transaction.productType != .nonRenewable,
              transaction.appBundleID == "com.antintwrk.app", transaction.purchasedQuantity == 1 else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        transactions[transaction.id] = transaction
        return .init(transactionID: transaction.id, productID: transaction.productID, accountToken: transaction.appAccountToken,
                     signedTransaction: result.jwsRepresentation, revoked: transaction.revocationDate != nil)
    }
}
