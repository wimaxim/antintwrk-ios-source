// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import SwiftUI
import Testing

@MainActor
struct AntintwrkIncomingCallTests {
    private let actor = "@u18:antintwrk.com"
    private let sender = "@u19:antintwrk.com"
    
    @Test func freshResolvedCallDoesNotDependOnRoomCache() {
        let now = Date()
        #expect(AntintwrkIncomingCallProofStore.fresh(actor: actor, activeActor: actor, sender: sender, timestamp: now, expires: now.addingTimeInterval(60), now: now))
        #expect(!AntintwrkIncomingCallProofStore.fresh(actor: actor, activeActor: sender, sender: sender, timestamp: now, expires: now.addingTimeInterval(60), now: now))
        #expect(!AntintwrkIncomingCallProofStore.fresh(actor: actor, activeActor: actor, sender: actor, timestamp: now, expires: now.addingTimeInterval(60), now: now))
        #expect(!AntintwrkIncomingCallProofStore.fresh(actor: actor, activeActor: actor, sender: sender, timestamp: now.addingTimeInterval(-16), expires: now.addingTimeInterval(60), now: now))
        #expect(!AntintwrkIncomingCallProofStore.fresh(actor: actor, activeActor: actor, sender: sender, timestamp: now, expires: now, now: now))
    }
    
    @Test func receiptIsOneShotAndBoundToRoomEventAndCurrentActor() throws {
        let name = "com.antintwrk.incoming.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(actor, forKey: "antintwrk.activeMessengerActor")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AntintwrkIncomingCallProofStore(defaults: defaults, directory: directory)
        let now = Date()
        let nonce = try #require(store.issue(actor: actor, roomID: "!room:antintwrk.com", eventID: "$event", expires: now.addingTimeInterval(60), now: now))
        #expect(store.consume(nonce, roomID: "!room:antintwrk.com", eventID: "$event", sessionActor: actor, now: now))
        #expect(!store.consume(nonce, roomID: "!room:antintwrk.com", eventID: "$event", sessionActor: actor, now: now))
        let wrongRoom = try #require(store.issue(actor: actor, roomID: "!room:antintwrk.com", eventID: "$event", expires: now.addingTimeInterval(60), now: now))
        #expect(!store.consume(wrongRoom, roomID: "!other:antintwrk.com", eventID: "$event", sessionActor: actor, now: now))
        let switched = try #require(store.issue(actor: actor, roomID: "!room:antintwrk.com", eventID: "$event", expires: now.addingTimeInterval(60), now: now))
        defaults.set(sender, forKey: "antintwrk.activeMessengerActor")
        #expect(!store.consume(switched, roomID: "!room:antintwrk.com", eventID: "$event", sessionActor: sender, now: now))
        #expect(store.issue(actor: actor, roomID: "!room:antintwrk.com", eventID: "$event", expires: now.addingTimeInterval(60), now: now) == nil)
    }
    
    @Test func coldStartUsesVerifiedReceiptButExpiredOrRawPushCannotRing() throws {
        let name = "com.antintwrk.incoming.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(actor, forKey: "antintwrk.activeMessengerActor")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AntintwrkIncomingCallProofStore(defaults: defaults, directory: directory)
        let now = Date()
        #expect(!store.consume(nil, roomID: "!room", eventID: "$event", sessionActor: actor, now: now))
        #expect(!store.consume(UUID().uuidString, roomID: "!room", eventID: "$event", sessionActor: actor, now: now))
        let nonce = try #require(store.issue(actor: actor, roomID: "!room", eventID: "$event", expires: now.addingTimeInterval(60), now: now))
        #expect(store.consume(nonce, roomID: "!room", eventID: "$event", sessionActor: nil, now: now))
        let expired = try #require(store.issue(actor: actor, roomID: "!room", eventID: "$event", expires: now.addingTimeInterval(60), now: now))
        #expect(!store.consume(expired, roomID: "!room", eventID: "$event", sessionActor: actor, now: now.addingTimeInterval(16)))
    }
}
