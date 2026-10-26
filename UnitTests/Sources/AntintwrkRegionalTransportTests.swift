// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import MatrixRustSDK
import Network
import Testing
import WebKit

@MainActor
struct AntintwrkRegionalTransportTests {
    @Test func connectAcceptsOnlyCanonicalTLSHostsAndAuthenticatedProxy() throws {
        for host in AntintwrkRegionalTransport.canonicalHosts + ["antintwrk.com"] {
            #expect(try AntintwrkRegionalTransport.connectHost(header(host), authorization: "Basic fixture") == host)
        }
        for host in ["evil.test", "matrix.antimsg.com.evil.test", "127.0.0.1", "matrix.antimsg.com:443@evil.test", "Matrix.antimsg.com"] {
            #expect(throws: (any Error).self) { try AntintwrkRegionalTransport.connectHost(header(host), authorization: "Basic fixture") }
        }
        #expect(throws: (any Error).self) { try AntintwrkRegionalTransport.connectHost(header("matrix.antimsg.com"), authorization: "Basic wrong") }
    }
    
    @Test func connectRejectsPlainHTTPWrongPortOversizedAndPipelinedRequests() throws {
        let requests = ["GET https://matrix.antimsg.com/ HTTP/1.1\r\n\r\n", "CONNECT matrix.antimsg.com:80 HTTP/1.1\r\n\r\n", String(decoding: header("matrix.antimsg.com"), as: UTF8.self) + "extra", String(repeating: "x", count: 8193)]
        for request in requests {
            #expect(throws: (any Error).self) { try AntintwrkRegionalTransport.connectHost(Data(request.utf8), authorization: "Basic fixture") }
        }
    }
    
    @Test func routingKeepsPublicSiteDirectAndRespectsCooldown() {
        let relay = AntintwrkRegionalTransport()
        #expect(relay.routes(for: "matrix.antimsg.com").map(\.0) == [.russian, .global])
        relay.preferredRegion = .global
        #expect(relay.routes(for: "matrix.antimsg.com").first?.0 == .global)
        relay.failed(.global)
        #expect(relay.routes(for: "matrix.antimsg.com").map(\.0) == [.russian])
        #expect(relay.routes(for: "matrix.antimsg.com", now: Date().addingTimeInterval(31)).first?.0 == .global)
        relay.failed(.russian)
        #expect(relay.routes(for: "matrix.antimsg.com").isEmpty)
        #expect(relay.routes(for: "antintwrk.com").count == 1)
        #expect(relay.routes(for: "antintwrk.com").first?.0 == nil)
        #expect(relay.routes(for: "antintwrk.com").first?.1 == .hostPort(host: "antintwrk.com", port: 443))
    }
    
    @Test(.timeLimit(.minutes(1))) func localRelayRequiresAuthenticationAndForwardsOpaqueBytesAfterConnectFallback() async throws {
        let echo = try await RegionalEchoFixture.start()
        defer { echo.stop() }
        let relay = AntintwrkRegionalTransport(endpoint: { region, _ in
            .hostPort(host: "127.0.0.1", port: region == .russian ? 1 : echo.port)
        }, healthProbe: { _, _ in true })
        try await relay.start()
        defer { relay.stop() }
        let proxyURL = try #require(relay.proxyURL)
        let url = try #require(URL(string: proxyURL))
        let rawPort = try #require(url.port)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(rawPort)))
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.start(queue: .main)
        defer { client.cancel() }
        try await send(header("matrix.antimsg.com", authorization: relay.authorization), to: client)
        let response = try await receive(client)
        #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        #expect(relay.routes(for: "matrix.antimsg.com").map(\.0) == [.global])
        let opaque = Data([0, 255, 1, 7, 13, 10, 22, 3, 3])
        try await send(opaque, to: client)
        #expect(try await receive(client) == opaque)
        echo.stop()
        #expect(try await receive(client).isEmpty)
        #expect(relay.successfulConnections == [.global: 1])
        let rejected = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        rejected.start(queue: .main)
        defer { rejected.cancel() }
        try await send(Data("CONNECT matrix.antimsg.com:443 HTTP/1.1\r\n\r\n".utf8), to: rejected)
        #expect(try await String(decoding: receive(rejected), as: UTF8.self).hasPrefix("HTTP/1.1 407"))
        let settings = URLSessionConfiguration.ephemeral
        relay.configure(settings)
        #expect(settings.proxyConfigurations.count == 1)
        #expect(settings.proxyConfigurations.first?.allowFailover == false)
        #expect(settings.proxyConfigurations.first?.matchDomains == AntintwrkRegionalTransport.canonicalHosts)
        let store = WKWebsiteDataStore.nonPersistent()
        relay.configure(store)
        #expect(store.proxyConfigurations.count == 1)
    }
    
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTINTWRK_HA_READ_ONLY_SMOKE"] == "1"), .timeLimit(.minutes(1)), arguments: ["russian", "global"])
    func canonicalHTTPSUsesRegionalRelayWithoutTLSOverride(_ region: String) async throws {
        let relay = AntintwrkRegionalTransport()
        relay.preferredRegion = try #require(AntintwrkRegionalTransport.Region(rawValue: region))
        try await relay.start()
        defer { relay.stop() }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15
        relay.configure(settings)
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://matrix.antimsg.com/_matrix/client/versions"))
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["versions"] is [String])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        relay.configure(config.websiteDataStore)
        let view = WKWebView(frame: .zero, configuration: config)
        let navigation = RegionalNavigationFixture()
        view.navigationDelegate = navigation
        try await navigation.load(url, in: view)
        let text = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        #expect(text.contains("versions"))
        let proxyURL = try #require(relay.proxyURL)
        let client = try await ClientBuilder().inMemoryStore().serverNameOrHomeserverUrl(serverNameOrUrl: "https://matrix.antimsg.com").proxy(url: proxyURL).build()
        #expect(client.homeserver() == "https://matrix.antimsg.com/")
        let details = await client.homeserverLoginDetails()
        #expect(details.supportsOauthLogin())
        let selected = try #require(AntintwrkRegionalTransport.Region(rawValue: region))
        #expect((relay.successfulConnections[selected] ?? 0) >= 3)
        #expect(relay.successfulConnections[selected.other] == nil)
    }
    
    @Test func healthAndFailureCacheKeepSocialIndependentFromMessenger() async {
        var probes: [AntintwrkRegionalTransport.Service: Int] = [:]
        let relay = AntintwrkRegionalTransport(healthProbe: { _, service in
            probes[service, default: 0] += 1
            return service == .social
        })
        #expect(await relay.isHealthy(.russian, service: .messenger) == false)
        #expect(await relay.isHealthy(.russian, service: .messenger) == false)
        #expect(await relay.isHealthy(.russian, service: .social))
        #expect(await relay.isHealthy(.russian, service: .social))
        #expect(probes == [.social: 1, .messenger: 1])
        #expect(relay.routes(for: "matrix.antimsg.com").map(\.0) == [.global])
        #expect(relay.routes(for: "antimsg.com").map(\.0) == [.russian, .global])
        relay.failed(.global, service: .social)
        #expect(relay.routes(for: "antimsg.com").map(\.0) == [.russian])
        #expect(relay.routes(for: "auth.antimsg.com").map(\.0) == [.global])
        #expect(AntintwrkRegionalTransport.Service.social.healthPath == "/app/social-health")
        #expect(AntintwrkRegionalTransport.Service.messenger.healthPath == "/app/health")
    }
    
    private func header(_ host: String, authorization: String = "Basic fixture") -> Data {
        Data("CONNECT \(host):443 HTTP/1.1\r\nProxy-Authorization: \(authorization)\r\n\r\n".utf8)
    }
    
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }
}

@MainActor
private final class RegionalEchoFixture {
    let listener: NWListener
    var port: NWEndpoint.Port {
        listener.port!
    }
    
    private var continuation: CheckedContinuation<Void, Error>?
    private var connections: [NWConnection] = []
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }
    
    static func start() async throws -> RegionalEchoFixture {
        let fixture = try RegionalEchoFixture()
        try await withCheckedThrowingContinuation { continuation in
            fixture.continuation = continuation
            fixture.listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard let continuation = fixture.continuation else { return }
                    if case .ready = state {
                        fixture.continuation = nil; continuation.resume()
                    }
                    if case .failed(let error) = state {
                        fixture.continuation = nil; continuation.resume(throwing: error)
                    }
                }
            }
            fixture.listener.newConnectionHandler = { connection in
                Task { @MainActor in
                    fixture.connections.append(connection)
                    connection.start(queue: .main)
                    fixture.echo(connection)
                }
            }
            fixture.listener.start(queue: .main)
        }
        return fixture
    }
    
    func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let data, error == nil, !complete else { return }
            connection.send(content: data, completion: .contentProcessed { error in
                guard error == nil else { return }
                Task { @MainActor [weak self] in self?.echo(connection) }
            })
        }
    }
    
    func stop() {
        listener.cancel(); connections.forEach { $0.cancel() }
    }
}

@MainActor
private final class RegionalNavigationFixture: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ url: URL, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.load(URLRequest(url: url, timeoutInterval: 15))
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
