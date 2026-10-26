// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import UIKit
import UserNotifications

@MainActor
@Observable
final class AntintwrkSocialPush {
    static let categories = ["friends", "messages", "comments", "votes", "important"]
    private let client: AntintwrkSocialClient
    private let defaults: UserDefaults
    private let shared: UserDefaults?
    private let permissionCenter: UserNotificationCenterProtocol
    private let registerDevice: () -> Void
    private var actor: String?
    private var generation = UUID()
    private var registration: Task<Void, Never>?
    private var token: String?
    private var previousToken: String?
    private var language = "en"
    private var permissionPending = false
    private var lastRegistration: String?
    private var refreshedAt: Date?
    var busy = false
    var failed = false
    var available = false
    var permissionDenied = false
    private var permissionGranted = false
    var deviceEnabled = false
    var registering: Bool {
        deviceEnabled && preferences["enabled"] == true && !permissionDenied && AntintwrkSocialPushBinding.load(from: shared) == nil
    }
    
    var preferences = ["enabled": false, "friends": true, "messages": true, "comments": true, "votes": false, "important": true]
    
    init(client: AntintwrkSocialClient, defaults: UserDefaults = .standard, shared: UserDefaults? = UserDefaults(suiteName: InfoPlistReader.main.appGroupIdentifier),
         permissionCenter: UserNotificationCenterProtocol = UNUserNotificationCenter.current(),
         registerDevice: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.client = client; self.defaults = defaults; self.shared = shared
        self.permissionCenter = permissionCenter; self.registerDevice = registerDevice
        token = defaults.string(forKey: "antintwrk.socialPushToken")
    }
    
    func activate(actor: String, language: String) {
        if self.actor != actor {
            generation = UUID(); registration?.cancel(); lastRegistration = nil
            self.actor = actor
            busy = false; failed = false; available = false; refreshedAt = nil
            preferences = ["enabled": false, "friends": true, "messages": true, "comments": true, "votes": false, "important": true]
            deviceEnabled = defaults.string(forKey: "antintwrk.socialPushEnabledActor") == actor
            if AntintwrkSocialPushBinding.load(from: shared)?.actor != actor {
                clearBinding()
            }
        }
        self.language = language
        updateLanguage(language)
        Task { await requestPermission(); await refresh() }
    }
    
    func updateLanguage(_ language: String) {
        self.language = language
        if let value = AntintwrkSocialPushBinding.load(from: shared), value.actor == actor {
            saveBinding(.init(actor: value.actor, binding: value.binding, language: language))
        }
    }
    
    func received(token: Data) {
        guard (32...256).contains(token.count) else { return }
        let value = token.map { String(format: "%02x", $0) }.joined()
        if self.token != value {
            previousToken = self.token
            clearBinding(); lastRegistration = nil
        }
        self.token = value; defaults.set(value, forKey: "antintwrk.socialPushToken")
        scheduleRegistration()
    }
    
    func requestPermission() async {
        guard actor != nil, !permissionPending else { return }
        permissionPending = true
        defer { permissionPending = false }
        let captured = generation
        let center = permissionCenter
        var status = await center.authorizationStatus()
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.authorizationStatus()
        }
        guard generation == captured, actor != nil else { return }
        permissionDenied = status == .denied
        permissionGranted = status == .authorized || status == .provisional || status == .ephemeral
        if permissionGranted {
            registerDevice()
        }
    }
    
    func refresh(force: Bool = false) async {
        guard let actor, !busy else { return }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 30 {
            scheduleRegistration(); return
        }
        let captured = generation
        busy = true; failed = false
        defer {
            if captured == generation {
                busy = false
            }
        }
        do {
            let data = try await client.pushRequest("push-settings", actor: actor)
            let reply = try JSONDecoder().decode(Settings.self, from: data)
            guard captured == generation, self.actor == actor else { return }
            refreshedAt = Date()
            available = reply.available
            preferences = reply.preferences
            if preferences["enabled"] != true {
                clearBinding(); lastRegistration = nil
            }
            scheduleRegistration()
        } catch {
            if captured == generation {
                failed = true
            }
        }
    }
    
    /// Only this explicit action may enable shared preferences; token refresh never does.
    func setDeviceEnabled(_ enabled: Bool) async {
        guard let actor, !busy else { return }
        let captured = generation
        busy = true; failed = false
        defer {
            if captured == generation {
                busy = false
            }
        }
        if !enabled {
            deviceEnabled = false; defaults.removeObject(forKey: "antintwrk.socialPushEnabledActor")
            clearBinding(); registration?.cancel(); lastRegistration = nil
        }
        do {
            if enabled {
                await requestPermission()
                guard captured == generation, permissionGranted, available else { throw Failure.unavailable }
                var next = preferences; next["enabled"] = true
                _ = try await client.pushRequest("push-preferences", fields: Self.fields(next), actor: actor)
                guard captured == generation else { return }
                preferences = next; deviceEnabled = true
                defaults.set(actor, forKey: "antintwrk.socialPushEnabledActor")
                // The APNs callback may still be pending; it will register as soon as it arrives.
                scheduleRegistration()
            } else if let token {
                _ = try await client.pushRequest("push-unsubscribe", fields: target(token), actor: actor)
            }
        } catch {
            if captured == generation {
                failed = true
            }
        }
    }
    
    func setCategory(_ category: String, enabled: Bool) async {
        guard Self.categories.contains(category), let actor, !busy else { return }
        let captured = generation
        busy = true; failed = false
        defer {
            if captured == generation {
                busy = false
            }
        }
        var next = preferences; next[category] = enabled
        do {
            _ = try await client.pushRequest("push-preferences", fields: Self.fields(next), actor: actor)
            guard captured == generation else { return }
            preferences = next
        } catch {
            if captured == generation {
                failed = true
            }
        }
    }
    
    func deactivate() async {
        let oldActor = actor; let oldToken = token
        generation = UUID(); actor = nil; busy = false; deviceEnabled = false
        registration?.cancel(); registration = nil; lastRegistration = nil
        defaults.removeObject(forKey: "antintwrk.socialPushEnabledActor")
        clearBinding()
        if let oldActor, let oldToken {
            _ = try? await client.pushRequest("push-unsubscribe", fields: target(oldToken), actor: oldActor)
        }
    }
    
    private func scheduleRegistration() {
        guard let actor, let token, deviceEnabled, available, preferences["enabled"] == true, permissionGranted else { return }
        let key = actor + ":" + token
        guard lastRegistration != key else { return }
        lastRegistration = key
        registration?.cancel()
        let captured = generation
        registration = Task {
            do {
                let data = try await client.pushRequest("push-subscribe", fields: target(token), actor: actor)
                let result = try JSONDecoder().decode(Subscription.self, from: data)
                guard captured == generation, self.actor == actor, self.token == token, deviceEnabled, !Task.isCancelled else { return }
                let binding = AntintwrkSocialPushBinding(actor: actor, binding: result.binding, language: language)
                guard binding.isValid else { throw Failure.unavailable }
                saveBinding(binding)
                if let previousToken, previousToken != token {
                    self.previousToken = nil
                    _ = try? await client.pushRequest("push-unsubscribe", fields: target(previousToken), actor: actor)
                }
            } catch {
                if captured == generation, self.token == token {
                    lastRegistration = nil; failed = true
                }
            }
        }
    }
    
    private func target(_ token: String) -> [String: String] {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        return ["environment": environment, "apns_token": token]
    }
    
    private static func fields(_ preferences: [String: Bool]) -> [String: String] {
        preferences.mapValues { $0 ? "1" : "0" }
    }
    
    private func saveBinding(_ value: AntintwrkSocialPushBinding) {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return }
        shared?.set(data, forKey: AntintwrkSocialPushBinding.key)
    }
    
    private func clearBinding() {
        shared?.removeObject(forKey: AntintwrkSocialPushBinding.key)
        // Remove only social alerts, preserving Matrix and call notifications.
        let captured = generation
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            guard captured == generation else { return }
            let active = AntintwrkSocialPushBinding.load(from: shared)
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
                $0.request.content.userInfo["kind"] as? String == AntintwrkSocialPushBinding.kind && active?.matches($0.request.content.userInfo) != true
            }.map(\.request.identifier))
        }
    }
    
    private struct Settings: Decodable { let available: Bool; let preferences: [String: Bool] }
    private struct Subscription: Decodable { let binding: String }
    private enum Failure: Error { case unavailable }
}
