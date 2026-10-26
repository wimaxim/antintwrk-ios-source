// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Testing
import UserNotifications
import WebKit

@MainActor
struct AntintwrkSocialPushPermissionTests {
    @Test func guestAndDeniedPermissionNeverOpenAnotherPrompt() async throws {
        let suite = "antintwrk.push.permission.qa." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = UserNotificationCenterMock()
        center.authorizationStatusReturnValue = .denied
        var registrations = 0
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: .nonPersistent())
        let service = AntintwrkSocialPush(client: client, defaults: defaults, shared: defaults, permissionCenter: center, registerDevice: { registrations += 1 })
        await service.requestPermission()
        #expect(center.authorizationStatusCallsCount == 0)
        service.activate(actor: "@u42:antintwrk.com", language: "en")
        await service.requestPermission()
        await service.requestPermission()
        #expect(center.requestAuthorizationOptionsCallsCount == 0)
        #expect(service.permissionDenied && registrations == 0)
        await service.deactivate()
    }
    
    @Test func pendingPermissionIsCoalescedAndCannotRegisterAfterLogout() async throws {
        let suite = "antintwrk.push.permission.qa." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = UserNotificationCenterMock()
        center.authorizationStatusReturnValue = .notDetermined
        let answers = AsyncStream<Bool>.makeStream()
        center.requestAuthorizationOptionsClosure = { _ in
            await answers.stream.first(where: { @Sendable _ in true }) ?? false
        }
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: .nonPersistent())
        var registrations = 0
        let service = AntintwrkSocialPush(client: client, defaults: defaults, shared: defaults, permissionCenter: center, registerDevice: { registrations += 1 })
        service.activate(actor: "@u42:antintwrk.com", language: "en")
        for _ in 0..<20 where center.requestAuthorizationOptionsCallsCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.requestAuthorizationOptionsCallsCount == 1)
        await service.requestPermission()
        #expect(center.requestAuthorizationOptionsCallsCount == 1)
        await service.deactivate()
        center.authorizationStatusReturnValue = .authorized
        answers.continuation.yield(true); answers.continuation.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(registrations == 0)
    }
}
