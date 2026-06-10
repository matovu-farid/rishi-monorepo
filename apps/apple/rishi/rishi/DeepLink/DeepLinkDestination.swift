//
//  DeepLinkDestination.swift
//  rishi
//
//  Phase 12 Plan 12-03 — typed destination produced by `DeepLinkRouter`.
//  Consumed by `RootView.onOpenURL` to dispatch the right surface
//  (reader cover, conversation sheet, auth callback, etc.).
//

import Foundation
import RishiCore

/// Typed in-app destination resolved from a `URL` (either `rishi://...`
/// custom scheme or `https://rishi.fidexa.org/...` Universal Link).
///
/// `Equatable` so tests can assert exact resolution. `Sendable` so the
/// value can hop across actor boundaries inside `.onOpenURL` handlers.
/// `Hashable` so SwiftUI views could drive `.navigationDestination(item:)`
/// on it in a future refactor without an additional adapter type.
enum DeepLinkDestination: Hashable, Sendable {
    case authCallback(token: String)
    case shareRedeem(token: String)
    case openBook(BookID)
    case openConversation(ConversationID)
    case unknown
}
