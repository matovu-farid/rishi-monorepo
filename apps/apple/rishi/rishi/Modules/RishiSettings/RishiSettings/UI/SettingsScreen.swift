import SwiftUI







/// SET-01 top-level Settings surface. `NavigationStack { Form { ... } }`
/// composes the 9 sections each as their own struct so unit tests can
/// render any subsection in isolation.
///
/// All section dependencies are passed in via init — the screen does not
/// reach into any environment / singleton. 11-06 wires it into the app
/// (replacing the legacy minimal SettingsSheet).
@available(iOS 18.4, *)
public struct SettingsScreen: View {

    public let user: User
    public let onSignOut: () async -> Void
    public let onDelete: () async throws -> Void
    public let onDeleted: () -> Void
    public let onDismiss: () -> Void

    /// Reader app-wide defaults. Bindings are owned by AppDependencies in
    /// 11-06; this section only renders + edits them.
    @Binding public var readerTheme: ReaderTheme
    @Binding public var readerFontFamily: ReaderFontFamily
    @Binding public var voiceLanguage: VoiceLanguageOption

    /// Phase 31 plan 31-04 — Mac-only PDF view-mode preference. Bound to
    /// `AppReaderDefaults.pdfViewMode` by `SettingsSheet`. The rendered
    /// `PDFViewModeSection` is itself Mac-gated, so this control is absent on
    /// iOS even though the binding exists for source compatibility.
    @Binding public var pdfViewMode: PDFViewModeSetting

    /// Audio (TTS) deps. The picker persists changes through `audioStore`
    /// and notifies the parent via `onAudioChange`.
    public let audioUserId: UserID
    public let audioInitial: TTSSettings
    public let audioStore: any TTSSettingsStore
    public let onAudioChange: (TTSSettings) -> Void

    /// Sync deps — observable status + a closure to trigger a manual sync.
    public let syncStatus: SyncStatus
    public let onSyncNow: @Sendable () -> Void

    /// Telemetry store backing the Privacy toggle.
    public let telemetryStore: any TelemetryStore

    /// Phase 27-06 footer-detection store backing the "Skip page footers when
    /// indexing" toggle. Defaults to an in-memory store in previews; production
    /// wiring in `AppDependencies` passes the UserDefaults-backed impl.
    public let footerDetectionStore: any FooterDetectionStore

    /// Entitlement resolver — defaults to `.production` (reads
    /// `ReaderAppEntitlementFlag.isGranted`); tests override.
    public let billingEntitlement: ReaderAppEntitlementFlag.Resolver

    /// The account's current entitlement snapshot (plan 12), threaded
    /// straight to `BillingSection` for `RemainingAllowanceView`. `nil` only
    /// in previews/tests.
    public let entitlementSnapshot: EntitlementSnapshot?

    /// When true, `BillingSection` shows a loading allowance row.
    public let allowanceLoading: Bool

    /// Opens the app-owned subscriptions sheet for a non-paid account.
    public let onSubscribe: (() -> Void)?

    @State private var showDeleteConfirm = false
    @State private var deleteModel: DeleteAccountModel?

    /// Owns the legal-link Safari sheet so it presents from the `Form` rather
    /// than from `LegalLinksSection`'s `Section` (a `Section` is an unstable
    /// presentation host — presenting from it collides with the in-progress
    /// Settings sheet and the Safari sheet never appears).
    @State private var legalSheetURL: IdentifiedURL?

    public init(
        user: User,
        readerTheme: Binding<ReaderTheme>,
        readerFontFamily: Binding<ReaderFontFamily>,
        voiceLanguage: Binding<VoiceLanguageOption>,
        pdfViewMode: Binding<PDFViewModeSetting>,
        audioUserId: UserID,
        audioInitial: TTSSettings,
        audioStore: any TTSSettingsStore,
        onAudioChange: @escaping (TTSSettings) -> Void,
        syncStatus: SyncStatus,
        onSyncNow: @escaping @Sendable () -> Void,
        telemetryStore: any TelemetryStore,
        footerDetectionStore: any FooterDetectionStore,
        billingEntitlement: ReaderAppEntitlementFlag.Resolver = .production,
        entitlementSnapshot: EntitlementSnapshot? = nil,
        allowanceLoading: Bool = false,
        onSubscribe: (() -> Void)? = nil,
        onSignOut: @escaping () async -> Void,
        onDelete: @escaping () async throws -> Void,
        onDeleted: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.user = user
        self._readerTheme = readerTheme
        self._readerFontFamily = readerFontFamily
        self._voiceLanguage = voiceLanguage
        self._pdfViewMode = pdfViewMode
        self.audioUserId = audioUserId
        self.audioInitial = audioInitial
        self.audioStore = audioStore
        self.onAudioChange = onAudioChange
        self.syncStatus = syncStatus
        self.onSyncNow = onSyncNow
        self.telemetryStore = telemetryStore
        self.footerDetectionStore = footerDetectionStore
        self.billingEntitlement = billingEntitlement
        self.entitlementSnapshot = entitlementSnapshot
        self.allowanceLoading = allowanceLoading
        self.onSubscribe = onSubscribe
        self.onSignOut = onSignOut
        self.onDelete = onDelete
        self.onDeleted = onDeleted
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Form {
                AccountSection(
                    user: user,
                    onSignOut: onSignOut,
                    onShowDeleteFlow: {
                        // Lazily build the model the first time the row is
                        // tapped, capturing the injected closures. Native
                        // destructive alert below is the deliberate
                        // confirmation — no separate two-step "arm".
                        if deleteModel == nil {
                            deleteModel = DeleteAccountModel(
                                onDelete: onDelete,
                                onDeleted: onDeleted
                            )
                        }
                        showDeleteConfirm = true
                    }
                )
                BillingSection(
                    entitlement: billingEntitlement,
                    entitlementSnapshot: entitlementSnapshot,
                    allowanceLoading: allowanceLoading,
                    onSubscribe: onSubscribe
                )
                ReaderDefaultsSection(
                    defaultTheme: $readerTheme,
                    defaultFontFamily: $readerFontFamily
                )
                VoiceLanguageSection(selection: $voiceLanguage)
                PDFViewModeSection(selection: $pdfViewMode)
                FooterDetectionSection(store: footerDetectionStore)
                AudioSection(
                    userId: audioUserId,
                    initialSettings: audioInitial,
                    store: audioStore,
                    onChange: onAudioChange
                )
                SyncSettingsSection(status: syncStatus, onSyncNow: onSyncNow)
                TelemetrySection(store: telemetryStore)
                LegalLinksSection(onSelect: { legalSheetURL = IdentifiedURL(url: $0) })
                AboutSection()
            }
            .navigationTitle("Settings")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                        .accessibilityIdentifier("settings-done")
                }
            }
            .alert(
                "Delete Account?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    Task { await deleteModel?.runDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your account, your library, your highlights, and your conversations. Your Rishi subscription will be cancelled on the next billing cycle from rishi.fidexa.org. This cannot be undone.")
            }
            .alert(
                "Couldn't delete your account",
                isPresented: Binding(
                    get: { deleteModel?.deleteError != nil },
                    set: { isPresented in
                        if !isPresented { deleteModel?.deleteError = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteModel?.deleteError ?? "")
            }
            .sheet(item: $legalSheetURL) { wrapper in
                SafariSheet(url: wrapper.url)
            }
        }
    }
}

@available(iOS 18.4, *)
private struct SettingsScreenPreviewHost: View {
    @State private var theme: ReaderTheme = .light
    @State private var font: ReaderFontFamily = .system
    @State private var voiceLanguage: VoiceLanguageOption = .english
    @State private var pdfViewMode: PDFViewModeSetting = .automatic

    var body: some View {
        SettingsScreen(
            user: User(
                id: UUID(),
                email: "reader@example.com",
                name: "Sample Reader",
                
            ),
            readerTheme: $theme,
            readerFontFamily: $font,
            voiceLanguage: $voiceLanguage,
            pdfViewMode: $pdfViewMode,
            audioUserId: UUID(),
            audioInitial: .default,
            audioStore: InMemoryTTSSettingsStore(),
            onAudioChange: { _ in },
            syncStatus: SyncStatus(
                lastSyncedAt: Date().addingTimeInterval(-300),
                pendingCount: 0,
                isRunning: false
            ),
            onSyncNow: {},
            telemetryStore: InMemoryTelemetryStore(initial: true),
            footerDetectionStore: InMemoryFooterDetectionStore(initial: true),
            billingEntitlement: .init(isGranted: true),
            entitlementSnapshot: .readerActive(
                .init(
                    periodEndMs: 1_735_689_600_000,
                    remainingNarrationSeconds: 3_600,
                    remainingVoiceChatSeconds: 3_600
                )
            ),
            onSubscribe: {},
            onSignOut: {},
            onDelete: {},
            onDeleted: {},
            onDismiss: {}
        )
    }
}

#Preview("Light") {
    if #available(iOS 18.4, *) {
        SettingsScreenPreviewHost()
            .preferredColorScheme(.light)
    } else {
        // Fallback on earlier versions
    }
}

#Preview("Dark") {
    if #available(iOS 18.4, *) {
        SettingsScreenPreviewHost()
            .preferredColorScheme(.dark)
    } else {
        // Fallback on earlier versions
    }
}
