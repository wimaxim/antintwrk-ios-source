// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Testing
import WebKit

@MainActor
struct AntintwrkWebImportTests {
    @Test func incomingShareImportsReviewedTextAndPhotoWithoutPublishing() async throws {
        let view = try await fixture()
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        let bytes = Data([71, 73, 70, 56, 57, 97])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = try AntintwrkIncomingShare(.mediaFiles(roomID: nil, mediaFiles: [.init(url: file, suggestedName: "fixture.gif")]))
        let script = try #require(request.script)
        let result = try await view.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, contentWorld: .page)
        #expect(result as? String == "ok")
        let count = try await view.evaluateJavaScript("document.querySelector('[data-photo-input]').files.length")
        #expect(count as? Int == 1)
        let published = try await view.evaluateJavaScript("window.published || false")
        #expect(published as? Bool == false)
    }
    
    @Test func incomingShareNeverOverwritesAnExistingDraft() async throws {
        let view = try await fixture(text: "existing draft")
        let request = try AntintwrkIncomingShare(.text(roomID: nil, text: "incoming fixture"))
        let script = try #require(request.script)
        let result = try await view.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, contentWorld: .page)
        #expect(result as? String == "draft")
        let content = try await view.evaluateJavaScript("document.querySelector('[data-rich-surface]').textContent")
        #expect(content as? String == "existing draft")
    }
    
    @Test func profilePartnerIsHiddenDynamicallyWithoutHidingPersonalLinks() async throws {
        let view = try await profileFixture(host: "antintwrk.com")
        let initial = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('[data-hero-profile] .ant-profile-ecosystem')).display")
        #expect(initial as? String == "none")
        let personal = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('personal')).display")
        #expect(personal as? String != "none")
        let outside = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('outside')).display")
        #expect(outside as? String != "none")
        let dynamic = try await view.callAsyncJavaScript("""
        const item = document.createElement('div'); item.className = 'ant-profile-ecosystem';
        document.querySelector('[data-hero-profile]').appendChild(item);
        await new Promise(resolve => setTimeout(resolve, 0));
        return getComputedStyle(item).display;
        """, arguments: [:], in: nil, contentWorld: .page)
        #expect(dynamic as? String == "none")
    }
    
    @Test func profilePartnerFilterDoesNotRunOnForeignOrigins() async throws {
        let view = try await profileFixture(host: "foreign.test")
        let display = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('[data-hero-profile] .ant-profile-ecosystem')).display")
        #expect(display as? String != "none")
    }
    
    private func profileFixture(host: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let resource = try #require(Bundle.main.url(forResource: "antintwrk-profile-partner", withExtension: "js"))
        try configuration.userContentController.addUserScript(WKUserScript(source: String(contentsOf: resource, encoding: .utf8), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        view.loadHTMLString("<html><body><div data-hero-profile><div class='ant-profile-ecosystem'>PARTNER PROJECT</div><a id='personal' class='hw-profile-promotion'>Personal link</a></div><div id='outside' class='ant-profile-ecosystem'>Other content</div></body></html>", baseURL: URL(string: "https://\(host)/en/profile"))
        for _ in 0..<200 {
            if let ready = try? await view.evaluateJavaScript("document.readyState==='complete' && !!document.getElementById('personal')"), ready as? Bool == true {
                return view
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
    
    private func fixture(text: String = "") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let resource = try #require(Bundle.main.url(forResource: "antintwrk-incoming-share", withExtension: "js"))
        let source = try String(contentsOf: resource, encoding: .utf8)
        view.loadHTMLString("""
        <html><body class="antintwrk-app-view"><form data-hero-composer onsubmit="window.published=true;return false">
        <div data-rich-surface contenteditable="true">\(text)</div><input type="file" data-photo-input multiple><input type="file" data-publication-video-input>
        </form><script>\(source)</script></body></html>
        """, baseURL: URL(string: "https://antintwrk.com/en/hero-compose"))
        for _ in 0..<200 {
            if let state = try? await view.evaluateJavaScript("document.readyState==='complete' && typeof window.antintwrkImportNativeShare==='function'"), state as? Bool == true {
                return view
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
}
