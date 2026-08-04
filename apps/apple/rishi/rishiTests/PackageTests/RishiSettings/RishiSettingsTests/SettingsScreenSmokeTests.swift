@testable import rishi
import Testing
import Foundation
import SwiftUI







@MainActor
@Suite("Settings screen + sections construction smoke")
struct SettingsScreenSmokeTests {

    @Test("Mac account deletion presents confirmation and signs out only after confirmation")
    func macAccountDeletionConfirmation() async {
        let account = MacAccountMenuModel()
        var deleted = false
        account.onDeleteConfirmed = { deleted = true }

        account.requestDelete()
        #expect(account.deleteConfirmationPresented)
        #expect(deleted == false)

        await account.confirmDelete()
        #expect(deleted)
        #expect(account.deleteConfirmationPresented == false)
    }

    @Test("BillingSection constructs (entitlement granted)")
    func billingSectionConstructsGranted() {
        // Phase 13: BillingSection no longer takes onManage; the inner
        // ManageSubscriptionRow reads ManageSubscriptionPresenter from
        // the SwiftUI environment.
        let s = BillingSection(entitlement: .init(isGranted: true), onSubscribe: {})
        _ = s
    }

    @Test("BillingSection constructs (entitlement NOT granted — failure-mode)")
    func billingSectionConstructsNotGranted() {
        let s = BillingSection(entitlement: .init(isGranted: false), onSubscribe: {})
        _ = s
    }

    @Test("BillingSection uses Manage for paid server snapshots")
    func billingSectionUsesManageForPaidSnapshots() {
        let period = EntitlementSnapshot.PaidPeriod(
            periodEndMs: 1_735_689_600_000,
            remainingNarrationSeconds: 60,
            remainingVoiceChatSeconds: 60
        )

        #expect(
            BillingSection(entitlementSnapshot: .readerActive(period), onSubscribe: {})
                .subscriptionAction == .manage
        )
        #expect(
            BillingSection(entitlementSnapshot: .voiceActive(period), onSubscribe: {})
                .subscriptionAction == .manage
        )
    }

    @Test("BillingSection uses Manage when StoreKit is active before server refresh")
    func billingSectionUsesManageForStoreKitSnapshotLag() {
        #expect(
            BillingSection(
                entitlementSnapshot: nil,
                onSubscribe: {},
                storeKitIsSubscribed: true,
               
            ).subscriptionAction == .manage
        )
    }

    @Test("BillingSection uses Subscribe for non-paid resolved snapshots")
    func billingSectionUsesSubscribeForNonPaidSnapshots() {
        let snapshots: [EntitlementSnapshot] = [
            .trialActive(remainingCredits: 1),
            .trialExhausted,
            .subscriptionExpired,
        ]

        for snapshot in snapshots {
            #expect(
                BillingSection(entitlementSnapshot: snapshot, onSubscribe: {})
                    .subscriptionAction == .subscribe
            )
        }
        #expect(
            BillingSection(entitlementSnapshot: nil, onSubscribe: {})
                .subscriptionAction == .subscribe
        )
    }

    @Test("BillingSection keeps subscription action neutral while loading")
    func billingSectionKeepsActionNeutralWhileLoading() {
        let period = EntitlementSnapshot.PaidPeriod(
            periodEndMs: 1_735_689_600_000,
            remainingNarrationSeconds: 60,
            remainingVoiceChatSeconds: 60
        )

        #expect(
            BillingSection(
                entitlementSnapshot: .readerActive(period),
                allowanceLoading: true,
                onSubscribe: {}
            ).subscriptionAction == .neutral
        )
        #expect(
            BillingSection(
                entitlementSnapshot: nil,
                allowanceLoading: true,
                onSubscribe: {}
            ).subscriptionAction == .neutral
        )
    }

    @Test("BillingSection accepts the Subscribe closure")
    func billingSectionAcceptsSubscribeClosure() {
        let section = BillingSection(onSubscribe: {})
        _ = section
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
        var language: VoiceLanguageOption = .english
        let s = ReaderDefaultsSection(
            defaultTheme: .init(get: { theme }, set: { theme = $0 }),
            defaultFontFamily: .init(get: { font }, set: { font = $0 })
        )
        _ = s.body
        let voice = VoiceLanguageSection(
            selection: .init(get: { language }, set: { language = $0 })
        )
        _ = voice.body
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
            name: "U",
      
        )
        var theme: ReaderTheme = .light
        var font: ReaderFontFamily = .system
        var language: VoiceLanguageOption = .english
        var pdfViewMode: PDFViewModeSetting = .automatic
        let screen = SettingsScreen(
            user: user,
            readerTheme: .init(get: { theme }, set: { theme = $0 }),
            readerFontFamily: .init(get: { font }, set: { font = $0 }),
            voiceLanguage: .init(get: { language }, set: { language = $0 }),
            pdfViewMode: .init(get: { pdfViewMode }, set: { pdfViewMode = $0 }),
            audioUserId: user.id,
            audioInitial: .default,
            audioStore: InMemoryTTSSettingsStore(),
            onAudioChange: { _ in },
            syncStatus: SyncStatus(),
            onSyncNow: {},
            telemetryStore: InMemoryTelemetryStore(),
            footerDetectionStore: InMemoryFooterDetectionStore(initial: true),
            billingEntitlement: .init(isGranted: true),
            onSubscribe: {},
            onSignOut: {},
            onEditUsername: {},
            onDelete: {},
            onDeleted: {},
            onDismiss: {}
        )
        _ = screen.body
    }

    @Test("Allow grants current-user consent before requesting a sync")
    func consentGrantPrecedesSyncCallback() async {
        let userID = UUID().uuidString
        let store = InMemoryDataUseConsentStore()
        let events = ConsentSyncEventRecorder()

        await SettingsScreen.grantDataUseConsentAndSync(
            userID: userID,
            consentStore: store,
            onSyncNow: {
                let isCurrent = await store.isCurrent(for: userID)
                await events.record(isCurrent ? "sync-after-grant" : "sync-before-grant")
            }
        )

        #expect(await store.isCurrent(for: userID))
        #expect(await events.events == ["sync-after-grant"])
    }
}

private actor ConsentSyncEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}
