// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
@preconcurrency import KeychainAccess

protocol AntintwrkStorePending {
    func contains(actor: String, productID: String) throws -> Bool
    func begin(_ order: AntintwrkStoreOrder) throws
    func remove(actor: String, token: UUID) throws
}

/// Stores only order bindings, never receipts, tokens for authentication or message content.
final class AntintwrkStorePendingKeychain: AntintwrkStorePending {
    private struct Entry: Codable, Equatable {
        let actor: String
        let productID: String
        let token: UUID
    }
    
    private let keychain: Keychain
    private let key = "antintwrk.store.pending.v1"
    
    init(keychain: Keychain = Keychain(service: InfoPlistReader.main.baseBundleIdentifier + ".store-pending",
                                       accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
            .accessibility(.afterFirstUnlockThisDeviceOnly)) {
        self.keychain = keychain
    }
    
    func contains(actor: String, productID: String) throws -> Bool {
        try entries().contains { $0.actor == actor && $0.productID == productID }
    }
    
    func begin(_ order: AntintwrkStoreOrder) throws {
        var current = try entries()
        guard !current.contains(where: { $0.actor == order.actor && $0.productID == order.productID }) else { throw AntintwrkStoreKit.Failure.busy }
        current.append(.init(actor: order.actor, productID: order.productID, token: order.accountToken))
        try save(current)
    }
    
    func remove(actor: String, token: UUID) throws {
        try save(entries().filter { $0.actor != actor || $0.token != token })
    }
    
    private func entries() throws -> [Entry] {
        guard let data = try keychain.getData(key) else { return [] }
        guard data.count <= 65536 else { throw AntintwrkStoreKit.Failure.invalidReceipt }
        return try JSONDecoder().decode([Entry].self, from: data)
    }
    
    private func save(_ entries: [Entry]) throws {
        let data = try JSONEncoder().encode(entries)
        guard data.count <= 65536 else { throw AntintwrkStoreKit.Failure.unavailable }
        try keychain.set(data, key: key)
        guard try keychain.getData(key) == data else { throw AntintwrkStoreKit.Failure.unavailable }
    }
}
