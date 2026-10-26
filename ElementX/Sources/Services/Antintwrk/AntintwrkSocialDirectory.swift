// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@MainActor
final class AntintwrkSocialDirectory: UserDiscoveryServiceProtocol {
    let social: AntintwrkSocialClient
    let client: ClientProxyProtocol
    let actor: String
    private var pending: Task<String, Error>?
    private var pendingID = UUID()
    private var valid = true
    
    init(social: AntintwrkSocialClient, client: ClientProxyProtocol) {
        self.social = social; self.client = client; actor = client.userID
    }
    
    static func socialID(_ userID: String) -> String? {
        guard userID.range(of: "^@u[1-9][0-9]{0,17}:antintwrk\\.com$", options: .regularExpression) != nil else { return nil }
        return String(userID.dropFirst(2).split(separator: ":")[0])
    }
    
    func invalidate() {
        valid = false; pending?.cancel(); pending = nil
    }
    
    func searchProfiles(with searchQuery: String) async -> Result<[UserProfile], UserDiscoveryErrorType> {
        guard valid, client.userID == actor else { return .failure(.failedSearchingUsers) }
        do {
            let users = try await social.messengerPeople(query: searchQuery, actor: actor)
            guard valid, !Task.isCancelled else { return .failure(.failedSearchingUsers) }
            return .success(users)
        } catch { return .failure(.failedSearchingUsers) }
    }
    
    func resolve(recipient: String) async throws -> String {
        let previous = pending
        let id = UUID(); pendingID = id
        defer {
            if pendingID == id {
                pending = nil
            }
        }
        let task = Task { [self] in
            _ = try? await previous?.value
            try checkActor()
            try await social.authorizeRecipient(recipient, actor: actor)
            try checkActor()
            let known = try client.directRoomForUserID(recipient).get()
            let invitation = client.staticRoomSummaryProvider.roomListPublisher.value.first {
                guard $0.isDirect, case .invite(let inviter)? = $0.joinRequestType else { return false }
                return inviter?.userID == recipient || $0.heroes.contains { $0.id == recipient }
            }
            if let roomID = known ?? invitation?.id, let room = await client.roomForIdentifier(roomID) {
                switch room {
                case .joined(let proxy):
                    guard proxy.infoPublisher.value.isDirect else { throw AntintwrkSocialClient.Failure.rejected }
                    return roomID
                case .invited(let proxy):
                    guard proxy.info.isDirect else { throw AntintwrkSocialClient.Failure.rejected }
                    try await client.joinRoom(roomID, via: []).get()
                    for _ in 0..<100 {
                        try checkActor()
                        if case .joined = await client.roomForIdentifier(roomID) {
                            return roomID
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw AntintwrkSocialClient.Failure.unavailable
                case .banned, .knocked: throw AntintwrkSocialClient.Failure.rejected
                case .left: break
                }
            }
            try checkActor()
            return try await client.createDirectRoom(with: recipient, expectedRoomName: nil).get()
        }
        pending = task
        let result = try await task.value
        AntintwrkHiddenChats(actor: actor).reveal(result)
        try checkActor()
        return result
    }
    
    private func checkActor() throws {
        guard valid, client.userID == actor, !Task.isCancelled else { throw AntintwrkSocialClient.Failure.cancelled }
    }
}
