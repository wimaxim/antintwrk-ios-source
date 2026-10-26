// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkSocialPushSettingsScreen: View {
    @Bindable var service: AntintwrkSocialPush
    var body: some View {
        Form {
            Section {
                Toggle(AntintwrkStrings.value("screen_ant_push_device"), isOn: Binding(get: { service.deviceEnabled && service.preferences["enabled"] == true }, set: { value in
                    Task { await service.setDeviceEnabled(value) }
                }))
                .disabled(service.busy || !service.available || service.permissionDenied)
                if service.busy || (service.registering && !service.failed) {
                    ProgressView(AntintwrkStrings.value("screen_ant_push_loading"))
                }
                if service.permissionDenied {
                    Button(L10n.actionOpenSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                if service.failed || !service.available, !service.busy {
                    Text(AntintwrkStrings.value("screen_ant_push_failed")).foregroundStyle(.secondary)
                    Button(L10n.actionRetry) { Task { await service.refresh(force: true) } }
                }
            }
            Section {
                ForEach(AntintwrkSocialPush.categories, id: \.self) { category in
                    Toggle(AntintwrkStrings.value("screen_ant_push_" + category), isOn: Binding(get: { service.preferences[category] ?? false }, set: { value in
                        Task { await service.setCategory(category, enabled: value) }
                    }))
                    .disabled(service.busy || !service.available)
                }
            } footer: { Text(AntintwrkStrings.value("screen_ant_push_categories")) }
        }
        .compoundList()
        .navigationTitle(AntintwrkStrings.value("screen_ant_push_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.requestPermission(); await service.refresh() }
    }
}
