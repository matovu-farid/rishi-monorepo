import Testing
import Foundation
import SwiftUI
@testable import RishiSettings
import RishiCore
import RishiAudio
import RishiSync
import RishiReader
import RishiBilling

@MainActor
@Suite("Settings screen + sections construction smoke")
struct SettingsScreenSmokeTests {

    @Test("BillingSection constructs (entitlement granted)")
    func billingSectionConstructsGranted() {
        // Phase 13: BillingSection no longer takes onManage; the inner
        // ManageSubscriptionRow reads ManageSubscriptionPresenter from
        // the SwiftUI environment.
        let s = BillingSection(entitlement: .init(isGranted: true))
        _ = s
    }

    @Test("BillingSection constructs (entitlement NOT granted — failure-mode)")
    func billingSectionConstructsNotGranted() {
        let s = BillingSection(entitlement: .init(isGranted: false))
        _ = s
    }

    @Test("AboutSection renders version string from Bundle.main")
    func aboutSectionConstructs() {
        let s = AboutSection()
        _ = s.body
    }

    @Test("TelemetrySection constructs over InMemoryTelemetryStore")
    func telemetrySectionConstructs() {
        let s = TelemetrySection(store: InMemoryTelemetryStore())
        _ = s.body
    }

    @Test("ReaderDefaultsSection constructs against bindings")
    func readerDefaultsConstructs() {
        var theme: ReaderTheme = .light
        var font: ReaderFontFamily = .system
        let s = ReaderDefaultsSection(
            defaultTheme: .init(get: { theme }, set: { theme = $0 }),
            defaultFontFamily: .init(get: { font }, set: { font = $0 })
        )
        _ = s.body
    }

    @Test("SyncSettingsSection constructs with a real SyncStatus")
    func syncSectionConstructs() {
        let s = SyncSettingsSection(status: SyncStatus(), onSyncNow: {})
        _ = s.body
    }

    @Test("AudioSection constructs over InMemoryTTSSettingsStore")
    func audioSectionConstructs() {
        let s = AudioSection(
            userId: UUID(),
            initialSettings: .default,
            store: InMemoryTTSSettingsStore(),
            onChange: { _ in }
        )
        _ = s.body
    }

    @Test("SettingsScreen composes all sections without throwing")
    func screenComposes() {
        let user = User(
            id: UUID(),
            email: "u@example.com",
            displayName: "U",
            avatarURL: nil,
            hasPro: false,
            createdAt: Date()
        )
        var theme: ReaderTheme = .light
        var font: ReaderFontFamily = .system
        let screen = SettingsScreen(
            user: user,
            readerTheme: .init(get: { theme }, set: { theme = $0 }),
            readerFontFamily: .init(get: { font }, set: { font = $0 }),
            audioUserId: user.id,
            audioInitial: .default,
            audioStore: InMemoryTTSSettingsStore(),
            onAudioChange: { _ in },
            syncStatus: SyncStatus(),
            onSyncNow: {},
            telemetryStore: InMemoryTelemetryStore(),
            billingEntitlement: .init(isGranted: true),
            onSignOut: {},
            onDelete: {},
            onDeleted: {},
            onManageSubscription: {},
            onDismiss: {}
        )
        _ = screen.body
    }
}
