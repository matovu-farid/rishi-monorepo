[Back to overview](../README.md)

# Authentication

## What it does

Authentication signs the user in, keeps a session token in the device keychain, and exposes the signed-in user identity to the rest of the app. Version 1 supports Sign in with Apple (often written "SIWA"). A previous Google Sign-In path existed during development but was removed before ship — Apple is the only social provider in v1. Account deletion is also handled here, because Apple's App Store Guideline 5.1.1(v) requires it.

## The user flow

- The user taps Sign in with Apple on the signed-out screen.
- Apple's native sheet appears (Face ID / Touch ID prompt).
- On success, the app sends Apple's identity token to the worker, which returns a session.
- The session is stored in the keychain. Every subsequent worker call attaches the bearer token.
- The user can sign out, or delete their account, from Settings. Delete also calls Apple's revoke endpoint and removes the server row.

## Where it lives

| Role | File |
|------|------|
| Public service entry point | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Service/RishiAuthService.swift` |
| Sign in with Apple driver | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Coordinators/SignInWithAppleCoordinator.swift` |
| Sign in with Apple presenter (UIKit bridge) | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Coordinators/SiwaPresenter.swift` |
| Per-request nonce generator | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Coordinators/Nonce.swift` |
| Keychain session store | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Keychain/KeychainSessionStore.swift` |
| Keychain backend (real / in-memory) | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Keychain/SystemKeychainBackend.swift`, `InMemoryKeychainBackend.swift` |
| Bearer-token provider (for `WorkerClient`) | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Service/RishiAuthTokenProvider.swift` |
| Dev-only bypass | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Service/DevBypassConfig.swift` |
| Session model | `apps/apple/Packages/RishiAuth/Sources/RishiAuth/Models/Session.swift` |

## What it depends on

- `RishiCore` — the `AuthService` protocol it conforms to, plus `User`, `Session`, and error types.
- `RishiAPI` — the `SignInSocialEndpoint`, `SignOutEndpoint`, `DeleteUserEndpoint`, and `GetSessionEndpoint`.
- `RishiLogging` — structured events on every sign-in, sign-out, and delete.

## Why it's built this way

- The primary key for an Apple user is `user_identifier` (the Apple "sub"), not email. Apple may return an empty email on the second sign-in, or a `@privaterelay.appleid.com` alias — keying on email would split or lose accounts.
- Sign in with Apple uses a per-request nonce. The presenter generates the nonce, hashes it with SHA-256, binds the hex digest to Apple's authorization request, and sends the same hex digest to the worker as `idToken.nonce`. Skipping or mismatching the nonce makes the worker reject the request.
- Account deletion calls Apple's `https://appleid.apple.com/auth/revoke` endpoint server-side before the database row is removed. App Store Guideline 5.1.1(v) requires the Apple refresh token to be revoked when a user deletes their account.
- `signOut` clears the keychain unconditionally, even if the worker call fails. `deleteAccount` does the opposite — if the worker fails, the keychain is left alone so the user can retry. A half-finished sign-out is recoverable; a half-finished delete would strand the user with no local session but a still-active server account.
- The keychain backend is a protocol with an in-memory fake so unit tests do not hit the real keychain.

## Gotchas

- The bearer token attached to worker requests comes from the keychain via `RishiAuthTokenProvider`. Do not cache it elsewhere — keychain is the single source of truth.
- `DevBypassConfig` exists only in DEBUG builds; the symbol is physically absent from Release binaries so it cannot be referenced from shipping code.
