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
import SwiftUI
import RishiCore
import RishiReader

// Codable conformance lives on a `nonisolated extension` below so the
// pure-value `encodeForStorage()` / `decodeFromStorage(_:)` helpers can
// invoke `JSONEncoder().encode(self)` without an actor hop. Under
// `default-isolation = MainActor` the synthesized Codable witness would
// otherwise be MainActor-isolated and unusable from nonisolated callers.
// `nonisolated` on this value type: it's a `Sendable`, disposable scene-state
// value whose every member is already annotated `nonisolated` for off-MainActor
// decode. The project-wide `default-isolation = MainActor` incidentally
// re-isolates it; opting the type out restores the intended (and only sound)
// model so its stored properties + synthesized `Equatable` are usable off-main.
nonisolated struct RishiSceneState: Equatable, Sendable {
    var selectedTab: MacTab
    var openBookId: BookID?

    /// Default state for a fresh install (and the fallback for any decode
    /// failure). Library tab visible, no book mid-read.
    ///
    /// Phase 19 Plan 19-11 — `nonisolated` so the off-MainActor decode
    /// helper can reference it without an actor hop.
    nonisolated static let `default` = RishiSceneState(selectedTab: .library, openBookId: nil)

    // MARK: Storage keys — keep these stable across app updates.
    //
    // Renaming either of these will silently reset every existing user's
    // restored window state. If the schema ever changes shape, bump the
    // suffix (e.g. `.v2`) instead of mutating the existing key.
    nonisolated static let selectedTabKey  = "rishi.scene.selectedTab"
    nonisolated static let openBookIdKey   = "rishi.scene.openBookId"

    // MARK: Codec helpers

    /// Encodes the state as a JSON `String` suitable for a `@SceneStorage`
    /// `String` cell. Returns `""` on encode failure so the call site can
    /// treat empty == "use default" without branching on optionals.
    ///
    /// Phase 19 Plan 19-11 — `nonisolated` so the bundled
    /// `decodeSceneRestoreCells(...)` helper can call it from any context
    /// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    nonisolated func encodeForStorage() -> String {
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
    ///
    /// Phase 19 Plan 19-11 — `nonisolated` so the bundled
    /// `decodeSceneRestoreCells(...)` helper can call it off MainActor.
    nonisolated static func decodeFromStorage(_ raw: String) -> RishiSceneState {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RishiSceneState.self, from: data) else {
            return .default
        }
        return decoded
    }

    // MARK: - Phase 19 Plan 19-11 — Nonisolated decode bundle (F-P0-05)
    //
    // Cold launch invokes `restoreSceneState()` on the MainActor `.task`
    // modifier. That body used to run THREE sequential JSON decodes
    // (RishiSceneState + NavigationPath.CodableRepresentation +
    // ReaderRoute) AND a `UUID(uuidString:)` parse — all pure value work,
    // all on main. Per the Swift book "Isolation → Nonisolated Code"
    // section, pure value functions should be `nonisolated` so callers in
    // any isolation context invoke them without a hop.
    //
    // This helper bundles the four decodes into a single nonisolated
    // static. The MainActor call site (RootView.restoreSceneState) does
    // exactly one synchronous call out to it, then assigns the projected
    // tuple into @State.

    /// Pure value decode of every legacy + current scene-restoration
    /// shape. Safe to call from any isolation context (MainActor, an
    /// actor, or a detached Task).
    ///
    /// Returns whatever each individual decoder yields; the caller is
    /// responsible for choosing precedence (NavigationPath > ReaderRoute
    /// > bare-UUID legacy DB lookup).
    // MARK: - Manual nonisolated Codable witness
    //
    // Hand-written so it isn't inferred MainActor-isolated by the module's
    // default-isolation = MainActor. The struct's two stored properties
    // are themselves Codable + Sendable (`MacTab` enum, `BookID` typealias
    // for UUID), so this is a mechanical round-trip.

    private enum CodingKeys: String, CodingKey {
        case selectedTab
        case openBookId
    }

    /// Explicit memberwise init — the manual `init(from:)` below suppresses
    /// the compiler-synthesized one, and `RishiSceneState.default` plus
    /// preview/test fixtures still need it. Nonisolated so any caller
    /// (including the off-MainActor decode bundle) can construct one.
    nonisolated init(selectedTab: MacTab, openBookId: BookID?) {
        self.selectedTab = selectedTab
        self.openBookId = openBookId
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedTab = try c.decode(MacTab.self, forKey: .selectedTab)
        self.openBookId = try c.decodeIfPresent(BookID.self, forKey: .openBookId)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedTab, forKey: .selectedTab)
        try c.encodeIfPresent(openBookId, forKey: .openBookId)
    }

    nonisolated static func decodeSceneRestoreCells(
        tabRaw: String,
        openBookIdRaw: String
    ) -> (state: RishiSceneState, path: NavigationPath?, route: ReaderRoute?, legacyId: UUID?) {
        let state = Self.decodeFromStorage(tabRaw)
        let path: NavigationPath? = {
            let decoded = NavigationPath.decodeFromStorage(openBookIdRaw)
            return decoded.isEmpty ? nil : decoded
        }()
        let route = ReaderRoute.decodeFromStorage(openBookIdRaw)
        let legacyId = UUID(uuidString: openBookIdRaw)
        return (state, path, route, legacyId)
    }
}

// Conformance declaration kept separate from the struct body so the
// manually-written `nonisolated init(from:)` / `encode(to:)` witnesses
// resolve as nonisolated (otherwise default-isolation = MainActor would
// re-isolate the conformance).
nonisolated extension RishiSceneState: Codable {}

// MARK: - Phase 18 Plan 18-01 — ReaderRoute storage bridge
//
// `@SceneStorage` cells are primitives. ReaderRoute is Codable, so we
// JSON-encode it into the existing `openBookIdRaw` String cell. Empty
// string == "no book open", which matches the v0 bare-UUID convention.
//
// `decodeFromStorage(_:)` returns nil for empty / corrupted / future-
// unknown JSON so RootView.restoreSceneState can fall back to the
// legacy bare-UUID branch instead of crashing.

extension ReaderRoute {
    /// Phase 19 Plan 19-11 — `nonisolated` for off-MainActor decode bundling.
    nonisolated static func encodeForStorage(_ route: ReaderRoute?) -> String {
        guard let route else { return "" }
        do {
            let data = try JSONEncoder().encode(route)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Phase 19 Plan 19-11 — `nonisolated` for off-MainActor decode bundling.
    nonisolated static func decodeFromStorage(_ raw: String) -> ReaderRoute? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReaderRoute.self, from: data)
    }
}

// MARK: - Phase 18 Plan 18-01 — NavigationPath storage bridge (F-P0-05 step 2)
//
// Native iOS 17 API: `NavigationPath.CodableRepresentation` round-trips a
// path whose elements are all Codable + Hashable through a single Codable
// value. We JSON-encode it into the same `openBookIdRaw` cell.
//
// Garbage / empty cells decode to an empty NavigationPath rather than
// throwing — scene restore is by-definition disposable across schema
// changes; we prefer "land on Library" over "crash on launch".

extension NavigationPath {
    /// Encode a NavigationPath whose elements are all Codable+Hashable
    /// (e.g. ReaderRoute) to a JSON String suitable for @SceneStorage.
    ///
    /// Phase 19 Plan 19-11 — `nonisolated` for off-MainActor decode bundling.
    nonisolated static func encodeForStorage(_ path: NavigationPath) -> String {
        guard let codable = path.codable else { return "" }
        do {
            let data = try JSONEncoder().encode(codable)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Decode a previously-encoded JSON String back into a NavigationPath;
    /// returns an empty path on failure.
    ///
    /// Phase 19 Plan 19-11 — `nonisolated` for off-MainActor decode bundling.
    nonisolated static func decodeFromStorage(_ raw: String) -> NavigationPath {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return NavigationPath() }
        do {
            let decoded = try JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data)
            return NavigationPath(decoded)
        } catch {
            return NavigationPath()
        }
    }
}
