//
//  ReaderPrefsMenuModel.swift
//  rishi
//
//  Phase 33 Plan 33-01 — the menu-binding contract the rest of Phase 33
//  builds on. Two pieces:
//
//  1. `shouldRunAutoSync(_:)` — a pure, #if-free decision function the three
//     automatic-sync entry points read in Wave 2. Manual "Sync Now" never
//     consults it. Kept OUTSIDE the macCatalyst gate so it is testable on
//     every target.
//  2. `ReaderPrefsMenuModel` + the `readerPrefsMenu` FocusedValueKey — the
//     focused-value payload `SignedInView` publishes (Wave 3) and
//     `RishiMenuCommands` reads via `@FocusedValue` to render LIVE checkmarks
//     (Wave 4). Catalyst-gated: iOS keeps the in-app settings sheet.
//
//  This wave introduces the data/contract only — no menu UI, no SignedInView
//  publish, no call-site gating. See 33-RESEARCH.md §A2, §D, §G5.
//

import SwiftUI
import RishiReader   // explicit import — ReaderTheme/ReaderFontFamily/PDFViewModeSetting live here
import RishiSync     // explicit import — SyncStatus lives here

/// Pure auto-sync gate decision. The three automatic-sync triggers (BGTask,
/// silent push, shell-appearance kick) read this in Wave 2 to honor the
/// `AppReaderDefaults.autoSync` flag; manual "Sync Now" bypasses it entirely.
/// Trivial today, but a single named seam lets a Swift Testing test pin the
/// on -> true / off -> false behavior independent of the Catalyst gate.
func shouldRunAutoSync(_ autoSync: Bool) -> Bool { autoSync }

#if targetEnvironment(macCatalyst)

/// The focused-value payload published by the live `SignedInView` (Wave 3) and
/// consumed by `RishiMenuCommands` helper `View`s (Wave 4). A focused value
/// resolves to `nil` until a focused scene publishes it, which gives automatic
/// "disabled before bootstrap" behavior for the menu with no extra guard.
///
/// The field set matches 33-RESEARCH.md §A2 + §D so Waves 3-4 do not need to
/// widen the struct. No audio-store logic lives here (that is built in
/// `SignedInView`, Wave 3) — the model only carries the resolved bindings and
/// action closures.
@MainActor
struct ReaderPrefsMenuModel {
    var theme: Binding<ReaderTheme>
    var pdfViewMode: Binding<PDFViewModeSetting>
    var fontFamily: Binding<ReaderFontFamily>
    var voice: Binding<String>
    var speed: Binding<Double>
    var autoSync: Binding<Bool>
    var onSyncNow: () -> Void
    var syncStatus: SyncStatus
    var userEmail: String?
    var onManageSubscription: () -> Void
    var onSignOut: () -> Void
    var onOpenPrivacy: () -> Void
    var onOpenTerms: () -> Void
}

private struct ReaderPrefsMenuKey: FocusedValueKey {
    typealias Value = ReaderPrefsMenuModel
}

extension FocusedValues {
    var readerPrefsMenu: ReaderPrefsMenuModel? {
        get { self[ReaderPrefsMenuKey.self] }
        set { self[ReaderPrefsMenuKey.self] = newValue }
    }
}

#endif
