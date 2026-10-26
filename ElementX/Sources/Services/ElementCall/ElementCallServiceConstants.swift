//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum ElementCallServiceNotificationKey: String {
    case roomID
    case roomDisplayName
    /// When an incoming call is set to ring, there will be a `m.rtc.notification`event  (MSC4075).
    /// Keep the notification event id as it is needed to decline calls (MSC4310).
    case rtcNotifyEventID
    /// The Date at which the incoming call should stop ringing.
    case expirationDate
    case isVoiceCall
    case managedProof
}

nonisolated let ElementCallServiceNotificationDiscardDelta = 15.0

nonisolated struct AntintwrkIncomingCallProofStore {
    private struct Proof: Codable {
        let actor: String
        let roomID: String
        let eventID: String
        let expires: Date
    }
    
    private let defaults: UserDefaults?
    private let directory: URL?
    private static var sharedDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InfoPlistReader.main.appGroupIdentifier)?.appendingPathComponent("IncomingCallProofs", isDirectory: true)
    }
    
    var activeActor: String? {
        defaults?.string(forKey: "antintwrk.activeMessengerActor")
    }
    
    init(defaults: UserDefaults? = UserDefaults(suiteName: InfoPlistReader.main.appGroupIdentifier), directory: URL? = sharedDirectory) {
        self.defaults = defaults; self.directory = directory
    }
    
    static func isManagedActor(_ actor: String) -> Bool {
        actor.range(of: "^@u[1-9][0-9]{0,17}:antintwrk\\.com$", options: .regularExpression) != nil
    }
    
    static func fresh(actor: String, activeActor: String?, sender: String, timestamp: Date, expires: Date, now: Date) -> Bool {
        isManagedActor(actor) && activeActor == actor && sender != actor && isManagedActor(sender) &&
            abs(timestamp.timeIntervalSince(now)) < ElementCallServiceNotificationDiscardDelta && expires > now
    }
    
    func issue(actor: String, roomID: String, eventID: String, expires: Date, now: Date = Date()) -> String? {
        guard let defaults, Self.isManagedActor(actor), defaults.string(forKey: "antintwrk.activeMessengerActor") == actor,
              expires > now, !roomID.isEmpty, roomID.utf8.count <= 1024, !eventID.isEmpty, eventID.utf8.count <= 1024 else { return nil }
        guard let directory else { return nil }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var active = 0
        for file in files where file.pathExtension == "json" {
            if let proof = read(file), proof.expires > now {
                active += 1
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        guard active < 64 else { return nil }
        let nonce = UUID().uuidString
        let proof = Proof(actor: actor, roomID: roomID, eventID: eventID, expires: min(expires, now.addingTimeInterval(15)))
        guard let data = try? JSONEncoder().encode(proof) else { return nil }
        do { try data.write(to: directory.appendingPathComponent(nonce + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { return nil }
        return nonce
    }
    
    func consume(_ nonce: String?, roomID: String, eventID: String, sessionActor: String?, now: Date = Date()) -> Bool {
        guard let defaults, let nonce, UUID(uuidString: nonce) != nil else { return false }
        guard let directory else { return false }
        let file = directory.appendingPathComponent(nonce + ".json")
        let proof = read(file)
        try? FileManager.default.removeItem(at: file)
        guard let proof, proof.expires > now,
              proof.roomID == roomID, proof.eventID == eventID,
              defaults.string(forKey: "antintwrk.activeMessengerActor") == proof.actor,
              sessionActor == nil || sessionActor == proof.actor else { return false }
        return true
    }
    
    private func read(_ file: URL) -> Proof? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber, size.intValue <= 4096,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Proof.self, from: data)
    }
    
    func discard(_ nonce: String) {
        guard UUID(uuidString: nonce) != nil, let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(nonce + ".json"))
    }
}
