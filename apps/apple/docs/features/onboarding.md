[Back to overview](../README.md)

# First-run Onboarding

## What it does

Onboarding is the short flow a new user sees the first time they open the app. It welcomes them, gets them signed in, gives them a book to read (a bundled sample or one they import), and asks for the two system permissions the app needs later (microphone for voice chat, notifications for sync wake-ups). After the user finishes once, the flow never appears again on that device.

## The user flow

- Launch the app for the first time — the welcome screen appears as a full-screen cover.
- Tap "Get started", arriving at the sign-in screen (powered by the auth package).
- After sign-in, choose "Use the sample book" or "Import a file" to seed the library.
- See a primer screen explaining why the app will ask for microphone permission; tap "Continue" to trigger the system prompt.
- See a primer screen for notifications, then a short hint pointing at the first book in the library. The flow flips a persisted flag and dismisses.

## Where it lives

| Role | File |
|------|------|
| Flow root view | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/OnboardingFlowView.swift` |
| Stage state machine | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/Flow/OnboardingCoordinator.swift` |
| Persisted flags (UserDefaults) | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/Storage/OnboardingState.swift` |
| Welcome screen | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/WelcomeScreen.swift` |
| Sample-or-import screen | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/SampleOrImportScreen.swift` |
| Microphone permission primer | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/MicPermissionPrimer.swift` |
| Notifications permission primer | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/NotificationsPermissionPrimer.swift` |
| First-reader hint | `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/FirstReaderHint.swift` |

## What it depends on

- `RishiCore` — shared types.
- `RishiAuth` — to drive the sign-in stage (the actual buttons live in the auth package, the onboarding screen just delegates).
- `RishiLibrary` — so the sample-or-import stage can install the bundled sample book and trigger the import sheet.
- `RishiUIKit` — design tokens.
- `RishiLogging` — events for each stage transition.

## Why it's built this way

- The coordinator is a small state machine driven by a single `currentStage` value, marked `@Observable` so SwiftUI redraws automatically when the stage changes. Each stage is its own view; the flow root just switches on the current stage.
- Permission primers run *before* the system permission dialog. iOS only shows the system dialog once per install — if the user denies it, they have to go to Settings. A primer screen explains why first, so they understand the ask before the system pops up.
- The persisted flags live in `UserDefaults` (`onboarding.completed`, `onboarding.primer.mic`, `onboarding.primer.notifications`). Returning users with the flags already set skip past primers they have already seen.
- The flow does not own sign-in or imports itself — it delegates via closures passed in from the app's composition root. This keeps the onboarding package free of UIKit and `AVFoundation` imports, so it compiles and tests cleanly on macOS during `swift test`.

## Gotchas

- The flow is shown as a `.fullScreenCover` from the app root. Do not try to wrap it in a `.sheet` — the welcome step assumes full-screen layout.
- Completion is tied to the persisted flag, not to reaching the last screen. If you change the order of stages, double-check that the final stage still calls `setHasCompletedOnboarding(true)` before dismissing.
