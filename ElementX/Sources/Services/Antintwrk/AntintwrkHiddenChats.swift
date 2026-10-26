// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@MainActor
struct AntintwrkHiddenChats {
    static let changed = Notification.Name("antintwrk.hiddenChatsChanged")
    let actor: String
    var store: UserDefaults = .standard
    private var key: String {
        "antintwrk.hiddenChats." + actor
    }
    
    func hide(_ roomID: String, lastMessage: Date?) {
        var entries = store.dictionary(forKey: key) as? [String: Double] ?? [:]
        entries[roomID] = lastMessage?.timeIntervalSince1970 ?? 0
        store.set(entries, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: actor)
    }
    
    func reveal(_ roomID: String) {
        var entries = store.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard entries.removeValue(forKey: roomID) != nil else { return }
        store.set(entries, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: actor)
    }
    
    func isHidden(_ roomID: String, lastMessage: Date?) -> Bool {
        let entries = store.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard let watermark = entries[roomID] else { return false }
        if let lastMessage, lastMessage.timeIntervalSince1970 > watermark {
            reveal(roomID); return false
        }
        return true
    }
}
