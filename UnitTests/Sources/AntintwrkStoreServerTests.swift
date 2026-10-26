// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Foundation
import Testing
import WebKit

@MainActor
struct AntintwrkStoreServerTests {
    private let actor = "@u18:antintwrk.com"
    private let token = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
    private var request: AntintwrkStoreRequest {
        .init(key: "kindness_1000", requestKey: String(repeating: "a", count: 32), applicationID: 0, gratitude: .init(kind: "publication", id: "42"))
    }
    
    @Test func preparationSendsIntentWithoutAClientSuppliedRecipient() async throws {
        let transport = Transport(reply: orderReply())
        let result = try await AntintwrkHTTPStoreServer(transport: transport).prepare(request, actor: actor)
        #expect(result.actor == actor && result.accountToken == token && result.checkoutAllowed)
        #expect(transport.action == "app-store-order")
        #expect(transport.fields == ["key": "kindness_1000", "requestKey": request.requestKey, "applicationId": "0", "gratitudeTargetKind": "publication", "gratitudeTargetId": "42"])
    }
    
    @Test func badgePreparationBindsApplicationBeforeCheckout() async throws {
        var reply = orderReply()
        reply["productId"] = "verification_lifetime"
        let transport = Transport(reply: reply)
        let request = AntintwrkStoreRequest(key: "verification_lifetime", requestKey: request.requestKey, applicationID: 101, gratitude: nil)
        let result = try await AntintwrkHTTPStoreServer(transport: transport).prepare(request, actor: actor)
        #expect(result.request.applicationID == 101 && result.productID == "verification_lifetime")
        #expect(transport.fields["applicationId"] == "101" && transport.fields["gratitudeTargetId"] == nil)
    }
    
    @Test(arguments: ["missingApplication", "negativeApplication", "oversizedApplication", "pointsApplication", "gratitude", "unknownProduct"])
    func invalidBadgeIntentNeverRequestsAnOrder(_ corruption: String) async {
        let transport = Transport(reply: orderReply())
        let key = corruption == "pointsApplication" ? "kindness_1000" : corruption == "unknownProduct" ? "verification_unknown" : "verification_monthly"
        let application = corruption == "missingApplication" ? 0 : corruption == "negativeApplication" ? -1 : corruption == "oversizedApplication" ? 1_000_000_000_000_000 : 101
        let target = corruption == "gratitude" ? AntintwrkStoreRequest.Target(kind: "publication", id: "42") : nil
        let intent = AntintwrkStoreRequest(key: key, requestKey: request.requestKey, applicationID: application, gratitude: target)
        await #expect(throws: (any Error).self) { try await AntintwrkHTTPStoreServer(transport: transport).prepare(intent, actor: actor) }
        #expect(transport.action == nil)
    }
    
    @Test(arguments: ["actor", "product", "token", "checkout", "environment", "ok"])
    func malformedPreparationCannotOpenPayment(_ field: String) async {
        var reply = orderReply()
        switch field {
        case "actor": reply["matrixUserId"] = "@u19:antintwrk.com"
        case "product": reply["productId"] = "support_1000"
        case "token": reply["appAccountToken"] = "invalid"
        case "checkout": reply.removeValue(forKey: "checkoutAllowed")
        case "environment": reply["environment"] = "Xcode"
        default: reply["ok"] = false
        }
        await #expect(throws: (any Error).self) { try await AntintwrkHTTPStoreServer(transport: Transport(reply: reply)).prepare(request, actor: actor) }
    }
    
    @Test func verificationUsesNativeSignedReceiptAndExactTransaction() async throws {
        let transport = Transport(reply: ["ok": true, "matrixUserId": actor, "transactionId": "1001", "state": "credited"])
        let receipt = AntintwrkStoreReceipt(transactionID: 1001, productID: request.key, accountToken: token, signedTransaction: String(repeating: "x", count: 64), revoked: false)
        let result = try await AntintwrkHTTPStoreServer(transport: transport).settle(receipt, actor: actor)
        #expect(result.state == .credited && result.transactionID == 1001)
        #expect(transport.fields["signedTransaction"] == receipt.signedTransaction)
        #expect(transport.fields["appAccountToken"] == token.uuidString.lowercased())
        transport.reply["transactionId"] = "1002"
        await #expect(throws: (any Error).self) { try await AntintwrkHTTPStoreServer(transport: transport).settle(receipt, actor: actor) }
    }
    
    @Test(arguments: ["unknown", "credited", "reversed"])
    func missingTransactionCannotClaimSettlement(_ state: String) async {
        let transport = Transport(reply: ["ok": true, "matrixUserId": actor, "transactionId": "0", "state": state])
        let order = AntintwrkStoreOrder(actor: actor, productID: request.key, request: request, accountToken: token, checkoutAllowed: false)
        await #expect(throws: (any Error).self) { try await AntintwrkHTTPStoreServer(transport: transport).status(order, actor: actor) }
    }
    
    @Test func pendingStatusIsNotCreditedAndForeignActorNeverRequestsIt() async throws {
        let transport = Transport(reply: ["ok": true, "matrixUserId": actor, "transactionId": "0", "state": "pending"])
        let server = AntintwrkHTTPStoreServer(transport: transport)
        let order = AntintwrkStoreOrder(actor: actor, productID: request.key, request: request, accountToken: token, checkoutAllowed: false)
        #expect(try await server.status(order, actor: actor).state == .pending)
        transport.action = nil
        await #expect(throws: (any Error).self) { try await server.status(order, actor: "@u19:antintwrk.com") }
        #expect(transport.action == nil)
    }
    
    @Test func nativeTransportRejectsGuestForeignActorAndUnknownActionBeforeNetworking() async throws {
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.0"), websiteDataStore: .nonPersistent())
        await #expect(throws: (any Error).self) { try await client.storeRequest("app-store-order", fields: [:], actor: actor) }
        try await client.recordAdmission(.init(stage: .authenticated, csrf: String(repeating: "a", count: 64), profileIdentity: nil, matrixUserId: actor, domainBinding: nil), origin: .russian)
        await #expect(throws: (any Error).self) { try await client.storeRequest("app-store-order", fields: [:], actor: "@u19:antintwrk.com") }
        await #expect(throws: (any Error).self) { try await client.storeRequest("arbitrary-action", fields: [:], actor: actor) }
        await client.logout(admission: nil, origin: .russian)
        await #expect(throws: (any Error).self) { try await client.storeRequest("app-store-verify", fields: [:], actor: actor) }
    }
    
    private func orderReply() -> [String: Any] {
        ["ok": true, "matrixUserId": actor, "productId": request.key, "appAccountToken": token.uuidString.lowercased(), "checkoutAllowed": true, "environment": "Production"]
    }
    
    private final class Transport: AntintwrkStoreHTTPTransport {
        var reply: [String: Any]
        var action: String?
        var fields = [String: String]()
        init(reply: [String: Any]) {
            self.reply = reply
        }
        
        func storeRequest(_ action: String, fields: [String: String], actor: String) async throws -> Data {
            self.action = action; self.fields = fields
            return try JSONSerialization.data(withJSONObject: reply)
        }
    }
}
