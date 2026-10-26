// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import StoreKit
import SwiftUI

/// The page receives display prices and settlement state, never an Apple signed receipt.
final class AntintwrkStoreBridge {
    struct Price { let productID: String; let displayPrice: String }
    private struct Catalog: Decodable {
        struct Item: Decodable { let key: String; let productId: String; let purpose: String; let points: Int; let plan: String? }
        let ok: Bool
        let matrixUserId: String
        let products: [Item]
    }
    
    private let transport: any AntintwrkStoreHTTPTransport
    private let store: AntintwrkStoreKit
    private let prices: @MainActor ([String]) async throws -> [Price]
    private var actor: String?
    private var epoch = UUID()
    private var recovery: Task<Void, Never>?
    var onUpdated: ((String) -> Void)?
    var protectsNavigation: Bool {
        store.isCheckingOut
    }
    
    init(transport: any AntintwrkStoreHTTPTransport, store: AntintwrkStoreKit,
         prices: @escaping @MainActor ([String]) async throws -> [Price] = { ids in
             try await Product.products(for: ids).map { Price(productID: $0.id, displayPrice: $0.displayPrice) }
         }) {
        self.transport = transport; self.store = store; self.prices = prices
        store.onSettlement = { [weak self] actor in
            guard let self, self.actor == actor else { return }
            onUpdated?(actor)
        }
    }
    
    deinit { recovery?.cancel() }
    
    func activate(actor: String?) {
        guard actor != self.actor else { return }
        self.actor = actor; epoch = UUID()
        recovery?.cancel(); recovery = nil
        store.activate(actor: actor)
        guard let actor else { return }
        let captured = epoch
        recovery = Task { [weak self] in
            guard let self else { return }
            if let result = try? await store.restore(userInitiated: false), result.credited > 0,
               self.actor == actor, epoch == captured, !Task.isCancelled {
                onUpdated?(actor)
            }
        }
    }
    
    func request(_ message: [String: Any], actor expected: String) async throws -> [String: Any] {
        guard actor == expected else { throw AntintwrkStoreKit.Failure.accountChanged }
        let captured = epoch
        let result: [String: Any]
        switch message["type"] as? String {
        case "store-catalog":
            let data = try await transport.storeRequest("app-store-catalog", fields: ["support_v1": "1", "verification_v1": "1"], actor: expected)
            guard data.count <= 65536 else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            guard catalog.ok, catalog.matrixUserId == expected, catalog.products.count <= 9 else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            var keys = Set<String>()
            for item in catalog.products {
                let verification = item.purpose == "verification" && item.points == 0 && ["lifetime", "monthly"].contains(item.plan ?? "") && item.key == "verification_\(item.plan ?? "")"
                let points = ["kindness", "support"].contains(item.purpose) &&
                    (item.purpose == "kindness" ? [1000, 10000, 100_000, 500_000] : [1000, 10000, 100_000]).contains(item.points) && item.key == "\(item.purpose)_\(item.points)"
                guard verification || points, item.productId == item.key,
                      keys.insert(item.key).inserted else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            }
            let offers = try await prices(catalog.products.map(\.productId))
            guard Set(offers.map(\.productID)).count == offers.count,
                  offers.allSatisfy({ keys.contains($0.productID) && !$0.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.displayPrice.count <= 200 }) else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            var pendingProducts = Set<String>()
            for item in catalog.products where try store.hasPendingIntent(productID: item.productId) {
                pendingProducts.insert(item.productId)
            }
            result = ["provider": "apple", "gratitudePurchaseVersion": 1, "verificationPurchaseVersion": 1, "products": catalog.products.compactMap { item -> [String: Any]? in
                guard let offer = offers.first(where: { $0.productID == item.productId }) else { return nil }
                var product: [String: Any] = ["key": item.key, "purpose": item.purpose, "points": item.points, "price": offer.displayPrice, "pending": pendingProducts.contains(item.productId)]
                if item.purpose == "verification" {
                    product["plan"] = item.plan
                }
                return product
            }]
        case "store-purchase":
            guard let key = message["key"] as? String else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            var target: AntintwrkStoreRequest.Target?
            var requestKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            if let gratitude = message["gratitude"] {
                guard let fields = gratitude as? [String: String], let savedKey = fields["requestKey"],
                      let kind = fields["targetKind"], let id = fields["targetId"] else { throw AntintwrkStoreKit.Failure.invalidReceipt }
                requestKey = savedKey; target = .init(kind: kind, id: id)
            }
            let applicationID = message["applicationId"] as? Int ?? 0
            let outcome = try await store.purchase(.init(key: key, requestKey: requestKey, applicationID: applicationID, gratitude: target))
            if outcome == .cancelled {
                return try checked(["ok": false, "error": "STORE_CANCELLED"], actor: expected, epoch: captured)
            }
            result = ["state": outcome == .credited ? "credited" : outcome == .reversed ? "reversed" : "pending"]
        case "store-restore":
            let recovery = try await store.restore(userInitiated: true)
            guard recovery.failed == 0 else { throw AntintwrkStoreKit.Failure.unavailable }
            result = ["state": recovery.pending > 0 ? "pending" : "restored"]
        default: throw AntintwrkStoreKit.Failure.unavailable
        }
        return try checked(result, actor: expected, epoch: captured)
    }
    
    private func checked(_ reply: [String: Any], actor: String, epoch: UUID) throws -> [String: Any] {
        guard self.actor == actor, self.epoch == epoch else { throw AntintwrkStoreKit.Failure.accountChanged }
        return reply
    }
}
