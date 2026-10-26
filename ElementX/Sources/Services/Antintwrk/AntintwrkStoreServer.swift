// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

protocol AntintwrkStoreHTTPTransport {
    func storeRequest(_ action: String, fields: [String: String], actor: String) async throws -> Data
}

extension AntintwrkSocialClient: AntintwrkStoreHTTPTransport { }

/// Validates the authenticated server envelope before allowing a system payment or finishing it.
final class AntintwrkHTTPStoreServer: AntintwrkStoreServer {
    private let transport: any AntintwrkStoreHTTPTransport
    
    init(transport: any AntintwrkStoreHTTPTransport) {
        self.transport = transport
    }
    
    func prepare(_ request: AntintwrkStoreRequest, actor: String) async throws -> AntintwrkStoreOrder {
        let verification = ["verification_lifetime", "verification_monthly"].contains(request.key)
        guard request.requestKey.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              verification ? (request.applicationID > 0 && request.applicationID <= 999_999_999_999_999 && request.gratitude == nil) :
              (request.applicationID == 0 && request.key.range(of: "^(kindness_(1000|10000|100000|500000)|support_(1000|10000|100000))$", options: .regularExpression) != nil) else { throw AntintwrkStoreKit.Failure.unavailable }
        var fields = ["key": request.key, "requestKey": request.requestKey, "applicationId": String(request.applicationID)]
        if let target = request.gratitude {
            guard request.key.hasPrefix("kindness_"), ["publication", "reel"].contains(target.kind),
                  target.id.range(of: "^[1-9][0-9]{0,17}$", options: .regularExpression) != nil else { throw AntintwrkStoreKit.Failure.invalidReceipt }
            fields["gratitudeTargetKind"] = target.kind; fields["gratitudeTargetId"] = target.id
        }
        let reply = try await response("app-store-order", fields: fields, actor: actor)
        guard reply.productId == request.key, let rawToken = reply.appAccountToken,
              rawToken.range(of: "^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$", options: .regularExpression) != nil,
              let token = UUID(uuidString: rawToken), let checkoutAllowed = reply.checkoutAllowed, let environment = reply.environment, ["Production", "Sandbox"].contains(environment) else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        return .init(actor: actor, productID: request.key, request: request, accountToken: token, checkoutAllowed: checkoutAllowed, environment: environment)
    }
    
    func settle(_ receipt: AntintwrkStoreReceipt, actor: String) async throws -> AntintwrkStoreSettlement {
        guard let token = receipt.accountToken, receipt.transactionID > 0,
              (32...65536).contains(receipt.signedTransaction.utf8.count) else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        let reply = try await response("app-store-verify", fields: ["appAccountToken": token.uuidString.lowercased(), "signedTransaction": receipt.signedTransaction], actor: actor)
        let result = try settlement(reply, actor: actor)
        guard result.transactionID == receipt.transactionID else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        return result
    }
    
    func status(_ order: AntintwrkStoreOrder, actor: String) async throws -> AntintwrkStoreSettlement {
        guard order.actor == actor else { throw AntintwrkStoreKit.Failure.accountChanged }
        let reply = try await response("app-store-status", fields: ["appAccountToken": order.accountToken.uuidString.lowercased()], actor: actor)
        return try settlement(reply, actor: actor)
    }
    
    private struct Reply: Decodable {
        let ok: Bool
        let matrixUserId: String
        let productId: String?
        let appAccountToken: String?
        let checkoutAllowed: Bool?
        let environment: String?
        let transactionId: String?
        let state: String?
    }
    
    private func response(_ action: String, fields: [String: String], actor: String) async throws -> Reply {
        let data = try await transport.storeRequest(action, fields: fields, actor: actor)
        guard data.count <= 65536 else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok, reply.matrixUserId == actor else { throw AntintwrkStoreKit.Failure.accountChanged }
        return reply
    }
    
    private func settlement(_ reply: Reply, actor: String) throws -> AntintwrkStoreSettlement {
        guard let raw = reply.transactionId, let transactionID = UInt64(raw), String(transactionID) == raw else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        let state: AntintwrkStoreSettlement.State
        switch reply.state {
        case "pending": state = .pending
        case "credited" where transactionID > 0: state = .credited
        case "reversed" where transactionID > 0: state = .reversed
        default: throw AntintwrkStoreKit.Failure.invalidReceipt
        }
        return .init(actor: actor, transactionID: transactionID, state: state)
    }
}
