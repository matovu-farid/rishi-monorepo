//
//  SettingsWindowSizing.swift
//  rishi
//
//  Phase 32 Plan 32-01 — pure fixed-size helper for the dedicated Mac Settings
//  window (RESEARCH §A5). Mirrors the `max()` clamp semantics of
//  RishiReader's PDFMacWindowSizing.clampedMinimum so the imperative
//  `sizeRestrictions` apply in Plan 32-03 has a tested core.
//
//  No `#if targetEnvironment(macCatalyst)` gate: this is platform-neutral pure
//  CoreGraphics math. The imperative `UIWindowScene.sizeRestrictions` apply that
//  USES this (Plan 32-03) is the Catalyst-gated surface.
//

import CoreGraphics

enum SettingsWindowSizing {

    /// Fixed prefs-window size (720x640), per RESEARCH §A5 / HIG fixed-size
    /// settings convention. Combined with `.defaultSize` for the SwiftUI initial
    /// frame and `sizeRestrictions` min==max for the hard clamp in Plan 32-03.
    static let fixedSettingsSize = CGSize(width: 720, height: 640)

    /// Pure clamp: raises each dimension of `existing` to at least the `fixed`
    /// size, never shrinking a larger existing value. Mirrors
    /// PDFMacWindowSizing.clampedMinimum's `max()` semantics so the
    /// sizeRestrictions apply only ever raises an existing minimum.
    static func clamped(existing: CGSize, to fixed: CGSize = fixedSettingsSize) -> CGSize {
        CGSize(
            width: max(existing.width, fixed.width),
            height: max(existing.height, fixed.height)
        )
    }
}
