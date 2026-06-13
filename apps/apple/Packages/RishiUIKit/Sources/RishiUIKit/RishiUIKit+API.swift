// RishiUIKit — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiUIKit exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiUIKit is the design system: color, typography, spacing,
// radius, motion tokens, plus a couple of cross-cutting view
// modifiers and accessibility-label constants. No business logic.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 3 unused exports).

// MARK: - Design tokens
//
// RishiColor                  — `Tokens/RishiColor.swift`. Namespace enum holding semantic
//                                color tokens (background, primaryText, accent, ...).
// RishiTypography             — `Tokens/RishiTypography.swift`. Font styles (title, body,
//                                caption, monospace digits).
// RishiSpacing                — `Tokens/RishiSpacing.swift`. Standard spacings (xs/sm/md/lg/xl).
// RishiRadius                 — `Tokens/RishiRadius.swift`. Standard corner radii.
// RishiMotion                 — `Tokens/RishiMotion.swift`. Animation curves + durations.

// MARK: - Modifiers
//
// View.rishiAnimation(...)    — `Modifiers/RishiAnimationModifier.swift`. View extension
//                                that applies a RishiMotion preset as an animation.

// MARK: - Accessibility
//
// A11yLabel                   — `A11y/AccessibleLabels.swift`. Namespace enum of shared
//                                accessibility labels referenced by views across packages.
