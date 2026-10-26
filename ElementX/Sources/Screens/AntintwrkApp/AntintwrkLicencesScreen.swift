// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkLicencesScreen: View {
    let profile: () -> Void
    private var licence: String {
        Bundle.main.url(forResource: "AGPL", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? AntintwrkStrings.value("screen_ant_licences_failed")
    }
    
    private var acknowledgements: [[String: Any]] {
        Self.acknowledgementRows()
    }
    
    static func acknowledgementRows(bundle: Bundle = .main) -> [[String: Any]] {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "plist", subdirectory: "Settings.bundle"),
              let data = try? Data(contentsOf: url), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rows = plist["PreferenceSpecifiers"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            if let text = row["FooterText"] as? String, !text.isEmpty {
                return row
            }
            guard let file = row["File"] as? String, file.range(of: "^Packages/[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                  let child = bundle.url(forResource: String(file.dropFirst("Packages/".count)), withExtension: "plist", subdirectory: "Settings.bundle/Packages"),
                  let contents = try? Data(contentsOf: child),
                  let value = try? PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any],
                  let groups = value["PreferenceSpecifiers"] as? [[String: Any]] else { return nil }
            let text = groups.compactMap { $0["FooterText"] as? String }.joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            var result = row; result["FooterText"] = text
            return result
        }
    }
    
    var body: some View {
        List {
            Section {
                Text(AntintwrkStrings.value("screen_ant_licences_project")).font(.headline)
                Text(String(format: AntintwrkStrings.value("screen_ant_licences_operator"), "Super David Universe LLC"))
                Text(AntintwrkStrings.value("screen_ant_licences_author"))
                Button("Maxim Novichkov", action: profile).fixedSize(horizontal: false, vertical: true)
                Text(AntintwrkStrings.value("screen_ant_licences_backend_title")).font(.headline)
                Text(AntintwrkStrings.value("screen_ant_licences_backend"))
                Text(AntintwrkStrings.value("screen_ant_licences_backend_scope"))
                Text(AntintwrkStrings.value("screen_ant_licences_client_title")).font(.headline)
                Text(AntintwrkStrings.value("screen_ant_licences_client"))
                Text(AntintwrkStrings.value("screen_ant_licences_rights"))
                Text("Copyright 2026 Maxim Novichkov\nElement X — AGPL-3.0-only\nCopyright 2022–2025 New Vector Ltd.\nCopyright 2025 Element Creations Ltd.")
                Link(AntintwrkStrings.value("screen_ant_source"), destination: URL(string: "https://github.com/wimaxim/antintwrk-ios-source")!)
                DisclosureGroup("AGPL-3.0") { Text(licence).font(.footnote).textSelection(.enabled) }
            }
            ForEach(Array(acknowledgements.enumerated()), id: \.offset) { _, row in
                if let title = row["Title"] as? String, let text = row["FooterText"] as? String, !text.isEmpty {
                    DisclosureGroup(title) { Text(text).font(.footnote).textSelection(.enabled) }
                }
            }
        }
        .navigationTitle(AntintwrkStrings.value("screen_ant_licences"))
    }
}
