//
//  VoiceSessionHost.swift
//  rishi
//
//  App-layer host that makes the voice session the PRIMARY AI surface and
//  hosts text chat as a secondary `.sheet` reachable from a button inside
//  the voice UI. Inverts the previous `ChatPanelHost` (text-hosts-voice)
//  relationship: here voice is the host and `ChatPanelView` (RishiChat) is
//  presented on top, bound to the same conversation.
//
//  Lives in `rishi/Views/` because it composes feature packages (RishiVoice
//  + RishiChat) and is mounted by `SignedInView` via the
//  `.fullScreenCover(isPresented: voicePresenter.isPresenting)` binding.
//  RishiVoice does NOT depend on RishiChat (layer rule) — this host brokers
//  both packages by supplying the `onOpenTextChat` closure.
//

import SwiftUI
import RishiCore
import RishiChat
import RishiVoice

/// Full-screen voice surface with an in-voice text-chat sheet.
///
/// Layering:
/// - ``VoiceSessionView`` (RishiVoice) renders the live session + partial
///   transcripts untouched; this host supplies its `onOpenTextChat` closure.
/// - The text-chat sheet wraps ``ChatPanelView`` (RishiChat), resolving the
///   ``ChatPanelViewModel`` for the same `bookId`/conversation the voice
///   session is bound to.
/// - `presenter.pendingInitialQuote` (set by the reader's "Ask about this"
///   affordance) auto-opens the text sheet prefilled with the quote.
struct VoiceSessionHost: View {

    @Bindable var presenter: VoiceSessionPresenter
    let services: BootstrappedServices
    let userId: UserID

    @State private var showTextChat = false
    @State private var textVM: ChatPanelViewModel?

    var body: some View {
        voiceContent
            .sheet(isPresented: $showTextChat) {
                textChatSheet
            }
            .onAppear {
                // "Ask about this" path — a quote was forwarded into the
                // session, so surface the text composer prefilled with it.
                if presenter.pendingInitialQuote != nil {
                    showTextChat = true
                }
            }
    }

    /// Branches the body between the live session UI and the failure surface,
    /// mirroring the previous `ChatPanelHost.voiceContent`. The failure branch
    /// retains the same `presenter` so Retry / Dismiss wire back to a single
    /// source of truth.
    @ViewBuilder
    private var voiceContent: some View {
        let state = presenter.state
        switch state.status {
        case .failed(let reason):
            VoiceErrorView(
                reason: reason,
                message: state.lastError,
                onRetry: {
                    // KEEP: presenter.retry() is @MainActor; the
                    // .fullScreenCover binding mutates on main. UI-bound.
                    // retry() preserves the book context + prefilled quote so
                    // the retried session is not degraded to bookId-only.
                    Task { await presenter.retry() }
                },
                onDismiss: { presenter.dismissFailure() }
            )
        default:
            VoiceSessionView(
                state: state,
                // KEEP: presenter.end() is @MainActor; mutates isPresenting.
                onEnd: { Task { await presenter.end() } },
                onOpenTextChat: { showTextChat = true }
            )
        }
    }

    /// Resolves (or creates) the conversation for the bound book and renders
    /// ``ChatPanelView``. Shows a spinner while the lookup is in flight and
    /// stays on it if the lookup throws (mirrors the prior chat-host
    /// nil-return behavior). Prefills the composer with the pending quote.
    @ViewBuilder
    private var textChatSheet: some View {
        NavigationStack {
            if let textVM {
                ChatPanelView(
                    viewModel: textVM,
                    initialQuote: presenter.pendingInitialQuote
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: presenter.currentBookId) {
            textVM = nil
            if let convo = try? await services.conversationLookup.findOrCreate(
                userId: userId,
                bookId: presenter.currentBookId
            ) {
                textVM = ChatPanelViewModel.make(conversation: convo, services: services)
            }
        }
    }
}
