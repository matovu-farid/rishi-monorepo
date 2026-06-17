# Native dialogs migration

## Problem

Several "interrupt the user with a short message + 1-3 buttons" surfaces are
hand-built full-screen SwiftUI views. They re-implement layout, theming, and
cross-platform behavior that the system `.alert` / `.confirmationDialog` already
provide for free. On Mac Catalyst the custom layouts misbehave (e.g. the voice
"Microphone access needed" screen stretched its primary button across the whole
window). Native dialogs are already well-styled and adapt across iOS and Mac, so
the truly alert-like surfaces should use them.

## Scope

Convert only **alert-like** surfaces — those that interrupt with a short message
and 1-3 actions. Explicitly out of scope: full-screen feature flows (onboarding,
permission primers, paywall), and the reader content sheets (TOC, theme picker,
highlight-note editor) — `ReaderModalOverlay` keeps its Catalyst sheet workaround.

Surfaces to migrate:

1. **Voice session failure** (`VoiceErrorView`)
2. **Reader cold-open failure** (`ReaderColdOpenFailureOverlay`, PDF + EPUB)
3. **Delete-account confirmation** (`DeleteAccountFlow`)

The app already uses native dialogs for delete-book (`.alert`), delete-conversation
(`.confirmationDialog`), and import errors (`.alert`); this extends that convention.

## Design

### 1. Voice session failure → native alert on the library

Today the voice session is a `.fullScreenCover` (driven by
`VoiceSessionPresenter.isPresenting`); on failure `VoiceSessionHost` swaps its
whole body to `VoiceErrorView`. A native alert floats over content, so the
failure presentation moves up to where the cover is mounted (`SignedInView`).

- Introduce a pure value type in RishiVoice:

  ```swift
  public struct VoiceFailureAlert: Equatable {
      public enum PrimaryAction: Equatable { case openSettings, retry }
      public let title: String
      public let message: String
      public let primaryAction: PrimaryAction
      public init(reason: VoiceSessionFailureReason, message: String?)
  }
  ```

  It absorbs the title/body-copy/primary-action mapping currently inside
  `VoiceErrorView` (`.micDenied` → "Microphone access needed" + Open Settings;
  all other reasons → reason-specific title + Try again). Pure → unit-tested
  for every `VoiceSessionFailureReason` case (TDD).

- `VoiceSessionPresenter`: add `private(set) var failure: VoiceFailureAlert?`.
  Whenever the session transitions to `.failed(reason)` (both the synchronous
  `start()` catch path and the live-session/bridge path), route through a single
  `enterFailure(reason:)` that sets `failure` and `isPresenting = false` (tears
  down the cover without invoking the binding's `end()` setter — programmatic
  changes don't call the binding setter). `retry()` clears `failure` and restarts
  with the captured book context; a new `clearFailure()` clears it for Dismiss.

- `SignedInView`: attach a native `.alert` bound to `presenter.failure`. Buttons:
  primary ("Open Settings" → open Settings URL then `clearFailure()`, or "Try
  again" → `retry()`), plus a cancel "Dismiss" → `clearFailure()`. The Settings
  deep-link helper (`UIApplication.openSettingsURLString`) moves to the app layer
  (SignedInView can import UIKit).

- Delete `VoiceErrorView.swift`. `VoiceSessionHost.voiceContent` drops the
  `.failed` branch (cover unmounts on failure).

### 2. Reader cold-open failure → native alert that pops back

Both PDF and EPUB reader screens render `ReaderColdOpenFailureOverlay` in an
`.overlay` when `loadingState == .failed(reason)`. Replace with a shared view
modifier in RishiReader:

```swift
extension View {
    func readerColdOpenFailureAlert(
        bookTitle: String,
        reason: String?,        // non-nil drives presentation
        onDismiss: @escaping () -> Void
    ) -> some View
}
```

Alert title "Could not open \(bookTitle)", message = reason, single "OK" button
whose action calls `onDismiss`. Call sites pass `onDismiss: { dismiss() }`
(`@Environment(\.dismiss)`) to pop the reader from the NavigationStack — the
reader has no content to show when the open failed. The idle/loading
`ReaderColdOpenOverlay` stays unchanged. Delete `ReaderColdOpenFailureOverlay`
from both screens.

### 3. Delete-account → native destructive alert

`DeleteAccountFlow` is a `.sheet` with a custom two-step arm→confirm and an
inline error message. Replace with native alerts driven from the Settings row:

- Primary confirm: `.alert("Delete Account?", ...)` with `message` = the existing
  warning copy (what gets deleted, billing note, "cannot be undone"), a
  `.destructive` "Delete" button and a Cancel button. The native destructive
  button is itself the deliberate confirmation, so the custom two-tap arming is
  dropped (native idiom). Chosen over `.confirmationDialog` because the long
  warning renders reliably as an alert message on both iOS and Catalyst.
- On confirm, run the existing async `onDelete()`; on success `onDeleted()`.
- On failure, present a second `.alert("Couldn't delete your account", ...)` with
  the existing retry copy and an OK button (state is preserved; user can retry).

Delete `DeleteAccountFlow.swift` and its sheet presentation; the
arm/in-flight/error state collapses into Settings-level `@State` (or a thin
view-model) plus the two alert modifiers.

## Testing

- `VoiceFailureAlertTests` (Swift Testing): assert `title`, `message`, and
  `primaryAction` for every `VoiceSessionFailureReason` (incl. each
  `KeyFetchFailure` and the message-override path). Replaces the
  `VoiceErrorView`-construction cases in `VoiceUISnapshotTests`.
- Presenter behavior: `enterFailure` sets `failure` and flips `isPresenting`
  off; `retry()` and `clearFailure()` clear `failure`.
- Reader/Settings changes are thin view wiring; rely on the integrated build
  gate plus existing tests. Keep any extractable async delete logic testable.

## Build gate

Subagents typecheck per touched file (`xcrun --sdk iphonesimulator swiftc
-typecheck`) or `swift test` per non-Readium package; they do NOT run
`xcodebuild rishi`. The orchestrator runs the full `xcodebuild` (iPhone 17 +
Mac Catalyst) and greps for the literal `** BUILD SUCCEEDED **` marker as the
final gate.

## Out of scope / explicitly preserved

- Onboarding flow, mic/notification permission primers, welcome, sample/import,
  paywall, settings form, chat/voice full-screen hosts.
- `ReaderModalOverlay` and its Catalyst overlay workaround for TOC/theme/note sheets.
- The OS-owned system permission prompt (`AVAudioApplication.requestRecordPermission`).
