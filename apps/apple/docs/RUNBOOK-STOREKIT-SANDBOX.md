# StoreKit Sandbox Runbook

**Audience:** matovu90@gmail.com plus any QA operator who needs to validate the Rishi Reader / Rishi Voice subscription loop before a TestFlight push or App Review submission.
**Purpose:** validate the Reader/Voice subscription loop end-to-end against Apple's Sandbox environment.

Run this runbook BEFORE every TestFlight build and BEFORE each App Review submission. It is the only thing standing between "`swift test` green" and "a real subscription transacts end-to-end against Apple's verification chain."

This is a companion to [`WORKER-CONTRACT-IAP.md`](./WORKER-CONTRACT-IAP.md) — that doc specifies what the worker MUST do; this doc tells the human operator what to click.

---

## 0. Prerequisites

Confirm each item before moving on:

- [ ] You have App Store Connect access for `org.fidexa.rishi` (Admin or App Manager role).
- [ ] You have an Apple ID that is NOT signed into the App Store on the test device. Sandbox testers must be entirely separate accounts — this is Apple's restriction, not ours.
- [ ] The Rishi product IDs are registered in App Store Connect (see §1). If they are not, complete §1 once and skip it on subsequent runs.
- [ ] The build is either (a) signed with the Distribution profile and installed via TestFlight, or (b) running from Xcode against the `rishi (Sandbox)` scheme on a real device.
- [ ] Sandbox tester credentials are available in the `#ios-billing` Slack channel. DO NOT commit credentials to git — Apple-issued sandbox passwords are credentials.
- [ ] The worker is reachable at the env-configured `WORKER_BASE_URL` (verify with a `curl` against `/api/health` or the equivalent ping route).

---

## 1. App Store Connect Product Setup (one-time)

This is a per-product one-time configuration. Skip if §0 confirmed the products are already registered.

1. Sign in to App Store Connect → **Apps** → `org.fidexa.rishi` → **In-App Purchases** (Subscriptions).
2. **Subscription Group:** click **+** → name `Rishi Reader & Voice` → reference name `rishi-reader-voice-group`.
3. Inside the group, create four auto-renewable subscriptions (Voice rank 1 / higher, Reader rank 2 / lower — matches StoreKit group numbers):

   | Product ID                          | Reference Name         | Duration | Price (US) |
   | ----------------------------------- | ---------------------- | -------- | ---------- |
   | `org.fidexa.rishi.voice.monthly`    | Rishi Voice Monthly    | 1 month  | $14.99     |
   | `org.fidexa.rishi.voice.annual`     | Rishi Voice Annual     | 1 year   | $143.99    |
   | `org.fidexa.rishi.reader.monthly`   | Rishi Reader Monthly   | 1 month  | $7.99      |
   | `org.fidexa.rishi.reader.annual`    | Rishi Reader Annual    | 1 year   | $76.99     |

4. For each product configure an introductory offer if required by current pricing policy (otherwise skip).
5. Fill in the App Store Information localizations (English at minimum).
6. Add a Review Note for each product pointing the App Review team at the runbook's §10 checklist.
7. Status: leave at **Ready to Submit**. Apple ties subscription review to app review — submit when the app build is submitted.

> Product **IDs are LOCKED** — they MUST match `RishiProductID` in `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Models/RishiProductID.swift`, the worker map in `workers/worker/src/billing/apple-product-plans.ts`, and `apps/apple/rishi/Rishi Reader.storekit`. Legacy `org.fidexa.rishi.pro.*` ids are grandfathered for existing subscribers only; do **not** create new Pro products.

Verify: all four Reader/Voice products appear in the IAP list with status `Ready to Submit`, grouped under `Rishi Reader & Voice`.

---

## 2. Create a Sandbox Tester

Each tester can be reused across runs but starts each subscription fresh. To reset a tester mid-cycle, see §9.

1. App Store Connect → **Users and Access** → **Sandbox Testers** → **+** (Add Tester).
2. **First / Last name:** anything. Use `Rishi QA` to make logs greppable.
3. **Email:** a real email you control that is NOT an existing Apple ID. Apple will send a verification email — complete it from a browser before continuing.
4. **Password:** any compliant password.
5. **Storefront:** United States (USD) for the default runbook flow. If you need to validate a non-USD currency, create a second tester with that storefront.
6. **Date of birth:** any adult.
7. Tap **Create**.
8. Add the credentials to the `#ios-billing` Slack channel pinned message. Do not paste them anywhere in this repo.

Verify: the tester appears in the Sandbox Testers list. The first time you sign in on a device, Apple prompts a one-time terms acceptance — get that out of the way now.

---

## 3. Device / Simulator Setup

### 3.1 iOS Device (recommended path)

1. **Settings** → tap your name at the top → sign OUT of the production Apple ID first if one is active. Sandbox testers cannot be the device's primary Apple ID — only the App Store Sandbox account.
2. **Settings** → **Developer** → **Sandbox Apple Account** → sign in with the Sandbox tester from §2.
3. Build and run Rishi on the device from Xcode using the `rishi (Sandbox)` scheme (see §4).

### 3.2 iOS Simulator

1. Xcode → **Settings** → **Accounts** → **+** → **Apple ID** → sign in with the Sandbox tester.
2. Build and run Rishi on the simulator. The default `rishi` scheme uses the local `Rishi Reader.storekit` config — see §4 for the difference vs. real Sandbox.
3. NOTE: simulator IAP uses the LOCAL StoreKit config UNLESS you switch to the `rishi (Sandbox)` scheme. The local config is great for daily dev but does NOT exercise Apple's verification chain — for App Review pre-submission ALWAYS use the Sandbox scheme on a real device.

### 3.3 Mac Catalyst

1. **System Settings** → **Internet Accounts** does NOT manage Sandbox testers on macOS.
2. Build the `rishi (Sandbox)` scheme for **My Mac (Catalyst)**.
3. Launch; the first IAP attempt prompts an Apple ID sign-in sheet — sign in with the Sandbox tester there.

---

## 4. Xcode Scheme Selection

| Scheme            | StoreKit Config        | When to use                                                       |
| ----------------- | ---------------------- | ----------------------------------------------------------------- |
| `rishi` (default) | `Rishi Reader.storekit` (local) | Daily development — offline, fast, no ASC roundtrip               |
| `rishi (Sandbox)` | None — uses real ASC sandbox | This runbook (end-to-end Sandbox validation; App Review pre-flight) |

To create the Sandbox scheme (one-time, already wired in `rishi.xcodeproj` per Plan 13-01):

1. Xcode → **Product** → **Scheme** → **Manage Schemes**… → duplicate `rishi`.
2. Rename to `rishi (Sandbox)`.
3. **Edit Scheme** → **Run** → **Options** → **StoreKit Configuration** → **None**.
4. Mark the scheme **Shared** so the next operator's checkout picks it up.
5. Save and commit the updated `xcshareddata/xcschemes/rishi (Sandbox).xcscheme`.

Verify: the scheme dropdown in Xcode's toolbar shows both `rishi` and `rishi (Sandbox)`.

---

## 5. Happy-Path Smoke Test

> Run this for EVERY pre-submission check. Expected total time: under 90 seconds. If any step takes longer, capture logs (§12) and escalate before submitting.

1. Launch the Sandbox build (`rishi (Sandbox)` scheme) on the test device.
2. Sign into Rishi using Sign in with Apple — production user is fine; the Sandbox tester from §2 is only used for IAP, not app sign-in.
3. Tap any premium feature (Read Aloud, voice chat, or cross-device sync) → the paywall sheet presents.
4. Verify both tiers (Monthly + Annual) display with their localized prices from §1.
5. Tap **Subscribe** on Monthly. The Sandbox purchase sheet appears with a `[Environment: Sandbox]` header at the top — this is your confirmation you are not about to charge a real card.
6. Confirm purchase. Authenticate with the Sandbox tester credentials from §2 (Slack `#ios-billing`).
7. Verify the paywall dismisses and the premium feature is now accessible.
8. Verify the worker received `POST /api/billing/verify-receipt` with the JWS payload (check server logs; see [`WORKER-CONTRACT-IAP.md` §1](./WORKER-CONTRACT-IAP.md#1-endpoint-post-apibillingverify-receipt) for log format and request schema).
9. Verify `users.premium_until` was updated in the DB to a future timestamp matching the decoded JWS `expiresDate`.
10. Repeat steps 3–9 once for the **Annual** tier on a fresh tester (or after §9 cleanup) to confirm both products work.

Verify: paywall dismissed, premium feature unlocked, worker log shows a `verified: true` response, DB row updated.

---

## 6. Restore Path Validation

1. Force-quit the app. Sign out of Rishi (the app's Sign-in-with-Apple session, not the device).
2. Sign back in as the same Sign-in-with-Apple user from §5.
3. (Optional, recommended once per phase) Delete and reinstall the app from Xcode. Sandbox subscriptions persist across reinstall on the same tester.
4. Open the paywall → tap **Restore Purchases** (footer link).
5. Verify Apple ID password prompt appears (the Sandbox tester password).
6. Verify the paywall dismisses with a `.restored` confirmation banner.
7. Verify `EntitlementReconciler.level == .pro` (premium feature accessible without re-purchase).

Verify: no second charge sheet appeared, entitlement granted, worker did NOT receive a second `verify-receipt` call (restore uses on-device `Transaction.currentEntitlements` first).

---

## 7. Renewal Validation (accelerated time)

Sandbox renewals happen on an ACCELERATED CADENCE per Apple's intentional design. This is `13-RESEARCH.md` §10 Pitfall 11 — document it here so the next operator does not chase ghost bugs.

| Production duration | Sandbox duration |
| ------------------- | ---------------- |
| 1 week              | 3 minutes        |
| 1 month             | 5 minutes        |
| 2 months            | 10 minutes       |
| 3 months            | 15 minutes       |
| 6 months            | 30 minutes       |
| 1 year              | 1 hour           |

After 6 renewals, Sandbox stops auto-renewing — this is intentional (production renews until cancelled).

1. Complete §5 with the **Monthly** tier (5-minute renewal cadence).
2. Keep the app open. Wait 5 minutes by the wall clock.
3. Verify the `Transaction.updates` listener receives the renewal event. In Xcode Console, filter `subsystem == org.fidexa.rishi category == iap` — you should see `iap.update.granted_and_finished`.
4. Verify the worker receives a re-verification call (`POST /api/billing/verify-receipt` with a new `transactionId`).
5. Verify `users.premium_until` advances by one month per renewal in DB.
6. Verify Apple posts a `DID_RENEW` notification to the worker ASSN V2 webhook within ~30s of the renewal (see [`WORKER-CONTRACT-IAP.md` §2](./WORKER-CONTRACT-IAP.md#2-webhook-app-store-server-notifications-v2)).

> Do NOT assume Sandbox renewal cadence matches production. Phase-13 acceptance documents this explicitly as RESEARCH §10 Pitfall 11.

Verify: at least one accelerated renewal logged in the iOS Console, one re-verify on the worker, one `DID_RENEW` on the webhook log.

---

## 8. Refund + Revoke Validation

Sandbox does NOT support self-service refunds via **Settings → Subscriptions**. Use one of two paths:

**Path A — App Store Connect Refund Test (preferred, exercises the real chain):**

1. App Store Connect → **Users and Access** → **Sandbox Apple Account** → select your tester → **Edit Subscription Renewal Preferences** → set renewal to **OFF**, or use the **Refund Test** option if available in your storefront.
2. Apple posts a `REFUND` ASSN V2 notification to the worker webhook within ~60s.

**Path B — Xcode Debug Refund (faster, only works on the local `.storekit` config, NOT the Sandbox scheme):**

1. Run the **default** `rishi` scheme (local `Rishi Reader.storekit`, NOT `rishi (Sandbox)`).
2. Xcode → **Debug** → **StoreKit** → **Manage Transactions** → select the active transaction → **Refund Purchase**.
3. This exercises iOS-side handling but does NOT hit the worker webhook — useful for unit-level smoke; not sufficient for App Review pre-flight.

For App Review pre-submission, ALWAYS use Path A. Document which path you ran when filing results in §12.

Verify (Path A) — all four must hold:
- `Transaction.updates` listener receives the refund event with `revocationDate != nil`. Console log: `iap.update.revoked`.
- `EntitlementReconciler` drops the user back to `.free` (premium feature gated again).
- The worker received an ASSN V2 `REFUND` notification (see [`WORKER-CONTRACT-IAP.md` §2.3](./WORKER-CONTRACT-IAP.md#23-handling)).
- `users.premium_until = now()` in DB.

---

## 9. Reset / Cleanup Between Runs

To start a fresh run with the same Sandbox tester:

1. **Settings** → **Developer** → **Sandbox Apple Account** → sign out.
2. App Store Connect → **Sandbox Testers** → tap your tester → **Clear Purchase History**.
3. Wait 60 seconds for ASC propagation.
4. Sign back in on the device and run §5 again.

If purchase history persists despite clearing, file a Feedback Assistant report (this is an Apple-side known issue circa 2026) and spin up a fresh tester per §2.

---

## 10. App Review Pre-Submission Checklist

Run all of the following before tapping **Submit for Review** in ASC. This is the one-page checklist a QA operator can copy-paste into the App Review submission notes.

```text
[ ] §5 happy path completes in < 90 s on iPhone + iPad + Mac Catalyst.
[ ] §6 restore returns the user to .pro on a fresh install.
[ ] §7 sees at least one accelerated renewal logged on the worker side.
[ ] §8 (Path A) refund drops the user back to .free within 60 s.
[ ] `bash apps/apple/scripts/check-anti-steering.sh` exits 0
    (no forbidden strings in app sources — Guideline 3.1.1).
[ ] `bash apps/apple/scripts/check-entitlements-unchanged.sh` exits 0
    (no deprecated `com.apple.developer.in-app-payments` entitlement).
[ ] Settings → Subscription Terms / Privacy Policy / Terms of Use links
    all open in SFSafariViewController (NOT external browser).
[ ] Paywall body contains the 3.1.2 disclosure copy verbatim
    (auto-renews / cancel anytime / trial duration / what user gets).
[ ] Manage Subscription opens the in-app
    `AppStore.showManageSubscriptions(in:)` sheet (NOT an external URL,
    NOT the legacy web portal removed in Phase 13).
[ ] All subscription products in ASC are in "Ready to Submit" status.
[ ] App Review notes include a sandbox tester credential reference
    pointing the reviewer at the team's ASC sandbox testers list.
```

Capture the output of the two shell scripts and attach to the App Review submission notes.

---

## 11. Known Gotchas

- Sandbox testers CANNOT be your primary Apple ID. They are entirely separate accounts.
- The `[Environment: Sandbox]` header on the purchase sheet is your confirmation you are NOT charging a real card. If you see `[Environment: Production]`, **STOP** — verify the Sandbox tester is signed in correctly via §3.
- Sandbox subscriptions DO renew automatically up to 6 times without user action. This is intentional. Production renews until cancelled.
- Two sandbox testers cannot share the same email — Apple's deduplication is per-email, even across teams.
- After clearing purchase history (§9), wait the full 60s before retrying — clearing too soon causes confusing "subscription already active" prompts.
- A Sandbox tester's storefront determines the currency the purchase sheet displays. Plan for at least one non-USD tester before App Review.

---

## 12. Escalation

If any step in §5–§8 fails after retrying with a fresh tester (§9):

1. Capture iOS Console logs filtered to `subsystem == org.fidexa.rishi category == iap`.
2. Capture worker logs for the `/api/billing/verify-receipt` calls in the test window. See [`WORKER-CONTRACT-IAP.md` §1.5](./WORKER-CONTRACT-IAP.md#15-error-reasons-canonical-strings-ios-surfaces-these-as-logs) for the canonical `reason` enum.
3. Capture Xcode → **Debug** → **StoreKit** → **Manage Transactions** screenshot.
4. Capture a screenshot of the ASC product page showing the product status.
5. File in `#ios-billing` Slack with the above four attachments, the build number, the device model + iOS version, and the Sandbox tester email used.

---

## 13. DEBUG stub verifier (offline / pre-deploy testing)

Phase 14 plan 14-07 adds `DebugStubReceiptVerifier`, a `#if DEBUG`-gated
actor that returns `verified: true` with `premiumUntil = now + 30 days`
without contacting the worker. Use this when the worker is unreachable
or not yet deployed, but you still need to exercise the iOS IAP flow.

### Activate (simulator)

Run BOTH commands — the StoreKit feature flag turns the IAP graph on,
the stub flag swaps the verifier:

```bash
defaults write org.fidexa.rishi StoreKitIAPFlag -bool YES
defaults write org.fidexa.rishi RishiUseStubReceiptVerifier -bool YES
```

Relaunch the app. The graph wires `DebugStubReceiptVerifier` in
`AppDependencies` and emits `iap.verifier.stub.enabled` at .info.

### Deactivate

```bash
defaults delete org.fidexa.rishi RishiUseStubReceiptVerifier
```

(Leave `StoreKitIAPFlag` ON unless you also want the IAP graph dormant.)

### Compile-strip guarantee

The entire `DebugStubReceiptVerifier.swift` source file and the
corresponding branch in `AppDependencies.swift` are wrapped in `#if DEBUG`.
Release builds emit a zero-symbol object for the stub — it physically
cannot ship to TestFlight or the App Store. Pattern mirrors Phase 3's
`DevBypassConfig`.

A future CI step (`nm .build/release/RishiBilling.o | grep DebugStub`
must return empty) is tracked as deferred in `14-07-SUMMARY.md`.
