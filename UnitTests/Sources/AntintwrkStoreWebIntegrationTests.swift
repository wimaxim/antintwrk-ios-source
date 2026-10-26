// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import SwiftUI
import WebKit
import XCTest

/// Explicit local QA only. Credentials are supplied in the QA simulator's private Library, never the source or test plan.
final nonisolated class AntintwrkStoreWebIntegrationTests: XCTestCase {
    @MainActor
    func testAuthenticatedStoreBridgeAndLogoutOnActualSocialPage() async throws {
        guard ProcessInfo.processInfo.environment["ANTINTWRK_LIVE_STORE_WEB_QA"] == "1" else {
            throw XCTSkip("Live ordinary-reviewer QA is opt-in")
        }
        let credentialURL = URL.libraryDirectory.appending(path: "antintwrk-reviewer-qa.json")
        let data = try Data(contentsOf: credentialURL)
        defer { try? FileManager.default.removeItem(at: credentialURL) }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let email = try XCTUnwrap(fields["email"])
        let password = try XCTUnwrap(fields["password"])
        let model = AntintwrkAppModel()
        let client = model.client
        let admission = try await client.login(email: email, password: password, language: "en")
        XCTAssertEqual(admission.stage, .authenticated)
        await model.accept(admission)
        XCTAssertTrue(model.page == .social)
        let surface = try XCTUnwrap(model.social)
        var requests = 0
        let handler = try XCTUnwrap(surface.onStoreRequest)
        surface.onStoreRequest = { message in
            requests += 1
            return try await handler(message)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.makeKeyAndVisible()
        let web = surface.active
        web.frame = controller.view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(web)
        defer { surface.invalidate(); window.isHidden = true; window.rootViewController = nil }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(35))
            var ready = false
            while ContinuousClock.now < deadline {
                if await (try? web.evaluateJavaScript("typeof window.antintwrkStoreRequest === 'function'")) as? Bool == true {
                    ready = true; break
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            XCTAssertTrue(ready, "Authenticated social module did not become ready")
            guard ready else { throw AntintwrkStoreKit.Failure.unavailable }
            // Sales remain disabled. Exercise real page → WK frame checks → native actor → authenticated API → page error.
            let script = "return await Promise.race([window.antintwrkStoreRequest({type:'store-catalog'}).then(()=>'unexpected-enabled').catch(e=>e.message),new Promise(r=>setTimeout(()=>r('bridge-timeout'),12000))])"
            let response = try await web.callAsyncJavaScript(script, in: nil, contentWorld: .page)
            XCTAssertEqual(response as? String, "STORE_UNAVAILABLE")
            XCTAssertEqual(requests, 1)
            let previous = requests
            _ = try await web.evaluateJavaScript("(()=>{let f=document.createElement('iframe');f.srcdoc='<script>window.webkit.messageHandlers.antintwrk.postMessage(JSON.stringify({type:\"store-catalog\",id:\"qa-subframe\"}))<\\/script>';document.body.append(f)})()")
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(requests, previous, "A subframe reached native checkout")
            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: nil) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? AntintwrkSocialClient.Failure.invalidResponse)
                    }
                }
            }
            try snapshot.pngData()?.write(to: URL.libraryDirectory.appending(path: "antintwrk-store-web-qa.png"), options: .atomic)
            try await verifyRefundDisclosure(surface: surface, controller: controller)
            surface.select(0)
            XCTAssertTrue(surface.active === web, "Returning from verification replaced the retained Feed")
            await model.logout()
            XCTAssertNil(model.social)
            do {
                _ = try await handler(["type": "store-catalog"])
                XCTFail("A stale surface retained store access after logout")
            } catch { }
            let final = try await client.session()
            XCTAssertEqual(final.stage, .login)
        } catch {
            await model.logout()
            throw error
        }
    }
    
    @MainActor
    private func verifyRefundDisclosure(surface: AntintwrkSocialSurface, controller: UIViewController) async throws {
        surface.open("verification")
        let verification = surface.active
        verification.frame = controller.view.bounds
        verification.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(verification)
        let verificationDeadline = ContinuousClock.now.advanced(by: .seconds(35))
        var verificationReady = false
        while ContinuousClock.now < verificationDeadline {
            if await (try? verification.evaluateJavaScript("document.querySelector('[data-store-status]')?.innerText.includes('Apple decides whether to approve the refund.') === true")) as? Bool == true {
                verificationReady = true; break
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertTrue(verificationReady, "The actual iOS page did not disclose Apple's refund decision")
        guard verificationReady else { throw AntintwrkStoreKit.Failure.unavailable }
        let checkoutReady = try await verification.evaluateJavaScript("JSON.parse(document.querySelector('[data-verification-config]').textContent).playReady") as? Bool
        let googlePayment = try await verification.evaluateJavaScript("document.body.innerText.includes('Google Play')") as? Bool
        XCTAssertEqual(checkoutReady, false)
        XCTAssertEqual(googlePayment, false)
        let verificationSnapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            verification.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? AntintwrkSocialClient.Failure.invalidResponse)
                }
            }
        }
        try verificationSnapshot.pngData()?.write(to: URL.libraryDirectory.appending(path: "antintwrk-verification-web-qa.png"), options: .atomic)
    }
}
