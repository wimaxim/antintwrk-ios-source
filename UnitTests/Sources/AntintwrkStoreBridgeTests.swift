// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Foundation
import Testing

@MainActor
struct AntintwrkStoreBridgeTests {
    private let actor = "@fixture:antintwrk.com"
    
    @Test func appleAccountManagementCannotBecomeAnExternalCheckoutRedirect() throws {
        for origin in [AntintwrkClientConfiguration.SocialOrigin.global, .russian] {
            let policy = try AntintwrkSocialWebPolicy(origin: origin, configuration: .init(productVersion: "1.0.0"))
            for value in ["https://apps.apple.com/account/subscriptions", "https://reportaproblem.apple.com/"] {
                #expect(policy.appleBillingURL(value)?.absoluteString == value)
                #expect(policy.appleBillingURL(value + "?redirect=https://example.invalid") == nil)
                #expect(policy.appleBillingURL(value + "#fragment") == nil)
            }
            for value in ["https://reportaproblem.apple.com.attacker.invalid/", "http://reportaproblem.apple.com/", "https://u@reportaproblem.apple.com/", "https://apps.apple.com/account/subscriptions/other", "https://apps.apple.com/app/id1", "https://reportaproblem.apple.com:443/"] {
                #expect(policy.appleBillingURL(value) == nil)
            }
        }
    }
    
    @Test func guestNeverRequestsAStoreCatalog() async {
        let fixture = Fixture()
        await #expect(throws: (any Error).self) { _ = try await fixture.bridge.request(["type": "store-catalog"], actor: actor) }
        #expect(fixture.transport.calls == 0)
    }
    
    @Test func catalogUsesOnlyActualLocalizedApplePrices() async throws {
        let fixture = Fixture()
        fixture.bridge.activate(actor: actor)
        let reply = try await fixture.bridge.request(["type": "store-catalog"], actor: actor)
        let products = try #require(reply["products"] as? [[String: Any]])
        #expect(reply["provider"] as? String == "apple")
        #expect(products.count == 1 && products.first?["price"] as? String == "9,99 €")
        #expect(products.first?["key"] as? String == "kindness_1000")
        #expect(reply["gratitudePurchaseVersion"] as? Int == 1)
        #expect(fixture.transport.fields == ["support_v1": "1", "verification_v1": "1"])
    }
    
    @Test(arguments: ["actor", "product", "points", "purpose", "duplicate", "price", "unknownPrice"])
    func invalidCatalogNeverProvidesACheckoutOffer(_ corruption: String) async {
        let fixture = Fixture()
        switch corruption {
        case "actor": fixture.transport.actor = "other"
        case "product": fixture.transport.items[0]["productId"] = "other"
        case "points": fixture.transport.items[0]["points"] = 999
        case "purpose": fixture.transport.items[0]["purpose"] = "verification"
        case "duplicate": fixture.transport.items.append(fixture.transport.items[0])
        case "price": fixture.price = " "
        default: fixture.product = "unexpected"
        }
        fixture.bridge.activate(actor: actor)
        await #expect(throws: (any Error).self) { _ = try await fixture.bridge.request(["type": "store-catalog"], actor: actor) }
    }
    
    @Test func logoutDuringCatalogCannotReturnOldAccountOffers() async {
        let fixture = Fixture()
        fixture.bridge.activate(actor: actor)
        fixture.duringPrices = { fixture.bridge.activate(actor: nil) }
        await #expect(throws: (any Error).self) { _ = try await fixture.bridge.request(["type": "store-catalog"], actor: actor) }
    }
    
    @Test func missingAppleProductIsNotGivenAnInventedPrice() async throws {
        let fixture = Fixture()
        fixture.omitPrices = true
        fixture.bridge.activate(actor: actor)
        let reply = try await fixture.bridge.request(["type": "store-catalog"], actor: actor)
        #expect((reply["products"] as? [[String: Any]])?.isEmpty == true)
    }
    
    @Test func verificationCatalogPreservesTheServerPlanAndApplePrice() async throws {
        let fixture = Fixture()
        fixture.product = "verification_monthly"
        fixture.price = "5,00 €"
        fixture.transport.items = [["key": fixture.product, "productId": fixture.product, "purpose": "verification", "points": 0, "plan": "monthly"]]
        fixture.bridge.activate(actor: actor)
        let result = try await fixture.bridge.request(["type": "store-catalog"], actor: actor)
        let products = try #require(result["products"] as? [[String: Any]])
        #expect(products.count == 1 && products[0]["plan"] as? String == "monthly" && products[0]["price"] as? String == "5,00 €")
        fixture.transport.items[0]["plan"] = "lifetime"
        await #expect(throws: (any Error).self) { _ = try await fixture.bridge.request(["type": "store-catalog"], actor: actor) }
    }
    
    @Test func verificationPurchaseRetainsTheOwnedApplicationIntent() async throws {
        let fixture = Fixture()
        fixture.bridge.activate(actor: actor)
        let result = try await fixture.bridge.request(["type": "store-purchase", "key": "verification_lifetime", "applicationId": 101], actor: actor)
        #expect(fixture.server.prepared?.applicationID == 101 && fixture.server.prepared?.key == "verification_lifetime")
        #expect(fixture.server.prepared?.gratitude == nil)
        #expect(result["error"] as? String == "STORE_CANCELLED" && fixture.driver.purchases == 1)
    }
    
    @Test func cancelledAppleSheetKeepsTheExactAuthorIntentAndNeverReportsCredit() async throws {
        let fixture = Fixture()
        fixture.bridge.activate(actor: actor)
        let requestKey = String(repeating: "a", count: 32)
        let reply = try await fixture.bridge.request(["type": "store-purchase", "key": "kindness_1000", "gratitude": ["requestKey": requestKey, "targetKind": "publication", "targetId": "42"]], actor: actor)
        #expect(reply["ok"] as? Bool == false && reply["error"] as? String == "STORE_CANCELLED")
        #expect(fixture.server.prepared?.requestKey == requestKey)
        #expect(fixture.server.prepared?.gratitude == .init(kind: "publication", id: "42"))
        #expect(fixture.server.prepared?.applicationID == 0 && fixture.driver.purchases == 1)
        #expect(reply["signedTransaction"] == nil)
    }
    
    @Test func malformedAuthorIntentNeverPreparesAnOrderOrOpensPayment() async {
        let fixture = Fixture()
        fixture.bridge.activate(actor: actor)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.bridge.request(["type": "store-purchase", "key": "kindness_1000", "gratitude": ["targetKind": 42]], actor: actor)
        }
        #expect(fixture.server.prepared == nil && fixture.driver.purchases == 0)
    }
    
    @Test func checkingStatusCannotClaimAnUnresolvedApprovalWasRestored() async throws {
        let fixture = Fixture()
        fixture.bridge.activate(actor: actor)
        try fixture.pending.begin(.init(actor: actor, productID: "kindness_1000", request: .init(key: "kindness_1000", requestKey: "fixture", applicationID: 0, gratitude: nil), accountToken: UUID(), checkoutAllowed: true))
        let reply = try await fixture.bridge.request(["type": "store-restore"], actor: actor)
        #expect(reply["state"] as? String == "pending")
        #expect(fixture.driver.purchases == 0)
    }
    
    private final class Fixture {
        let transport = Transport()
        let server = Server()
        let driver = Driver()
        let pending = Pending()
        lazy var store = AntintwrkStoreKit(driver: driver, server: server, pending: pending)
        var price = "9,99 €"
        var product = "kindness_1000"
        var omitPrices = false
        var duringPrices: (() -> Void)?
        lazy var bridge = AntintwrkStoreBridge(transport: transport, store: store, prices: { [weak self] _ in
            guard let self else { return [] }
            duringPrices?()
            return omitPrices ? [] : [.init(productID: product, displayPrice: price)]
        })
    }
    
    private final class Transport: AntintwrkStoreHTTPTransport {
        var calls = 0
        var fields: [String: String] = [:]
        var actor = "@fixture:antintwrk.com"
        var items: [[String: Any]] = [["key": "kindness_1000", "productId": "kindness_1000", "purpose": "kindness", "points": 1000]]
        func storeRequest(_ action: String, fields: [String: String], actor: String) async throws -> Data {
            calls += 1; self.fields = fields
            return try JSONSerialization.data(withJSONObject: ["ok": true, "matrixUserId": self.actor, "products": items])
        }
    }
    
    private final class Pending: AntintwrkStorePending {
        private var entries: [UUID: AntintwrkStoreOrder] = [:]
        func contains(actor: String, productID: String) throws -> Bool {
            entries.values.contains { $0.actor == actor && $0.productID == productID }
        }
        
        func tokens(actor: String) throws -> Set<UUID> {
            Set(entries.filter { $0.value.actor == actor }.map(\.key))
        }
        
        func begin(_ order: AntintwrkStoreOrder) throws {
            entries[order.accountToken] = order
        }
        
        func remove(actor: String, token: UUID) throws {
            guard entries[token]?.actor == actor else { return }
            entries[token] = nil
        }
    }
    
    private final class Server: AntintwrkStoreServer {
        var prepared: AntintwrkStoreRequest?
        func prepare(_ request: AntintwrkStoreRequest, actor: String) async throws -> AntintwrkStoreOrder {
            prepared = request
            return .init(actor: actor, productID: request.key, request: request, accountToken: UUID(), checkoutAllowed: true)
        }
        
        func settle(_ receipt: AntintwrkStoreReceipt, actor: String) async throws -> AntintwrkStoreSettlement {
            throw AntintwrkStoreKit.Failure.unavailable
        }
        
        func status(_ order: AntintwrkStoreOrder, actor: String) async throws -> AntintwrkStoreSettlement {
            throw AntintwrkStoreKit.Failure.unavailable
        }
    }
    
    private final class Driver: AntintwrkStoreDriver {
        var purchases = 0
        func purchase(_ order: AntintwrkStoreOrder, authorize: @escaping @MainActor () throws -> Void) async throws -> AntintwrkStoreKit.PurchaseResult {
            try authorize(); purchases += 1
            return .cancelled
        }
        
        func unfinished() async throws -> [AntintwrkStoreReceipt] {
            []
        }
        
        func updates() -> AsyncStream<AntintwrkStoreReceipt> {
            AsyncStream { $0.finish() }
        }
        
        func finish(_ transactionID: UInt64) async { }
        func sync() async throws { }
    }
}

@MainActor
struct AntintwrkAssistancePolicyTests {
    private let signature = "fixture." + String(repeating: "a", count: 43)
    
    @Test func charityReferralsOpenOnlyTheirApprovedPublicDestinations() throws {
        let configuration = try AntintwrkClientConfiguration(productVersion: "1.0.0")
        for origin in [AntintwrkClientConfiguration.SocialOrigin.global, .russian] {
            let policy = AntintwrkSocialWebPolicy(origin: origin, configuration: configuration)
            for language in AntintwrkClientConfiguration.supportedLanguages {
                for target in ["https://antintwrk.com/\(language)/ukraine?app_ref=\(signature)", "https://cerebralpalsycommunity.org/\(language)/give?source=heroworld&ref=\(signature)", "https://helpcp.org/\(language)/help/davidnewman?ref=\(signature)&source=heroworld"] {
                    #expect(policy.assistanceURL(target)?.absoluteString == target)
                }
            }
        }
    }
    
    @Test(arguments: ["http://antintwrk.com/en/ukraine", "https://antintwrk.com:443/en/ukraine", "https://user@antintwrk.com/en/ukraine", "https://antimsg.com/en/ukraine", "https://antintwrk.com/en/kindness", "https://antintwrk.com/en/ukraine/extra", "https://antintwrk.com.evil.test/en/ukraine"])
    func alteredAssistanceOriginOrRouteIsRejected(_ prefix: String) throws {
        let policy = try AntintwrkSocialWebPolicy(origin: .russian, configuration: .init(productVersion: "1.0.0"))
        #expect(policy.assistanceURL(prefix + "?app_ref=" + signature) == nil)
    }
    
    @Test func credentialsAndExtraQueryFieldsCannotEscapeToAnExternalBrowser() throws {
        let policy = try AntintwrkSocialWebPolicy(origin: .global, configuration: .init(productVersion: "1.0.0"))
        let valid = "https://antintwrk.com/en/ukraine?app_ref=" + signature
        for suffix in ["&csrf=private", "&app_ref=" + signature, "#fragment"] {
            #expect(policy.assistanceURL(valid + suffix) == nil)
        }
        #expect(policy.assistanceURL("https://helpcp.org/en/help/davidnewman?source=other&ref=" + signature) == nil)
        #expect(policy.assistanceURL("https://antintwrk.com/en/ukraine?app_ref=invalid") == nil)
    }
}
