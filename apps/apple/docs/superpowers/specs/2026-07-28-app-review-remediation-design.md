# App Review Remediation Design

> **Status:** Design approved by the user’s compliance-first direction.

## Goal

Make the next Rishi Apple submission address all reported rejection findings: the unsupported background-audio declaration, the microphone permission pre-prompt wording, and the subscription screen that failed to load in App Review.

## Decisions

1. Remove `audio` from `UIBackgroundModes`. Rishi’s submitted feature set does not need persistent background playback for voice chat, and the review feedback explicitly says to remove the declaration when persistent audio cannot be demonstrated. Foreground Read Aloud remains supported; background playback is out of scope for this resubmission.
2. Keep native StoreKit 2 subscriptions. The active app already presents `SubscriptionStoreView` and the worker already verifies the current Reader/Voice products through `entitlement-sync`. The fix is to make catalog loading observable and recoverable, ensure the paywall uses the validated subscription group/catalog, and verify the App Store Connect records in the reviewed storefront.
3. Rename both custom microphone pre-prompt actions to `Continue`. The system permission sheet remains the only place that asks the user to Allow or Don’t Allow microphone access. Denial must leave the user with a usable app and a Settings recovery path when voice chat is attempted later.
4. Treat App Store Connect as the production catalog authority. The local `.storekit` file remains a development fixture and must not be used as evidence that products are available to App Review.

## Architecture and data flow

`SubscriptionsView` will consume one shared StoreKit catalog state owned by `Store`: loading, loaded, empty/unavailable, or failed-with-retry. The catalog provider will request only the current platform’s allow-listed product IDs, reject missing/partial responses for the paywall, and expose the validated subscription group ID. Purchase and restore continue through the existing StoreKit 2 transaction/JWS → worker `POST /api/billing/entitlement-sync` → entitlement refresh flow.

`MicPermissionPrimer` and `VoicePermissionPrompt` will share the same neutral rationale and `Continue` action semantics. `OnboardingHost` will request permission only after the action; onboarding will record the resulting decision rather than treating denial as a grant. Existing permission-gate behavior will remain the authority for later voice-chat starts.

## Error handling

- StoreKit request failure, empty results, or a partial catalog produce a visible unavailable state with Retry; purchase controls are not shown for missing products.
- Restore is user initiated and uses the existing restore service/transaction walk, not an opportunistic `AppStore.sync()` call.
- A denied microphone permission does not block reading. Starting voice chat later shows the existing Settings recovery guidance when iOS will not present the prompt again.
- No background audio claim remains in the archive or review notes.

## Verification

- Run the Apple project build/tests against an available iPad simulator.
- Run focused StoreKit, onboarding, and microphone tests through the actual `rishiTests` target.
- Run worker billing tests with Bun and add/update only tests needed for the active Apple product/ownership behavior.
- Archive Release, inspect the generated `Info.plist`, and verify `UIBackgroundModes` no longer contains `audio`.
- Test the real App Store Connect Sandbox/TestFlight storefront on an iPad Air-class device: paywall load, purchase, restore, and failed/unavailable catalog recovery.
- Record fresh review notes that describe the uploaded Release archive and do not mention DEBUG bypasses or external subscription purchase.

## Out of scope

- Implementing persistent background playback for this submission.
- Replacing StoreKit, AVFoundation, WebRTC, or the worker entitlement model.
- Adding new subscription products or changing prices/entitlements.
- Switching to web-managed billing.
