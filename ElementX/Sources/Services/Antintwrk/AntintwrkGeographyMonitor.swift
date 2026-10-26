// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Network
import SwiftUI

@MainActor
final class AntintwrkGeographyMonitor {
    private let monitor = NWPathMonitor()
    private var debounce: Task<Void, Never>?
    private var periodic: Task<Void, Never>?
    private var lastCheck: Date?
    private var signature: String?
    private var active = false
    private var checking = false
    private var queued = false
    private let refresh: () async -> Void
    
    init(refresh: @escaping () async -> Void) {
        self.refresh = refresh
        monitor.pathUpdateHandler = { [weak self] path in
            let value = "\(path.status)-" + path.availableInterfaces.map { "\($0.name)-\($0.type)" }.sorted().joined(separator: "|") + Self.localAddresses()
            Task { @MainActor [weak self] in self?.changed(value) }
        }
        monitor.start(queue: DispatchQueue(label: "com.antintwrk.geography"))
    }
    
    func setActive(_ value: Bool) {
        active = value
        periodic?.cancel(); periodic = nil
        if value {
            periodic = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if lastCheck.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
                        await check()
                    }
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
    
    private func changed(_ value: String) {
        let previous = signature
        signature = value
        guard previous != nil, previous != value else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, let self, active else { return }
            await check()
        }
    }
    
    private func check() async {
        guard active else { return }
        if checking {
            queued = true; return
        }
        checking = true
        await refresh()
        lastCheck = Date(); checking = false
        if queued {
            queued = false; await check()
        }
    }
    
    private nonisolated static func localAddresses() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(head) }
        var values: [String] = []
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.append(name + ":" + String(cString: buffer))
            }
        }
        return values.sorted().joined(separator: "|")
    }
}
