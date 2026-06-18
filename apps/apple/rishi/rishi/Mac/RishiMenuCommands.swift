//
//  RishiMenuCommands.swift
//  rishi
//
//  Phase 12 Plan 12-01 — Mac Catalyst menu-bar commands. Plug into
//  `rishiApp` via:
//
//      WindowGroup { RootView()... }
//          .commands { RishiMenuCommands(router: deps.macCommandRouter,
//                                         account: deps.macAccountMenu) }
//
//  Every command also carries a ⌘ shortcut (sourced from
//  `RishiKeyboardShortcut`) so the keyboard surface and the menu surface
//  stay in sync. iPad hardware-keyboard users get the same chords for free.
//

import SwiftUI
#if targetEnvironment(macCatalyst)
import RishiReader   // explicit import — ReaderTheme/ReaderFontFamily/PDFViewModeSetting
import RishiSync     // explicit import — SyncStatus (read in SyncMenuItems)
import RishiAudio    // explicit import — VoiceCatalog (voice picker rows)
#endif

struct RishiMenuCommands: Commands {

    let router: MacCommandRouter
    let account: MacAccountMenuModel

    init(router: MacCommandRouter, account: MacAccountMenuModel) {
        self.router = router
        self.account = account
    }

    var body: some Commands {
        // Phase 33 Plan 33-04 (Wave 4) — one lightweight Account submenu under
        // the app menu (after "About"), replacing the Phase 32 Settings…/Cmd+,
        // window entry (the Settings window is removed this phase). Every item
        // is a menu command routed through the focused reader-prefs model to an
        // existing presenter/auth flow/URL — no custom window or sheet (§D).
        // Mac-only: iOS/iPadOS keep the in-app gear + sheet (no app menu there).
        #if targetEnvironment(macCatalyst)
        CommandGroup(after: .appInfo) {
            Menu("Account") {
                AccountMenuItems(account: account)
            }
        }
        #endif

        // FILE — replace the default "New ..." item with our own pair so
        // Catalyst doesn't surface an inert "New Document" menu entry.
        CommandGroup(replacing: .newItem) {
            Button("Import Book…") { router.send(.importBook) }
                .keyboardShortcut(RishiKeyboardShortcut.importBook.key,
                                  modifiers: RishiKeyboardShortcut.importBook.modifiers)
            Button("New Conversation") { router.send(.newConversation) }
                .keyboardShortcut("n", modifiers: .command)
        }

        // EDIT — replace the default Find item so ⌘F focuses our library search.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { router.send(.focusSearch) }
                .keyboardShortcut(RishiKeyboardShortcut.find.key,
                                  modifiers: RishiKeyboardShortcut.find.modifiers)
        }

        // VIEW — theme + font + tab switchers. Phase 32 Plan 32-04: merged
        // into the SINGLE system View menu (created by `.searchable(.toolbar)`
        // in LibrarySearchField.swift) via `CommandGroup(after: .sidebar)`.
        // Previously this declared its own custom View command menu, which
        // collided with SwiftUI's auto-generated View menu and produced TWO
        // "View" menus on Mac. Placing these items after `.sidebar` lands them
        // in the same system View menu — exactly one "View" now appears.
        CommandGroup(after: .sidebar) {
            #if targetEnvironment(macCatalyst)
            // Phase 33 Plan 33-03 (Wave 3) — LIVE-checkmarked reader prefs.
            // These helper Views read the `readerPrefsMenu` focused value
            // (published by SignedInView) so SwiftUI renders + updates native
            // checkmarks; reading the @Observable directly in the Commands body
            // would freeze the checkmark at launch (Pitfall 1). Theme is now an
            // inline Picker bound straight to AppReaderDefaults.theme (replaces
            // the old router-driven theme Buttons — RESEARCH §C Option 2).
            ThemeMenuItems()
            PDFViewModeMenuItems()
            AudioMenuItems()
            Divider()
            #endif
            // Font size stays on the router: there is no app-scope "current
            // size" to checkmark, so these remain stateless commands (§C).
            Button("Increase Font Size") { router.send(.fontIncrease) }
                .keyboardShortcut(RishiKeyboardShortcut.fontIncrease.key,
                                  modifiers: RishiKeyboardShortcut.fontIncrease.modifiers)
            Button("Decrease Font Size") { router.send(.fontDecrease) }
                .keyboardShortcut(RishiKeyboardShortcut.fontDecrease.key,
                                  modifiers: RishiKeyboardShortcut.fontDecrease.modifiers)
            Divider()
            // Phase 37 Plan 37-06 — Apple-Books-style reader affordances.
            // "Find in Book" sends the SAME `.focusSearch` intent as the EDIT
            // menu's ⌘F "Find…" (single Find affordance, no second ⌘F chord —
            // Pitfall 6): when a reader is open it intercepts `focusSearch` and
            // opens its in-book search sheet; otherwise the library search
            // field focuses. "Add Bookmark" (⌘D) posts `RishiCommand.addBookmark`,
            // toggled by the open reader screen.
            Button("Find in Book") { router.send(.focusSearch) }
            Button("Add Bookmark") { router.send(.addBookmark) }
                .keyboardShortcut(RishiKeyboardShortcut.addBookmark.key,
                                  modifiers: RishiKeyboardShortcut.addBookmark.modifiers)
            Divider()
            #if targetEnvironment(macCatalyst)
            SyncMenuItems()
            Divider()
            #endif
            Button("Library") { router.send(.selectTab(.library)) }
                .keyboardShortcut(RishiKeyboardShortcut.libraryTab.key,
                                  modifiers: RishiKeyboardShortcut.libraryTab.modifiers)
            Button("Chats")   { router.send(.selectTab(.chats)) }
                .keyboardShortcut(RishiKeyboardShortcut.chatsTab.key,
                                  modifiers: RishiKeyboardShortcut.chatsTab.modifiers)
        }

        // WINDOW — extend the system Window menu with a "Reader" jump that
        // routes to the library (where the user picks a book to open).
        CommandGroup(after: .windowArrangement) {
            Button("Reader") { router.send(.selectTab(.library)) }
        }
    }
}

#if targetEnvironment(macCatalyst)

// MARK: - Reader-preference menu items (Phase 33 Plan 33-03, Wave 3)
//
// Each helper View reads the `readerPrefsMenu` focused value published by the
// live SignedInView. Hosting the observation inside a View (not the Commands
// body) is what makes the native checkmarks update live (RESEARCH §A2,
// Pitfall 1). The focused value is `nil` until the live view mounts, so every
// item disables itself before bootstrap with no extra guard.

/// Theme as an inline Picker bound directly to `AppReaderDefaults.theme`
/// (RESEARCH §C Option 2). Replaces the old router-driven theme Buttons; the
/// theme router intent is now unused but left in place (Plan 05 decides
/// removal).
private struct ThemeMenuItems: View {
    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Picker("Theme", selection: prefs?.theme ?? .constant(.light)) {
            Text("Light").tag(ReaderTheme.light)
            Text("Sepia").tag(ReaderTheme.sepia)
            Text("Dark").tag(ReaderTheme.dark)
        }
        .pickerStyle(.inline)
        .disabled(prefs == nil)
    }
}

/// PDF View Mode as an inline Picker over the four `PDFViewModeSetting` cases,
/// bound to `AppReaderDefaults.pdfViewMode` (current case gets the checkmark).
private struct PDFViewModeMenuItems: View {
    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Picker("PDF View Mode", selection: prefs?.pdfViewMode ?? .constant(.automatic)) {
            ForEach(PDFViewModeSetting.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.inline)
        .disabled(prefs == nil)
    }
}

/// Audio voice + speed as inline Pickers grouped under an "Audio" submenu.
/// Speed is a discrete Picker (a Slider is not menu-native — RESEARCH §B5),
/// both bound through the focused model's live audio holder.
private struct AudioMenuItems: View {
    /// Discrete speed steps surfaced as menu rows (matches the worker speed
    /// range; a continuous Slider has no native menu checkmark).
    private static let speedSteps: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Menu("Audio") {
            Picker("Voice", selection: prefs?.voice ?? .constant(VoiceCatalog.all[0])) {
                ForEach(VoiceCatalog.all, id: \.self) { voice in
                    Text(VoiceCatalog.displayName(for: voice)).tag(voice)
                }
            }
            .pickerStyle(.inline)
            Picker("Speed", selection: prefs?.speed ?? .constant(1.0)) {
                ForEach(Self.speedSteps, id: \.self) { step in
                    Text(Self.speedLabel(step)).tag(step)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(prefs == nil)
    }

    private static func speedLabel(_ value: Double) -> String {
        String(format: "%gx", value)
    }
}

/// Sync submenu: an Auto Sync Toggle (live checkmark) bound to
/// `AppReaderDefaults.autoSync`, a "Sync Now" Button reusing
/// `syncEngine.syncNow()` (manual path — ignores the autoSync flag), and a
/// disabled status line reading the live `SyncStatus`.
private struct SyncMenuItems: View {
    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Menu("Sync") {
            Toggle("Auto Sync", isOn: prefs?.autoSync ?? .constant(true))
                .disabled(prefs == nil)
            Button("Sync Now") { prefs?.onSyncNow() }
                .disabled(prefs == nil)
            Divider()
            Text(Self.statusLine(prefs?.syncStatus))
                .disabled(true)
        }
        .disabled(prefs == nil)
    }

    /// Human-readable status from the live `SyncStatus`. Read inside the View
    /// so it updates live as the engine applies snapshots after every wave.
    private static func statusLine(_ status: SyncStatus?) -> String {
        guard let status else { return "Not synced" }
        if status.isRunning { return "Syncing…" }
        if let error = status.lastError, !error.isEmpty {
            return "Sync error: \(error)"
        }
        if let last = status.lastSyncedAt {
            let formatted = last.formatted(date: .abbreviated, time: .shortened)
            if status.pendingCount > 0 {
                return "Last synced \(formatted) · \(status.pendingCount) pending"
            }
            return "Last synced \(formatted)"
        }
        if status.pendingCount > 0 {
            return "\(status.pendingCount) pending"
        }
        return "Not synced yet"
    }
}

// MARK: - Account submenu (Phase 33 Plan 33-04, Wave 4)

/// One lightweight Account entry point: a disabled email line, a disabled
/// About version line, then Manage Subscription / Sign Out / Privacy / Terms
/// commands routed through the app-level `MacAccountMenuModel` (RESEARCH §D). The
/// account/legal/auth payload is app-GLOBAL, so it is read from this
/// focus-independent model rather than `@FocusedValue` — a focused value
/// resolves to nil whenever the publishing scene loses focus (e.g. when the
/// menu bar opens), which greyed-out the whole submenu and showed "Not signed
/// in" even while signed in. No custom window or sheet — Manage Subscription
/// drives StoreKit's system sheet via the existing presenter, legal links open
/// externally, Sign Out reuses the existing auth flow. The payload is `nil`
/// until the live SignedInView mounts (and after sign-out), which disables every
/// command before bootstrap with no extra guard.
private struct AccountMenuItems: View {
    let account: MacAccountMenuModel
    var body: some View {
        let payload = account.payload
        // Disabled info: signed-in email (resolved in SignedInView, not via the
        // async currentUser) + the bundle version (Catalyst has no AppKit about
        // panel, so About is a disabled line mirroring AboutSection.swift:39-43).
        Text(payload?.userEmail ?? "Not signed in")
            .disabled(true)
        Text(Self.aboutLine)
            .disabled(true)
        Divider()
        Button("Manage Subscription…") { payload?.onManageSubscription() }
            .disabled(payload == nil)
        Button("Sign Out") { payload?.onSignOut() }
            .disabled(payload == nil)
        Divider()
        Button("Privacy Policy") { payload?.onOpenPrivacy() }
            .disabled(payload == nil)
        Button("Terms of Use") { payload?.onOpenTerms() }
            .disabled(payload == nil)
    }

    /// "rishi X.Y (build)" from Bundle.main — mirrors AboutSection's version
    /// read so the menu line tracks every release automatically.
    private static var aboutLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "rishi \(short) (\(build))"
    }
}

#endif
