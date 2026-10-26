// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Network
import SwiftUI
import WebKit

@MainActor
final class AntintwrkRegionalTransport {
    // Staged until server fencing and RTC allocation acceptance is complete.
    static let enabled = false
    static let shared = AntintwrkRegionalTransport()
    static let canonicalHosts = ["antimsg.com", "matrix.antimsg.com", "auth.antimsg.com", "push.antimsg.com", "rtc.antimsg.com"]
    enum Region: String { case russian, global
        var endpoint: String {
            self == .russian ? "connect.ru.antimsg.com" : "connect.la.antimsg.com"
        }
        
        var other: Self {
            self == .russian ? .global : .russian
        }
    }
    
    enum Failure: Error { case unavailable, invalidConnect, authentication }
    enum Service: String { case social, messenger
        var healthPath: String {
            self == .social ? "/app/social-health" : "/app/health"
        }
    }
    
    private struct ServiceKey: Hashable {
        let region: Region
        let service: Service
    }
    
    private struct Health {
        let healthy: Bool
        let expires: Date
    }
    
    private let username = "antintwrk"
    private let password = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var pipes: [UUID: AntintwrkRegionalPipe] = [:]
    private var starting: Task<Void, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var unavailableUntil: [ServiceKey: Date] = [:]
    private var health: [ServiceKey: Health] = [:]
    private var healthTasks: [ServiceKey: Task<Bool, Never>] = [:]
    var preferredRegion: Region = .russian
    private(set) var successfulConnections: [Region: Int] = [:]
    // Injection is restricted to local tests; the production singleton uses canonical endpoints.
    private let endpoint: (Region, String) -> NWEndpoint
    private let healthProbe: ((Region, Service) async -> Bool)?
    
    init(endpoint: @escaping (Region, String) -> NWEndpoint = { region, _ in .hostPort(host: .init(region.endpoint), port: 443) },
         healthProbe: ((Region, Service) async -> Bool)? = nil) {
        self.endpoint = endpoint
        self.healthProbe = healthProbe
    }
    
    var proxyURL: String? {
        port.map { "http://\(username):\(password)@127.0.0.1:\($0.rawValue)" }
    }
    
    var authorization: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
    
    func start() async throws {
        if port != nil {
            return
        }
        if let starting {
            return try await starting.value
        }
        let task = Task { try await listen() }
        starting = task
        defer { starting = nil }
        try await task.value
    }
    
    private func listen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                listener.cancel()
            }
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, let continuation = startContinuation else { return }
                    switch state {
                    case .ready:
                        startContinuation = nil; port = listener.port
                        continuation.resume()
                    case .failed, .cancelled:
                        startContinuation = nil; continuation.resume(throwing: Failure.unavailable)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
    
    func stop() {
        listener?.cancel(); listener = nil; port = nil
        for pipe in Array(pipes.values) {
            pipe.close()
        }
        pipes.removeAll()
    }
    
    func configure(_ settings: URLSessionConfiguration) {
        if let proxy = proxyConfiguration {
            settings.proxyConfigurations = [proxy]
        }
    }
    
    func configure(_ store: WKWebsiteDataStore) {
        if let proxy = proxyConfiguration {
            store.proxyConfigurations = [proxy]
        }
    }
    
    private var proxyConfiguration: ProxyConfiguration? {
        guard let port else { return nil }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        proxy.matchDomains = Self.canonicalHosts
        proxy.allowFailover = false
        proxy.applyCredential(username: username, password: password)
        return proxy
    }
    
    func routes(for host: String, now: Date = Date()) -> [(Region?, NWEndpoint)] {
        if host == "antintwrk.com" {
            return [(nil, .hostPort(host: "antintwrk.com", port: 443))]
        }
        let order = [preferredRegion, preferredRegion.other]
        let service = Self.service(for: host)
        let available = order.filter { unavailableUntil[ServiceKey(region: $0, service: service)].map { $0 <= now } ?? true }
        return available.map { ($0, endpoint($0, host)) }
    }
    
    static func service(for host: String) -> Service {
        host == "antimsg.com" ? .social : .messenger
    }
    
    func failed(_ region: Region, service: Service = .messenger) {
        let key = ServiceKey(region: region, service: service)
        let expires = Date().addingTimeInterval(30)
        unavailableUntil[key] = expires
        health[key] = Health(healthy: false, expires: expires)
    }
    
    func isHealthy(_ region: Region, service: Service) async -> Bool {
        let key = ServiceKey(region: region, service: service)
        if let until = unavailableUntil[key], until > Date() {
            return false
        }
        if let cached = health[key], cached.expires > Date() {
            return cached.healthy
        }
        if let pending = healthTasks[key] {
            return await pending.value
        }
        let task = Task {
            if let healthProbe {
                return await healthProbe(region, service)
            }
            return await Self.probe(region, service: service)
        }
        healthTasks[key] = task
        let result = await task.value
        healthTasks[key] = nil
        if result {
            health[key] = Health(healthy: true, expires: Date().addingTimeInterval(10))
        } else {
            failed(region, service: service)
        }
        return result
    }
    
    private static func probe(_ region: Region, service: Service) async -> Bool {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false; settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 2.5; settings.timeoutIntervalForResource = 3
        let session = URLSession(configuration: settings, delegate: AntintwrkRegionalHealthDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://" + region.endpoint + service.healthPath) else { return false }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 4096 else { return false }
            var count = 0
            for try await _ in bytes {
                count += 1; if count > 4096 {
                    return false
                }
            }
            return true
        } catch { return false }
    }
    
    func connected(_ region: Region) {
        successfulConnections[region, default: 0] += 1
    }
    
    static func connectHost(_ data: Data, authorization: String) throws -> String {
        guard data.count <= 8192, let text = String(data: data, encoding: .ascii),
              let end = text.range(of: "\r\n\r\n"), end.upperBound == text.endIndex else { throw Failure.invalidConnect }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw Failure.invalidConnect }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CONNECT", ["HTTP/1.1", "HTTP/1.0"].contains(parts[2]) else { throw Failure.invalidConnect }
        let authority = String(parts[1])
        guard authority.hasSuffix(":443") else { throw Failure.invalidConnect }
        let host = String(authority.dropLast(4))
        guard (canonicalHosts + ["antintwrk.com"]).contains(host) else { throw Failure.invalidConnect }
        let credentials = lines.dropFirst().filter { $0.lowercased().hasPrefix("proxy-authorization:") }
        guard credentials.count == 1,
              credentials[0].dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) == authorization else { throw Failure.authentication }
        return host
    }
    
    private func accept(_ connection: NWConnection) {
        guard pipes.count < 64 else { connection.cancel(); return }
        let id = UUID()
        let pipe = AntintwrkRegionalPipe(connection: connection, transport: self) { [weak self] in self?.pipes[id] = nil }
        pipes[id] = pipe; pipe.start()
    }
}

@MainActor
private final class AntintwrkRegionalPipe {
    private let incoming: NWConnection
    private weak var transport: AntintwrkRegionalTransport?
    private let ended: () -> Void
    private var outgoing: NWConnection?
    private var timeout: Task<Void, Never>?
    private var header = Data()
    private var opened = false
    private var closed = false
    private var attempt = UUID()
    private var service: AntintwrkRegionalTransport.Service = .messenger
    
    init(connection: NWConnection, transport: AntintwrkRegionalTransport, ended: @escaping () -> Void) {
        incoming = connection; self.transport = transport; self.ended = ended
    }
    
    func start() {
        incoming.start(queue: .main)
        deadline { [weak self] in self?.close() }
        readHeader()
    }
    
    private func readHeader() {
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 8192 - header.count) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !closed else { return }
                if let data {
                    header.append(data)
                }
                if header.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let transport else { close(); return }
                    let host: String
                    do { host = try AntintwrkRegionalTransport.connectHost(header, authorization: transport.authorization) }
                    catch AntintwrkRegionalTransport.Failure.authentication { reject(authentication: true); return }
                    catch { reject(); return }
                    timeout?.cancel()
                    service = AntintwrkRegionalTransport.service(for: host)
                    connect(transport.routes(for: host))
                } else if complete || error != nil || header.count >= 8192 {
                    reject()
                } else {
                    readHeader()
                }
            }
        }
    }
    
    private func connect(_ routes: [(AntintwrkRegionalTransport.Region?, NWEndpoint)], healthChecked: Bool = false) {
        guard !closed, !opened, let next = routes.first else { reject(); return }
        if let region = next.0, !healthChecked {
            Task { [weak self] in
                guard let self, let transport else { return }
                let healthy = await transport.isHealthy(region, service: service)
                guard !closed, !opened else { return }
                connect(healthy ? routes : Array(routes.dropFirst()), healthChecked: healthy)
            }
            return
        }
        let attemptID = UUID(); attempt = attemptID
        let connection = NWConnection(to: next.1, using: .tcp)
        outgoing = connection
        let remaining = Array(routes.dropFirst())
        let failed: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !closed, !opened, attempt == attemptID else { return }
            attempt = UUID(); connection.cancel()
            if let region = next.0 {
                transport?.failed(region, service: service)
            }
            connect(remaining)
        }
        deadline(failed)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !closed, attempt == attemptID else { return }
                switch state {
                case .ready:
                    guard !opened else { return }
                    opened = true; timeout?.cancel()
                    if let region = next.0 {
                        transport?.connected(region)
                    }
                    incoming.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, !closed else { return }
                            guard error == nil else { close(); return }
                            pump(incoming, to: connection); pump(connection, to: incoming)
                        }
                    })
                case .failed, .cancelled:
                    if opened {
                        close()
                    } else {
                        failed()
                    }
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    
    private func pump(_ source: NWConnection, to destination: NWConnection) {
        guard !closed else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !closed else { return }
                guard error == nil else { close(); return }
                guard let data, !data.isEmpty else {
                    if complete {
                        close()
                    } else {
                        pump(source, to: destination)
                    }
                    return
                }
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, !closed else { return }
                        if error != nil || complete {
                            close()
                        } else {
                            pump(source, to: destination)
                        }
                    }
                })
            }
        }
    }
    
    private func deadline(_ action: @escaping @MainActor () -> Void) {
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            action()
        }
    }
    
    private func reject(authentication: Bool = false) {
        guard !closed else { return }
        let response = authentication ? "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"ANTINTWRK\"\r\n" : "HTTP/1.1 403 Forbidden\r\n"
        incoming.send(content: Data((response + "Connection: close\r\nContent-Length: 0\r\n\r\n").utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        })
    }
    
    func close() {
        guard !closed else { return }
        closed = true; timeout?.cancel(); incoming.cancel(); outgoing?.cancel(); ended()
    }
}

private final class AntintwrkRegionalHealthDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
