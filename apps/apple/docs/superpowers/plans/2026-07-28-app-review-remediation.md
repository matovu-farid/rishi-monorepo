# App Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Rishi Apple submission internally consistent and App Review-ready for the reported subscription, background audio, microphone permission, and subscription-loading issues.

**Architecture:** Keep native Apple auto-renewable subscriptions through `SubscriptionStoreView`; App Store Connect is the authoritative product catalog and the local `.storekit` files are test fixtures only. Centralize legal URLs and subscription identity data, expose product-loading failures to the paywall, keep background audio only for user-initiated Read Aloud playback, and make the final Release archive the source of truth for review notes and validation.

**Tech Stack:** Swift 6, SwiftUI, StoreKit 2, AVFoundation, WebRTC, XCTest/Swift Testing as already configured, Xcode 16.4, Fastlane, App Store Connect Sandbox.

---

## Scope And Decisions

- Native Apple IAP remains enabled for this submission. Do not use website subscription links as the purchase path unless the Reader App entitlement is separately approved and the binary is intentionally changed to remove native IAP.
- The canonical legal URLs are `https://rishi.fidexa.org/terms`, `https://rishi.fidexa.org/legal/subscription-terms`, and `https://rishi.fidexa.org/privacy`; the first and third were verified as final HTTPS destinations, while `/legal/subscription-terms` is the dedicated subscription policy page.
- `rishi.reader.monthly` must be verified directly in App Store Connect. It is retained only if that exact ID is the live product ID; otherwise migrate every client, worker, webhook, test, and fixture reference to the confirmed ID.
- The `audio` background mode is removed for this submission because persistent background playback was not part of the reviewable product flow and Apple could not verify it.
- No developer bypass, DEBUG-only access path, or inaccessible review credential may be required to exercise the submitted Release build.

## File Map

- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/Store.swift` for observable product/group-loading state and diagnostics.
- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift` for canonical legal policy destinations, group-based paywall wiring, visible subscription disclosures, and product-load recovery.
- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Models/RishiProductID.swift` only if App Store Connect confirms an ID migration is required.
- Modify `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/UI/VoicePermissionPrompt.swift` and `apps/apple/rishi/rishi/Modules/RishiOnboarding/RishiOnboarding/UI/MicPermissionPrimer.swift` for permission-copy compliance.
- Modify `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/Coordinator/AudioSessionCoordinator.swift` and `apps/apple/rishi/rishi/Modules/swift-realtime-openai/WebRTC/WebRTCConnector.swift` to remove competing AVAudioSession ownership and make failure behavior explicit.
- Modify `apps/apple/rishi/rishi/Info.plist` and the Release settings in `apps/apple/rishi/rishi.xcodeproj/project.pbxproj` only after confirming the generated archive’s privacy keys.
- Modify `apps/apple/fastlane/metadata/en-US/description.txt`, `release_notes.txt`, `fastlane/metadata/review_information/notes.txt`, and `phone_number.txt` to match the Release binary and include the EULA link.
- Modify `apps/apple/fastlane/scripts/validate_metadata.rb` to validate the EULA URL and reject placeholder review contact data.
- Modify `apps/apple/rishi/Rishi Reader.storekit` and the test StoreKit fixture only after App Store Connect verification and the approved subscription matrix are recorded.
- Add or update billing, permission, audio, and metadata validation tests in the existing Apple test targets without replacing StoreKit, AVFoundation, Readium, PDFKit, or WebRTC.
- Update `apps/apple/docs/APP-STORE-METADATA.md` and `apps/apple/docs/RUNBOOK-STOREKIT-SANDBOX.md` with the final workflow and stop-submission gates.

## Implementation Tasks

### Task 1: Establish The Authoritative Billing And Legal Matrix

**Files:**
- Modify: `apps/apple/docs/APP-STORE-METADATA.md`
- Modify: `apps/apple/docs/RUNBOOK-STOREKIT-SANDBOX.md`
- Review: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Models/RishiProductID.swift`
- Review: `apps/apple/rishi/Rishi Reader.storekit`
- Review: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/Resources/Rishi.storekit`

- [ ] Confirm in App Store Connect that the Paid Apps Agreement, tax/banking setup, bundle ID `org.fidexa.rishi`, subscription group `rishi-reader-voice-group`, product statuses, storefront availability, localizations, review screenshots, and prices are valid for the submitted iOS app.
- [ ] Record the exact four iOS product IDs, prices, durations, trial rules, entitlement levels, and allowances in the runbook. Resolve the `$76.99`/`$79.99` and `180/90` versus `540/270` conflicts before touching fixtures or copy.
- [ ] Confirm whether `rishi.reader.monthly` is the exact live App Store Connect ID. If not, create a migration task covering the Swift client, worker mappings, webhook handling, entitlement mapping, tests, and both StoreKit fixtures.
- [ ] Select one canonical general-terms URL and one canonical subscription-terms URL. Verify HTTPS, HTTP success, no authentication, no redirect to a purchase page, and content covering auto-renewal, price, trial conversion, cancellation, renewal, restore, and refunds.
- [ ] Add a visible subscription legal block to the metadata runbook containing the exact Terms of Use, Subscription Terms, and Privacy Policy URLs.
- [ ] Mark unresolved product, legal, price, allowance, agreement, and contact checks as submission blockers rather than assumptions.

**Verification:** The completed matrix must be sufficient to compare App Store Connect, source code, worker entitlement mapping, local fixtures, app copy, and review notes without interpretation.

### Task 2: Align StoreKit Loading And Paywall Failure Handling

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/Store.swift`
- Modify: `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`
- Modify: `apps/apple/rishi/rishi/CurrentViewModifier.swift` if required by the existing error-observer API
- Test: existing `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/` tests

- [ ] Write tests for successful loading, StoreKit request failure, empty results, partial results, retry, and the exact requested/returned product ID sets using the active `Store` implementation rather than the commented-out `StoreKitProductService`.
- [ ] Introduce a small injectable product/group provider around the active `Product.products(for:)` and subscription-group lookup calls, with the production implementation delegating directly to StoreKit. Use the provider in `Store` so failure, empty, partial, and retry behavior can be tested without relying on a live App Store account.
- [ ] Update `Store.loadProducts()` so failures assign a typed observable error, empty results are not treated as success, stale products are not presented as current, and retries are safe. Preserve the fetched subscription group ID as state for the group-based paywall.
- [ ] Preserve the existing platform split: iOS requests the four non-`.macos` IDs and Catalyst requests only the four `.macos` IDs.
- [ ] Change `SubscriptionsView` and every consumer that presents it to use the fetched App Store subscription group ID through the approved `SubscriptionStoreView(groupID:)` path; keep product IDs as the explicit allow-list used for validation and fallback diagnostics. Audit `RootView.swift`, `SettingsContent.swift`, `LibraryTabView.swift`, and any entitlement gate that currently checks group availability.
- [ ] Make the subscription surface show a loading state, a recoverable unavailable state with retry, and the loaded products. Do not show a purchase button for a missing product.
- [ ] Add visible purchase disclosure copy near the purchase controls covering the selected plan price and billing period, auto-renewal, trial conversion if present, cancellation through Apple account settings, restore purchases, and links to Terms of Use, Subscription Terms, and Privacy Policy. Keep dynamic price/period values sourced from StoreKit rather than hard-coded.
- [ ] Log the requested and returned IDs plus the StoreKit error category in Release-safe diagnostics; never log credentials or receipt contents.
- [ ] Keep `SubscriptionStoreView` policy destinations pointed to the canonical legal URLs selected in Task 1.
- [ ] Run the focused billing package tests and ensure tests no longer depend on the disabled legacy product service.

**Verification:** Provider tests cover all load states; a simulated or real empty StoreKit response produces a clear retryable state instead of the reviewer-visible blank/unavailable sheet; a complete response supplies the group ID and renders both monthly and annual plans with the required disclosure.

### Task 3: Correct Product Identity And Local StoreKit Fixtures

**Files:**
- Modify if required: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Models/RishiProductID.swift`
- Modify if required: `apps/apple/rishi/Rishi Reader.storekit`
- Modify if required: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/Resources/Rishi.storekit`
- Modify if required: worker product mapping files identified by repository search
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/StoreKitConfigTests.swift`

- [ ] Compare every product ID and subscription group ID in source, worker mappings, App Store Connect, and both fixtures against the Task 1 matrix.
- [ ] Remove duplicate or structurally inconsistent product records from the development fixture; retain legacy Pro records only if existing subscribers require them and ensure they cannot appear in the current paywall.
- [ ] Make fixture prices, periods, descriptions, group IDs, and policy URLs match the approved matrix. Do not use the local fixture as evidence that App Store Connect is configured.
- [ ] Add a test that rejects an unknown or legacy product ID from granting a current entitlement.
- [ ] Add a test that proves the iOS catalog never requests Catalyst IDs and the Catalyst catalog never requests iOS IDs.
- [ ] Verify the shared `rishi (Sandbox)` scheme has StoreKit Configuration set to `None`; the default development scheme may retain the local fixture.
- [ ] Create and commit `apps/apple/rishi/rishi.xcodeproj/xcshareddata/xcschemes/rishi (Sandbox).xcscheme` by duplicating the shared `rishi` scheme, setting Run → Options → StoreKit Configuration to `None`, and marking it shared. Do not claim this scheme exists until the file is present and `xcodebuild -list` shows it.

**Verification:** The exact IDs requested by the Release binary are byte-for-byte present and available in App Store Connect for the reviewed platform.

### Task 4: Align Permission UX And Privacy Disclosures

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiOnboarding/RishiOnboarding/UI/MicPermissionPrimer.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/UI/VoicePermissionPrompt.swift`
- Modify: `apps/apple/rishi/rishi.xcodeproj/project.pbxproj` or `apps/apple/rishi/rishi/Info.plist` for the final microphone usage string
- Review and update: `apps/apple/fastlane/metadata/app_privacy.json`
- Review and update: the public privacy policy outside this repository if its disclosures are incomplete
- Test: the existing onboarding and voice permission tests/UI tests

- [ ] Replace both custom pre-prompt action labels `Allow microphone` with `Continue` or `Enable microphone`; use `Continue` because the following system dialog independently asks the user to Allow or Don’t Allow.
- [ ] Make both rationales use the same accurate statement about active voice-chat capture, transmission destination, retention, and the activation buffer if capture begins before WebRTC connects.
- [ ] Keep the system `NSMicrophoneUsageDescription` semantically aligned with the in-app rationale and verify it in the generated Release archive, not only the source plist/settings.
- [ ] Test fresh install, grant, deny, previously denied, Settings recovery, and voice-chat start without permission on physical iOS/iPadOS devices.
- [ ] Remove camera or speech-recognition purpose strings only if source and product review confirm those features are not shipped; otherwise document and test the corresponding flows.
- [ ] Reconcile App Store privacy answers and the public privacy policy with microphone audio, book content, chat data, identifiers, diagnostics, retention, deletion, third-party processing, and model-training behavior.
- [ ] Treat microphone-audio retention, deletion, provider processing, and model-training disclosures as an explicit manual privacy-policy and App Store Connect blocker; source review establishes direct OpenAI transport and Rishi transcript persistence, but does not establish provider audio-retention behavior.

**Verification:** No custom button claims to grant permission, the system prompt follows the rationale, and all privacy declarations describe the actual production data flow.

### Task 5: Make Background Audio Deliberate And Reviewable

**Files:**
- Review/modify: `apps/apple/rishi/rishi/Info.plist`
- Modify: `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/Coordinator/AudioSessionCoordinator.swift`
- Modify: `apps/apple/rishi/rishi/Modules/swift-realtime-openai/WebRTC/WebRTCConnector.swift`
- Review: `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/TTS/ChunkedAudioPlayerTTSEngine.swift`
- Review: `apps/apple/rishi/rishi/Modules/RishiAudio/RishiAudio/TTS/NowPlayingController.swift`
- Test: existing RishiAudio and voice tests; add physical-device acceptance evidence

- [ ] Confirm that Read Aloud is a user-initiated, audible background feature and that the production path sets `.playback`/`.spokenAudio`, publishes Now Playing metadata, and supports lock-screen controls.
- [ ] Route all global AVAudioSession category, mode, activation, and deactivation changes through `AudioSessionCoordinator`; leave WebRTC responsible for its audio unit rather than reconfiguring the process-global session.
- [ ] Remove or correct direct WebRTC activation options that are inappropriate for activation. Change the coordinator API used by `RealtimeVoiceSession` and the Read Aloud owner to return a typed success/failure result (or throw a typed error), then map that result to the existing voice/read-aloud presentation layer with a retry/settings recovery action. Add a test using the existing configurator test double that proves activation failure reaches the owner instead of being logged and ignored.
- [ ] Ensure voice chat does not keep microphone capture or an idle background audio session alive when the app backgrounds unless persistent voice chat is an explicitly supported product feature.
- [ ] On a physical iPhone and iPad, start Read Aloud, background and lock the device, verify audible continuation and Now Playing controls, then stop and verify session release. Test route changes, AirPods disconnect, phone interruption, and foreground/background transitions.
- [ ] If the physical-device test fails, remove `audio` from `UIBackgroundModes` and remove background-audio claims from metadata rather than submitting the declaration without a functional feature.
- [ ] Add the successful reviewer navigation and expected behavior to the final review notes.

**Verification:** The decision to retain or remove `UIBackgroundModes=audio` is backed by a physical-device pass/fail record for the exact Release archive.

### Task 6: Align App Store Metadata, Legal EULA, And Review Access

**Files:**
- Modify: `apps/apple/fastlane/metadata/en-US/description.txt`
- Modify: `apps/apple/fastlane/metadata/en-US/release_notes.txt`
- Modify: `apps/apple/fastlane/metadata/review_information/notes.txt`
- Modify: `apps/apple/fastlane/metadata/review_information/phone_number.txt`
- Modify: `apps/apple/fastlane/scripts/validate_metadata.rb`
- Modify: `apps/apple/docs/APP-STORE-METADATA.md`

- [ ] Add the functional Terms of Use/EULA URL to the App Store description, alongside the canonical subscription terms and privacy URLs.
- [ ] Remove website-managed subscription claims unless they are legal-only links and do not direct users to purchase outside Apple IAP.
- [ ] Describe native StoreKit subscription purchase, restore, and manage-subscription behavior accurately. Use the final product names, prices, periods, and allowance matrix.
- [ ] Rewrite review notes for the actual Release archive: no DEBUG claim, no unavailable Developer Bypass, no claim that IAP UI is absent, and exact navigation to free features, the paywall, microphone flow, Read Aloud, and legal pages.
- [ ] Replace `+1 555 0100` with a monitored, reachable review phone number.
- [ ] Extend metadata validation to require a configured Terms of Use/EULA URL and reject known placeholder phone patterns such as `555`, `000`, or empty values.
- [ ] Add URL validation that checks HTTPS and successful response where network access is available; keep a manual clean-device URL check as the final authority.
- [ ] Run anti-steering validation and ensure no forbidden subscription-purchase language remains in submitted metadata or review notes.

**Verification:** A reviewer following only the App Store listing and review notes can reach a working native subscription flow without a developer toggle or website purchase detour.

### Task 7: Validate The Exact Release Archive Before Resubmission

**Files:**
- Modify if needed: `apps/apple/fastlane/Fastfile`
- Modify if needed: `apps/apple/rishi/rishi.xcodeproj/xcshareddata/xcschemes/rishi (Sandbox).xcscheme`
- Review: final archive, generated `Info.plist`, entitlements, metadata, and App Store Connect record

- [ ] Run `bundle exec fastlane metadata_validate` from `apps/apple/`.
- [ ] Run the supported Apple test-target command for the checked-out project: `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)' test -only-testing:rishiTests`, or, if that destination is unavailable, use the installed iPad simulator destination reported by `xcrun simctl list devices available`. Record the exact command and result; do not describe nonexistent Swift package manifests as test targets.
- [ ] Build the exact Release archive used for upload with `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -configuration Release -destination 'generic/platform=iOS' -archivePath "$PWD/build/Rishi.xcarchive" archive`.
- [ ] Inspect the generated archive at `build/Rishi.xcarchive/Products/Applications/rishi.app/Info.plist` using `plutil -p`; confirm microphone usage text, `UIBackgroundModes`, URL schemes, and no unintended permission keys. If an IPA layout is also needed, export it with `xcodebuild -exportArchive` and inspect `Payload/rishi.app/Info.plist` separately.
- [ ] Inspect archive entitlements and confirm only the intended production capabilities are present.
- [ ] Install the exact archive on a clean physical iPhone and iPad.
- [ ] Run the real App Store Connect Sandbox flow with the shared `rishi (Sandbox)` scheme or TestFlight build, not the local `.storekit` scheme: paywall load, monthly purchase, annual purchase, restore, renewal/update, expiration/revocation, sign-out/sign-in, and fresh install.
- [ ] Confirm App Store Connect product records are `Ready to Submit`, attached to the app version, and include required localizations, pricing, availability, and review screenshots.
- [ ] Upload metadata and binary, manually inspect the App Store Connect preview, confirm the EULA link is functional in the description, and only then add the app and subscription products for review.
- [ ] Preserve the Sandbox test results, physical-device background-audio recording/logs, archive metadata inspection, and final review notes as the resubmission evidence.

**Stop condition:** Do not submit if any product is unavailable, any legal URL fails, the permission copy still says `Allow microphone`, background audio fails on physical hardware, the review notes do not match the archive, or any review contact is placeholder data.

## Consumer / Call-Site Audit

| Behavioral change | Consumers to verify |
|---|---|
| Product loading state/error | `SubscriptionsView.swift`, `CurrentViewModifier.swift`, `RootView.swift`, `SettingsContent.swift`, `LibraryTabView.swift` |
| Product IDs and entitlement mapping | `RishiProductID.swift`, `PurchaseService.swift`, `RestoreService.swift`, `EntitlementLevel.swift`, `EntitlementReconciler.swift`, worker Apple product map/webhook handlers, StoreKit fixtures |
| Legal URLs/EULA | `SubscriptionsView.swift`, Settings legal links, Mac Catalyst account/subscription UI, App Store description, App Store Connect custom EULA configuration |
| Microphone rationale | `MicPermissionPrimer.swift`, `VoicePermissionPrompt.swift`, `OnboardingHost.swift`, `SystemMicPermissionGate.swift`, generated `NSMicrophoneUsageDescription`, privacy policy, App Privacy answers |
| Audio session ownership | `AudioSessionCoordinator.swift`, `WebRTCConnector.swift`, `RealtimeVoiceSession.swift`, `ReadAloudController.swift`, TTS engine, Now Playing controller, background/scene lifecycle handlers |
| Review access | Release build configuration, `Fastfile`, review notes, Sign in with Apple path, Sandbox account instructions, free-feature path |

## Implementation Order

1. Complete Task 1 App Store Connect, legal, price, allowance, and product-ID decisions.
2. Complete Task 3 identity and fixture alignment, because all StoreKit code and tests depend on the matrix.
3. Complete Task 2 product loading and paywall error handling.
4. Complete Task 4 permission and privacy changes.
5. Complete Task 5 audio lifecycle and physical-device validation.
6. Complete Task 6 metadata, EULA, review notes, and contact validation.
7. Complete Task 7 exact-archive and App Store Connect submission validation.

## Explicitly Out Of Scope

- Switching the app to website-managed subscriptions without a separate approved Reader App entitlement and a new product decision.
- Replacing StoreKit, AVFoundation, Readium, PDFKit, WebRTC, or the existing TTS engine.
- Broad billing or audio architecture refactors unrelated to the rejection findings.
- Adding new subscription tiers or changing entitlement economics beyond resolving existing inconsistencies.
- Submitting or committing credentials, Sandbox passwords, receipts, or private App Store Connect data.

## Adversarial Review Loop

Each round: review the current artifact independently, log findings, update the plan, then re-review the updated plan.

### Round 1 — Research Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | Review notes and listing copy deny native IAP while `SubscriptionStoreView` is reachable in the Release app. | Task 1 fixes the model first; Task 6 rewrites all metadata and review instructions from the exact archive. |
| 2 | Critical | App Store Connect product availability is not proven by local `.storekit` files. | Task 1 makes App Store Connect authoritative; Task 7 requires real Sandbox/TestFlight validation and product-status checks. |
| 3 | High | EULA strategy and functional URL are missing or inconsistent. | Scope decisions select standard/custom EULA; Task 6 adds the description link, App Store Connect configuration, canonical in-app links, and URL checks. |
| 4 | High | `rishi.reader.monthly` may be an identity mismatch. | Task 1 requires direct ASC confirmation; Task 3 updates every consumer if migration is necessary. |
| 5 | High | Prices and allowances disagree across ASC docs, fixtures, and product copy. | Task 1 creates one approved matrix; Tasks 3 and 6 reconcile all consumers before submission. |
| 6 | High | `UIBackgroundModes=audio` lacks physical-device evidence. | Task 5 requires a physical iPhone/iPad test and makes removal the fallback if the feature fails. |
| 7 | High | Microphone pre-prompt button says `Allow microphone`. | Task 4 changes both pre-prompts to `Continue`/`Enable microphone` and tests grant/deny/recovery. |
| 8 | High | Review contact is a placeholder and notes describe DEBUG-only access. | Task 6 replaces the contact and removes inaccessible Release instructions. |

**Round 1 result:** Re-review required while the plan was being drafted; all Critical/High findings have explicit tasks, owners, and stop conditions in the updated artifact.

### Round 2 — Plan Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Product-loading changes could update the active `Store` while stale tests still target the commented-out `StoreKitProductService`. | Task 2 explicitly requires tests against active `Store` and removal of stale-path dependence before verification. |
| 2 | High | Audio fixes could preserve two global AVAudioSession owners. | Task 5 explicitly audits `WebRTCConnector` and requires coordinator-only global session configuration. |
| 3 | High | Legal links could be fixed in the paywall but remain inconsistent in Settings, Catalyst, or metadata. | The consumer/call-site audit names all legal-link consumers; Task 1 selects canonical URLs and Task 6 validates all entry points. |
| 4 | High | A local fixture could still mask a missing App Store Connect product. | Task 3 separates fixtures from authority; Task 7 requires the real Sandbox/TestFlight flow with StoreKit configuration disabled. |
| 5 | High | Review notes could still describe a different archive than the one uploaded. | Task 6 rewrites notes only after the Release archive exists; Task 7 requires archive-level inspection and clean-device execution. |

**Round 2 result:** Re-review required. The independent reviewer identified missing group-based paywall wiring, an untestable active StoreKit loader, absent visible subscription disclosures, a nonexistent Sandbox scheme, an invalid archive inspection path, unspecified test commands, and underspecified audio error propagation.

### Round 3 — Re-review After Plan Corrections

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Group-based subscription presentation was missing from the original plan. | Task 2 now requires fetched group ID state, `SubscriptionStoreView(groupID:)`, and audits all presentation consumers. |
| 2 | High | Active StoreKit failure paths were not testable. | Task 2 now requires an injectable provider around StoreKit calls and provider-backed tests for all load states. |
| 3 | High | Legal links alone did not guarantee visible subscription disclosures. | Task 2 now requires dynamic price/period disclosure near purchase controls, including auto-renewal, cancellation, restore, and legal links. |
| 4 | High | The Sandbox scheme was referenced but absent. | Task 3 now creates and commits the shared `rishi (Sandbox).xcscheme` with StoreKit configuration set to `None`. |
| 5 | High | The archive path was not valid for an `.xcarchive`. | Task 7 now specifies the archive’s `Products/Applications/rishi.app/Info.plist` path and the separate IPA export path. |
| 6 | High | Test/build commands were vague or referred to nonexistent package manifests. | Task 7 now specifies the Xcode test-target command, fallback destination discovery, and Release archive command. |
| 7 | High | Audio-session failure propagation had no API shape or UI consumer. | Task 5 now requires a typed coordinator result/error, owner mapping, and a failure propagation test. |

**Round 3 result:** PASS — 0 open Critical/High issues in the updated plan. The build-first gate was inconclusive because no Apple package manifests exist and isolated file typechecking lacks target dependencies; the integrated Xcode test/archive command in Task 7 is therefore a mandatory implementation gate, not a pre-validated result.

## Final Acceptance Criteria

- App description contains a functional Terms of Use/EULA link and canonical subscription terms link.
- App Store Connect custom EULA is configured if a custom EULA is selected.
- Native StoreKit subscription UI loads products in the real App Review/Sandbox storefront.
- Monthly and annual products have matching IDs, prices, durations, localizations, availability, and entitlement mappings.
- Product-loading failures produce a retryable user-visible state.
- No permission pre-prompt button says `Allow microphone`.
- Microphone rationale, system usage string, privacy policy, and App Privacy answers describe actual capture/transmission/retention behavior.
- Background Read Aloud either passes physical-device background playback validation or the `audio` background mode is removed.
- Review notes match the exact Release archive and do not require DEBUG bypasses.
- Review phone number is reachable and non-placeholder.
- Metadata validation, focused tests, Release archive inspection, clean-device checks, physical-device audio checks, and real Sandbox subscription checks all pass.
