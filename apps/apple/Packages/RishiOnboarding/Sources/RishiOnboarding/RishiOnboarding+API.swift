// RishiOnboarding — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiOnboarding exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiOnboarding owns the first-run flow: a small set of intro screens,
// sign-in, a mic primer, and a voice-language chooser.
// It also persists the "user has completed onboarding" bit so the app
// can skip the flow on subsequent launches.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 8 unused exports).

// MARK: - Views
//
// OnboardingFlowView          — `UI/OnboardingFlowView.swift`. The full first-run experience:
//                                intro pages -> Sign in with Apple -> mic -> voice language -> done.
// NoCardTrialScreen             — `UI/NoCardTrialScreen.swift`. One-time,
//                                per-account "100 free credits, no card"
//                                explainer shown after first sign-in.

// MARK: - Coordinators / Flows
//
// OnboardingCoordinator       — `Flow/OnboardingCoordinator.swift`. State + actions for
//                                OnboardingFlowView. Talks to AuthService for sign-in and
//                                to OnboardingState for persistence.

// MARK: - Storage
//
// OnboardingState             — `Storage/OnboardingState.swift`. Protocol. Has the user
//                                completed onboarding?
// UserDefaultsOnboardingState — `Storage/OnboardingState.swift`. The production
//                                implementation backed by UserDefaults.
// TrialOnboardingState         — `Storage/TrialOnboardingState.swift`. Protocol.
//                                Has this ACCOUNT (not device) seen the no-card
//                                trial explainer?
// UserDefaultsTrialOnboardingState
//                              — `Storage/TrialOnboardingState.swift`. Production
//                                implementation, keyed by `UserID`.
