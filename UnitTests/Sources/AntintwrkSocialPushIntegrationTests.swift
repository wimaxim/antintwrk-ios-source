// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import SwiftUI
import WebKit
import XCTest

/// Opt-in ordinary QA account only. Real HTTP subscription boundaries; synthetic token, no real notification sent.
final nonisolated class AntintwrkSocialPushIntegrationTests: XCTestCase {
    @MainActor
    func testActualPreferencesSubscriptionLogoutAndSettingsRender() async throws {
        guard ProcessInfo.processInfo.environment["ANTINTWRK_LIVE_STORE_WEB_QA"] == "1" else { throw XCTSkip("Ordinary QA fixture required") }
        let url = URL.libraryDirectory.appending(path: "antintwrk-reviewer-qa.json")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try AntintwrkSocialClient(configuration: .init(productVersion: "1.0.26"), websiteDataStore: .nonPersistent())
        let admission = try await client.login(email: XCTUnwrap(fields["email"]), password: XCTUnwrap(fields["password"]), language: "en")
        let actor = try XCTUnwrap(admission.matrixUserId)
        let originalData = try await client.pushRequest("push-settings", actor: actor)
        let originalReply = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        let original = try XCTUnwrap(originalReply["preferences"] as? [String: Bool])
        XCTAssertEqual(originalReply["available"] as? Bool, true)
        let suite = "antintwrk.push.integration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(actor, forKey: "antintwrk.activeMessengerActor")
        let center = UserNotificationCenterMock()
        center.authorizationStatusReturnValue = .authorized
        let service = AntintwrkSocialPush(client: client, defaults: defaults, shared: defaults, permissionCenter: center, registerDevice: { })
        service.activate(actor: actor, language: "en")
        func settle(_ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(ready(), "Push service did not settle")
        }
        do {
            try await settle { service.available && !service.busy }
            service.received(token: Data(repeating: 0, count: 32))
            await service.setDeviceEnabled(true)
            try await settle { AntintwrkSocialPushBinding.load(from: defaults) != nil || service.failed }
            XCTAssertFalse(service.failed)
            let binding = try XCTUnwrap(AntintwrkSocialPushBinding.load(from: defaults))
            XCTAssertEqual(binding.actor, actor)
            XCTAssertTrue(binding.matches(["kind": AntintwrkSocialPushBinding.kind, "binding": binding.binding]))
            service.received(token: Data(repeating: 1, count: 32))
            XCTAssertNil(AntintwrkSocialPushBinding.load(from: defaults), "Rotation must clear the old delivery scope immediately")
            try await settle { AntintwrkSocialPushBinding.load(from: defaults) != nil || service.failed }
            let rotated = try XCTUnwrap(AntintwrkSocialPushBinding.load(from: defaults))
            XCTAssertNotEqual(rotated.binding, binding.binding)
            XCTAssertFalse(rotated.matches(["kind": AntintwrkSocialPushBinding.kind, "binding": binding.binding]))
            await service.refresh(force: true)
            XCTAssertEqual(AntintwrkSocialPushBinding.load(from: defaults), rotated)
            await service.setCategory("votes", enabled: !(original["votes"] ?? false))
            XCTAssertEqual(service.preferences["votes"], !(original["votes"] ?? false))
            await service.setDeviceEnabled(false)
            XCTAssertNil(AntintwrkSocialPushBinding.load(from: defaults))
            XCTAssertFalse(service.deviceEnabled)
            // A device toggle must not turn off other devices through the shared preference.
            let after = try await JSONSerialization.jsonObject(with: client.pushRequest("push-settings", actor: actor)) as? [String: Any]
            XCTAssertEqual((after?["preferences"] as? [String: Bool])?["enabled"], true)
            let previousLanguage = UserDefaults.standard.object(forKey: "antintwrk.language")
            defer { UserDefaults.standard.set(previousLanguage, forKey: "antintwrk.language") }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            for item in ["en", "ru", "uk", "de", "es", "fr", "it", "ar", "zh", "ru-large", "ar-large"] {
                let language = try XCTUnwrap(item.split(separator: "-").first.map(String.init))
                UserDefaults.standard.set(language, forKey: "antintwrk.language")
                let window = UIWindow(windowScene: scene)
                let screen = ElementNavigationStack { AntintwrkSocialPushSettingsScreen(service: service) }
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(item.hasSuffix("-large") ? .accessibility3 : .large)
                let controller = UIHostingController(rootView: screen)
                window.rootViewController = controller
                window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(service.failed, "Settings reopen unexpectedly failed")
                controller.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: URL.libraryDirectory.appending(path: "antintwrk-social-push-" + item + ".png"))
                window.isHidden = true; window.rootViewController = nil
            }
            await service.deactivate()
            XCTAssertNil(AntintwrkSocialPushBinding.load(from: defaults))
            for token in [String(repeating: "00", count: 32), String(repeating: "01", count: 32)] {
                _ = try await client.pushRequest("push-unsubscribe", fields: ["environment": "sandbox", "apns_token": token], actor: actor)
            }
            _ = try await client.pushRequest("push-preferences", fields: original.mapValues { $0 ? "1" : "0" }, actor: actor)
            await client.logout(admission: admission, origin: .russian)
            do {
                _ = try await client.pushRequest("push-settings", actor: actor)
                XCTFail("Logged-out actor retained push access")
            } catch { }
        } catch {
            await service.deactivate()
            for token in [String(repeating: "00", count: 32), String(repeating: "01", count: 32)] {
                _ = try? await client.pushRequest("push-unsubscribe", fields: ["environment": "sandbox", "apns_token": token], actor: actor)
            }
            _ = try? await client.pushRequest("push-preferences", fields: original.mapValues { $0 ? "1" : "0" }, actor: actor)
            await client.logout(admission: admission, origin: .russian)
            throw error
        }
    }
}
