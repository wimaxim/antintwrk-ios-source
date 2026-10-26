// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

enum AntintwrkStrings {
    static func value(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: "antintwrk.language")
        let path = language.flatMap { Bundle.main.path(forResource: $0 == "zh" ? "zh-Hans" : $0, ofType: "lproj") }
        let bundle = path.flatMap(Bundle.init(path:)) ?? .main
        let shared = NSLocalizedString(key, tableName: "Antintwrk", bundle: bundle, value: key, comment: "")
        return shared == key ? NSLocalizedString(key, tableName: "AntintwrkIOS", bundle: bundle, value: key, comment: "") : shared
    }
}
