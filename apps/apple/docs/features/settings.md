[Back to overview](../README.md)

# Settings

## What it does

Settings is the single screen reached from the user-avatar button in the top bar. It groups every preference and account action the app exposes: who you are signed in as, which subscription you are on, reader defaults (theme and font family), Read Aloud defaults (voice and speed), sync status, telemetry opt-in, and the legal links and version footer. Account deletion lives here too.

## The user flow

- Tap the avatar in the top bar to open the Settings sheet.
- Scroll through grouped sections: Account, Billing, Reader, Audio, Sync, Telemetry, About.
- Adjust a setting — for example, change the reader theme to Sepia. The change is persisted immediately and the reader picks it up next time you open a book.
- Tap "Manage subscription" to open Apple's in-app Manage Subscriptions sheet, or "Delete account" to start the confirm-and-revoke flow.
- Tap Done to dismiss; nothing needs to be "saved" — every change writes through as it happens.

## Where it lives

| Role | File |
|------|------|
| Screen root (a `Form` with seven sections) | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/SettingsScreen.swift` |
| Account section + delete flow | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Account/AccountSection.swift`, `DeleteAccountFlow.swift` |
| Billing section (subscription state) | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Billing/BillingSection.swift` |
| Reader defaults section | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Reader/ReaderDefaultsSection.swift` |
| Audio (TTS) defaults section | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Audio/AudioSection.swift` |
| Sync status + Sync Now | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Sync/SyncSettingsSection.swift` |
| Telemetry opt-in | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Telemetry/TelemetrySection.swift`, `Telemetry/` |
| About + legal links | `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/About/AboutSection.swift`, `LegalLinksSection.swift` |

## What it depends on

- `RishiCore` — shared models (`User`, `EntitlementLevel`).
- `RishiAuth` — sign-out and account-delete actions.
- `RishiBilling` — entitlement state and the Manage Subscriptions launcher.
- `RishiSync` — observable sync status.
- `RishiAudio` — TTS voice / speed store for the Audio section.
- `RishiReader` — `ReaderTheme` and `ReaderFontFamily` enums.
- `RishiUIKit` — design tokens.
- `RishiLogging` — structured events for sign-out, delete, and toggles.

## Why it's built this way

- Every section is a stand-alone `View` struct that takes its dependencies in its `init`. The screen never reaches into a singleton or environment. This makes each section unit-testable on its own, and lets the composition root wire real services into one section while injecting fakes into another.
- The screen does not hold its own state. Reader theme, font family, audio settings, telemetry opt-in — every binding is passed in from the app's composition root. Changes flow back out through closures so the values can be persisted to the right store.
- Account deletion uses a separate two-step `DeleteAccountFlow` to force a confirmation step. Apple expects deletion to be deliberate (Guideline 5.1.1(v)) and not a single accidental tap.
- The Billing section reads from `EntitlementReconciler` rather than asking the worker directly, so the row stays correct in airplane mode and updates instantly when a purchase finishes.

## Gotchas

- The avatar button that opens Settings lives in the app target, not in this package — the package only provides the screen and expects the caller to present it as a sheet.
- Manage Subscriptions is the system sheet; do not roll a custom subscription-management screen. App Review will flag a duplicate.

---

**Next:** [../architecture/package-consolidation.md](../architecture/package-consolidation.md) — optional reference: which packages we considered merging and why we deferred.
