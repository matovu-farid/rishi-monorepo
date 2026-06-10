//
//  ChatPanelHost.swift
//  rishi
//
//  Phase 10 Plan 10-06 — app-layer host wrapping `ChatPanelView` with a
//  voice-start toolbar button and the `.fullScreenCover(isPresented:)`
//  hosting `VoiceSessionView`. RishiChat does NOT depend on RishiVoice
//  (layer rule) — this host brokers both packages.
//
//  Lives in `rishi/Views/` because it composes feature packages and is
//  consumed by `RootView` when the chat sheet mounts. The host is the
//  ONLY place that decides whether the voice button is visible.
//

import SwiftUI
import RishiCore
import RishiChat
import RishiVoice

/// SwiftUI host wrapping ``ChatPanelView`` with a voice toolbar button +
/// full-screen voice cover. Created by ``RootView`` when the chat sheet
/// mounts; lives for the sheet's lifetime.
///
/// Layering:
/// - ``ChatPanelView`` (RishiChat) is rendered untouched.
/// - The voice button + ``VoiceSessionView`` cover are added at this layer.
/// - `presenter.isPresenting` drives the cover; the cover's body switches on
///   `presenter.state.status` to swap in ``VoiceErrorView`` for terminal
///   failures.
struct ChatPanelHost: View {

    @Bindable var presenter: VoiceSessionPresenter
    let viewModel: ChatPanelViewModel
    let bookId: BookID?
    let initialQuote: String?

    init(
        presenter: VoiceSessionPresenter,
        viewModel: ChatPanelViewModel,
        bookId: BookID?,
        initialQuote: String? = nil
    ) {
        self._presenter = Bindable(wrappedValue: presenter)
        self.viewModel = viewModel
        self.bookId = bookId
        self.initialQuote = initialQuote
    }

    var body: some View {
        ChatPanelView(viewModel: viewModel, initialQuote: initialQuote)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await presenter.start(bookId: bookId) }
                    } label: {
                        Image(systemName: "waveform.circle")
                    }
                    .accessibilityLabel("Start voice session")
                    .accessibilityIdentifier("chat.voice.start")
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { presenter.isPresenting },
                set: { newValue in
                    if newValue == false {
                        Task { await presenter.end() }
                    }
                }
            )) {
                voiceContent
            }
    }

    /// Branches the cover body between the live session UI and the failure
    /// surface. The failure-surface branch retains the same `presenter`
    /// reference so Dismiss / Try-again wire back to a single source of
    /// truth — no second nested cover.
    @ViewBuilder
    private var voiceContent: some View {
        let state = presenter.state
        switch state.status {
        case .failed(let reason):
            VoiceErrorView(
                reason: reason,
                message: state.lastError,
                onRetry: {
                    Task {
                        // Reset and restart the same conversation context.
                        presenter.dismissFailure()
                        await presenter.start(bookId: bookId)
                    }
                },
                onDismiss: { presenter.dismissFailure() }
            )
        default:
            VoiceSessionView(
                state: state,
                onEnd: { Task { await presenter.end() } }
            )
        }
    }
}
