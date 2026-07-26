# Onboarding iPad CTA Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep onboarding primary buttons full-width on iPhone while giving them a centered, compact width on iPad, and keep language-primer copy within a readable centered column on regular-width layouts.

**Architecture:** Add internal onboarding width configurations/modifiers that read SwiftUI horizontal size class. Apply the CTA rule to every onboarding primary button, including the separate post-auth trial and sample/import screens, and apply the content rule to the language primer explanation. Existing button styles, labels, actions, accessibility identifiers, and scaffold behavior remain unchanged.

**Tech Stack:** SwiftUI, Swift Testing, Swift Package Manager (`RishiOnboarding`).

---

## Files and responsibilities

- Create `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/OnboardingCTA.swift` for the shared responsive CTA and readable-content width rules.
- Modify `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/WelcomeScreen.swift` to use the shared rule for Get started.
- Modify `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/MicPermissionPrimer.swift` and `VoiceLanguagePrimer.swift` for their primary actions.
- Modify `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/FirstReaderHint.swift`, `NoCardTrialScreen.swift`, and `SampleOrImportScreen.swift` for their primary actions.
- Modify `apps/apple/Packages/RishiOnboarding/Tests/RishiOnboardingTests/OnboardingUITests.swift` with focused configuration tests.

## Implementation tasks

### Task 1: Lock the responsive sizing rule with tests

- [ ] Add tests asserting compact width returns `.infinity` and regular width returns a centered maximum of 400 points.
- [ ] Run the onboarding package tests and confirm the new tests fail because the configuration does not exist.

### Task 2: Implement and apply the shared CTA rule

- [ ] Add an internal `OnboardingCTAConfiguration` with `maxWidth(for:)` and an `onboardingCTAWidth()` View modifier. Use `@Environment(\\.horizontalSizeClass)` and apply `.frame(maxWidth: configuration.maxWidth(for: horizontalSizeClass))` to the button label/container so compact layouts remain unchanged.
- [ ] Apply the modifier to the prominent primary buttons on all six onboarding screens. Preserve the two-button sample/import stack by constraining each primary/bordered button individually while leaving the stack margins intact.
- [ ] Add an iPad preview device to the Welcome preview only if it does not require changing production behavior; otherwise rely on the size-class rule and package tests.

### Task 2a: Bound language-primer copy on iPad

- [ ] Add a regular-width content maximum of 560 points, retaining infinite width for compact layouts.
- [ ] Apply the content-width modifier to the language primer explanatory text after its existing padding and multiline alignment modifiers.
- [ ] Keep the title, picker, secondary action, and all compact-layout behavior unchanged.

### Task 3: Verify and review

- [ ] Run the focused `RishiOnboarding` test target and confirm all tests pass.
- [ ] Run an independent adversarial review of the diff for missed onboarding call sites, compact-layout regressions, and accessibility/action changes.
- [ ] Re-review and fix any Critical/High findings, then inspect the final diff and working tree for unrelated changes.

## Consumer / call-site audit

| Consumer | Primary CTA | Required change |
|---|---|---|
| `WelcomeScreen` | Get started | Apply shared responsive width |
| `MicPermissionPrimer` | Allow microphone | Apply shared responsive width |
| `VoiceLanguagePrimer` | Continue | Apply shared responsive width |
| `FirstReaderHint` | Got it | Apply shared responsive width |
| `NoCardTrialScreen` | Got it | Apply shared responsive width |
| `SampleOrImportScreen` | Use sample book, Import a book | Apply shared responsive width to both |

## Implementation order

1. Add failing configuration tests.
2. Add the shared configuration/modifier.
3. Apply the modifier to all audited primary CTA call sites.
4. Run tests and perform the implementation adversarial review.

## Explicitly out of scope

- Changing iPhone button dimensions or spacing.
- Changing secondary text buttons, button labels, actions, or accessibility identifiers.
- Changing `RishiScreenScaffold`, navigation flow, or content spacing.
- Adding device-specific runtime branches beyond horizontal size class.

## Adversarial review loop

Each round: review → log findings → update plan/code → re-review.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A shared rule could accidentally affect compact iPhone layout if it replaces the existing infinite-width behavior. | Plan explicitly requires `.infinity` for compact size class and preserves existing screen margins. |
| 2 | Medium | The sample/import screen has two bordered actions, not one. | Consumer audit explicitly includes both buttons and requires constraining each individually. |
| 3 | Low | SwiftUI UI tests do not directly expose rendered button width in the existing package test setup. | Test the pure width configuration and verify the full package build; visual device validation remains a manual follow-up. |

**Round 1 result:** Re-review required for implementation findings after code changes.

### Round 2 — Implementation review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The repository already contains unrelated scheme/build-number edits and untracked packaging artifacts. | Left untouched; they are outside this CTA task and predate the implementation. |
| 2 | Low | Existing package tests do not render every CTA at both size classes. | Pure width behavior is covered; all six screens and both sample/import actions are compiled and construction-tested where existing coverage applies. |

**Round 2 result:** PASS — 0 open Critical/High issues. Verification completed with 21 onboarding tests passing, 11 UIKit tests passing, and a successful generic iOS Simulator build.

### Round 3 — Follow-up language-copy review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The package test can verify the shared content-width contract but cannot introspect the rendered SwiftUI modifier application without adding a new UI inspection dependency. | Accepted as a test-coverage note; the language primer call site is directly audited, and the package/build verification confirms the modifier compiles in the production view. |
| 2 | Medium | The working tree still contains unrelated scheme/build-number changes and an untracked packaging artifact. | Left untouched because these predate and are outside the requested UI change. |

**Round 3 result:** PASS WITH NOTES — 0 open Critical/High issues; the two Medium items are explicitly accepted as documented scope/coverage notes.
