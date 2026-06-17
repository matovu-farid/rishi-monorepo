//
//  SettingsWindowPresenter.swift
//  rishi
//
//  Phase 32 Plan 32-01 — single-instance open-flag backstop for the dedicated
//  Mac Settings window (RESEARCH §A3 strategy 2, belt-and-suspenders against
//  Pitfall 2 "openWindow duplicates on repeated Cmd+,").
//
//  Pure flag logic, no UIWindowScene/openWindow dependency — fully Swift-Testing
//  verifiable. Plan 32-02/32-03 will hold ONE instance on AppDependencies and
//  flip it from the Settings scene root's onAppear/onDisappear; the Cmd+,
//  dispatcher calls `openWindow(id:)` only when `shouldOpen` is true.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class SettingsWindowPresenter {

    /// True while the dedicated Settings window is on screen. The scene root
    /// sets this via `markOpened()`/`markClosed()`; the Cmd+, dispatcher reads
    /// `shouldOpen` to decide whether to call `openWindow`.
    private(set) var isOpen = false

    /// The dispatcher should only call `openWindow` when the window is not
    /// already open. If `openWindow` already refocuses an existing window this
    /// guard is a no-op; if it would duplicate, this prevents it.
    var shouldOpen: Bool { !isOpen }

    nonisolated init() {}

    func markOpened() { isOpen = true }

    func markClosed() { isOpen = false }
}
