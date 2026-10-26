// Copyright 2026 Super David Universe LLC
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import Testing
import WebKit

@MainActor
final class AntintwrkCallToneTests: NSObject, WKNavigationDelegate {
    private var loaded: (() -> Void)?
    
    @Test
    func packagedTelephoneTonesDecodeInWebKit() async throws {
        let webView = WKWebView()
        webView.navigationDelegate = self
        await waitForConfirmation { confirm in
            loaded = { confirm() }
            webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        }
        for (name, duration) in [("ringback", 5.0), ("busy", 3.0)] {
            let root = try #require(Bundle.main.resourceURL)
            let data = try Data(contentsOf: root.appendingPathComponent("AntintwrkTelephoneCall/assets/antintwrk-\(name)-v1.wav"))
            let result = try await webView.callAsyncJavaScript("""
            const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
            const context = new AudioContext();
            try {
                const buffer = await context.decodeAudioData(bytes.buffer);
                return { duration: buffer.duration, channels: buffer.numberOfChannels };
            } finally { await context.close(); }
            """, arguments: ["base64": data.base64EncodedString()], in: nil, contentWorld: .page)
            let decoded = try #require(result as? [String: Any])
            #expect(decoded["duration"] as? Double == duration)
            #expect(decoded["channels"] as? Int == 1)
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?()
        loaded = nil
    }
}
