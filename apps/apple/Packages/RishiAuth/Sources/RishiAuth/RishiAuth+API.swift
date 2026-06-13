// RishiAuth — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiAuth exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiAuth owns Sign in with Apple, the Keychain-backed session
// store, and the TokenProvider that hands bearer tokens to
// RishiAPI's WorkerClient. The app talks to RishiAuthService; the
// other types are seams for tests.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 4 unused exports).

// MARK: - Service
//
// RishiAuthService            — `Service/RishiAuthService.swift`. Actor. Implements
//                                RishiCore.AuthService. signInWithApple / signOut /
//                                deleteAccount / currentUser. The app injects this.
// RishiAuthTokenProvider      — `Service/RishiAuthTokenProvider.swift`. TokenProvider that
//                                reads from KeychainSessionStore. Pass to WorkerClient.
// DevBypassConfig             — `Service/DevBypassConfig.swift`. Reads `RISHI_DEV_BYPASS`
//                                from Info.plist. When true, adds X-Dev-Bypass to outbound
//                                requests (gates premium features in dev/CI).

// MARK: - Models
//
// Session                     — `Models/Session.swift`. The persisted auth session
//                                (token, userId, email, provider, issuedAt, expiresAt).
// SignInProvider              — `Models/SignInProvider.swift`. Enum of providers (apple, etc.).

// MARK: - Keychain
//
// KeychainSessionStore        — `Keychain/KeychainSessionStore.swift`. Actor. save / load /
//                                delete the current Session in the system keychain.
// KeychainBackend             — `Keychain/KeychainBackend.swift`. Protocol abstracting the
//                                four SecItem CRUD calls. Lets tests swap in a fake.

// MARK: - Coordinators / Flows
//
// SignInWithAppleCoordinator  — `Coordinators/SignInWithAppleCoordinator.swift`. Actor.
//                                Drives the SIWA flow end to end: presenter -> Worker ->
//                                Session. Used by RishiAuthService.signInWithApple.
// AppleSignInDriver           — `Service/SignInDriver.swift`. Protocol the coordinator depends
//                                on. The system implementation calls AuthenticationServices;
//                                tests provide a stub.

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit 01851e4dc.)
//
// KeychainBackend             — kept public so cross-module tests (RishiAuthTests, integration
//                                tests in the app target) can supply a fake keychain. Demoting
//                                it would require an `@testable import` chain.
// SystemKeychainBackend       — kept public because it is the default value of
//                                `KeychainSessionStore.init(backend:)`. A public init's default
//                                value must itself be public.
// SiwaPresenter family        — SiwaPresenter / SystemSiwaPresenter / SiwaScope / SiwaName /
//                                SiwaCredential. Kept public so the app target can inject a
//                                presenter bound to the current UIWindow, and so tests can
//                                drive the coordinator without a real ASAuthorizationController.
