//
//  ReaderVoiceEntry.swift
//  rishi
//
//  App-layer adapter satisfying RishiReader's `ReaderVoicePresenter` seam.
//  The reader screens call `presentVoice(bookId:initialQuote:)` from their
//  toolbar voice button + "Ask about this" selection action; this entry
//  gates the request on the Read-Aloud-style entitlement check and then
//  drives `VoiceSessionPresenter.start(...)`.
//
//  Layer rule: RishiReader does not import RishiVoice / RishiBilling. The
//  concrete bridge lives here in the app target (the broker) and forwards
//  to the app-owned `VoiceSessionPresenter`.
//

import Foundation
import RishiBilling
import RishiCore
import RishiReader

/// Bridges the reader's `ReaderVoicePresenter` seam onto the app's
/// `VoiceSessionPresenter`, applying the same entitlement gate the reader
/// destinations use for Read Aloud (entitlement snapshot + DEBUG
/// `UITestBypass` override).
@MainActor
final class ReaderVoiceEntry: ReaderVoicePresenter {

    private let voicePresenter: VoiceSessionPresenter
    private let entitlementProvider: () async -> EntitlementLevel
    private let onRequestPaywall: (String) -> Void

    init(
        voicePresenter: VoiceSessionPresenter,
        entitlementProvider: @escaping () async -> EntitlementLevel,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self.voicePresenter = voicePresenter
        self.entitlementProvider = entitlementProvider
        self.onRequestPaywall = onRequestPaywall
    }

    func presentVoice(bookId: BookID, initialQuote: String?) {
        // KEEP: entitlementProvider() awaits the entitlement actor (off-main
        // internally); voicePresenter.start(...) is @MainActor (drives the
        // .fullScreenCover binding). UI-bound by design.
        Task {
            let level = await entitlementProvider()
            var entitled = level == .pro
            #if DEBUG
            if UITestBypass.isActive { entitled = true }
            #endif
            guard entitled else { onRequestPaywall("Voice Chat"); return }
            await voicePresenter.start(bookId: bookId, initialQuote: initialQuote)
        }
    }
}
