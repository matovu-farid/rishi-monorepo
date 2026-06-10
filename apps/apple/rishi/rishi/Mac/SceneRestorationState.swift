//
//  SceneRestorationState.swift
//  rishi
//
//  Phase 12 Plan 12-02 — Codable scene state used by `@SceneStorage` to
//  restore the selected sidebar/tab item and the currently-open book when
//  the system reattaches a scene (Mac Catalyst window close-then-reopen,
//  iPad multi-window, force-quit + relaunch).
//
//  @SceneStorage can only persist a primitive (String/Int/Double/Bool/URL/
//  Data) per cell, so we JSON-encode the whole struct into a single String
//  cell. Two separate `static let` keys are exposed (`selectedTabKey`,
//  `openBookIdKey`) to keep room for a future split if/when we want to
//  persist the book id in its own SceneStorage cell.
//
//  Decode is intentionally lossy: any malformed input → `.default`. We
//  prefer "land on Library" over "crash on launch" for a state that is by
//  definition disposable across a major schema change.
//

import Foundation
import RishiCore

struct RishiSceneState: Codable, Equatable {
    var selectedTab: MacTab
    var openBookId: BookID?

    /// Default state for a fresh install (and the fallback for any decode
    /// failure). Library tab visible, no book mid-read.
    static let `default` = RishiSceneState(selectedTab: .library, openBookId: nil)

    // MARK: Storage keys — keep these stable across app updates.
    //
    // Renaming either of these will silently reset every existing user's
    // restored window state. If the schema ever changes shape, bump the
    // suffix (e.g. `.v2`) instead of mutating the existing key.
    static let selectedTabKey  = "rishi.scene.selectedTab"
    static let openBookIdKey   = "rishi.scene.openBookId"

    // MARK: Codec helpers

    /// Encodes the state as a JSON `String` suitable for a `@SceneStorage`
    /// `String` cell. Returns `""` on encode failure so the call site can
    /// treat empty == "use default" without branching on optionals.
    func encodeForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    /// Decodes a previously persisted JSON string back into a scene state.
    /// Any non-decodable input — empty cell (first launch), garbage, or
    /// shape drift after an app update — returns `.default` instead of
    /// throwing.
    static func decodeFromStorage(_ raw: String) -> RishiSceneState {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RishiSceneState.self, from: data) else {
            return .default
        }
        return decoded
    }
}
