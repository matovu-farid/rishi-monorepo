//
//  SettingsSheet.swift
//  rishi
//
//  Phase 7 Plan 07-05 — SYNC-07 + SYNC-08 user-facing surface.
//
//  Presented from the Library toolbar gear icon. Embeds `SettingsSyncSection`
//  from RishiSync inside a Form so the layout matches Apple's stock Settings
//  affordance.
//

import SwiftUI
import RishiSync

struct SettingsSheet: View {

    let dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SettingsSyncSection(status: dependencies.syncStatus) { [syncEngine = dependencies.syncEngine] in
                    Task {
                        await syncEngine.syncNow()
                    }
                }
                // Future: account section, theme overrides, etc.
            }
            .navigationTitle("Settings")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
