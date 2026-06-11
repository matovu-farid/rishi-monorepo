# Billing Worker Runbook — Apple IAP Backend

**Audience:** matovu90@gmail.com plus any operator deploying or troubleshooting the Phase 14 Apple IAP backend.
**Purpose:** stand up `workers/worker/` for Apple IAP from a clean state, register the ASC webhook, run a sandbox smoke, and troubleshoot the common production incidents.

Companion to [`RUNBOOK-STOREKIT-SANDBOX.md`](./RUNBOOK-STOREKIT-SANDBOX.md) — that doc tells you how to drive the iOS Sandbox flow; this doc tells you how to bring the worker behind it up and how to diagnose when the chain breaks.

Companion to [`WORKER-CONTRACT-IAP.md`](./WORKER-CONTRACT-IAP.md) — that doc is the cross-team contract; this doc is operations.

> All endpoints live on `api.fidexa.org` (the Cloudflare Worker custom domain — see `workers/worker/wrangler.jsonc`). `rishi.fidexa.org` is the marketing site and never serves billing traffic.

---

## 0. Prerequisites

Confirm before continuing:

- [ ] Cloudflare account access with `wrangler` CLI authenticated (`pnpm exec wrangler whoami` returns the Rishi account).
- [ ] App Store Connect access for `org.fidexa.rishi` with the Admin or App Manager role.
- [ ] An ASC API key issued from **Users and Access > Integrations > App Store Connect API** — Key ID + Issuer ID + the downloaded `.p8` private key file.
- [ ] Sandbox tester credentials available from `RUNBOOK-STOREKIT-SANDBOX.md` §2.
- [ ] Node + pnpm at the repo-pinned versions (`pnpm@10.22.0` — Release CI pin, see `project_pnpm_pin.md`).
- [ ] You are on the `main` branch with a clean working tree.

---

## 1. One-time Setup

### 1.1 D1 migration (local then remote)

Phase 14 plan 14-01 ships migration `0007_apple_iap.sql` (creates `apple_subscriptions` + `apple_notifications_log`). Apply it to local then remote D1:

```bash
# From repo root
cd workers/worker

# Local D1 sim (wrangler dev consumes this same DB on port 8787)
pnpm exec wrangler d1 execute rishi-sync --local --file=drizzle/migrations/0007_apple_iap.sql

# Production D1 (the live binding declared in wrangler.jsonc)
pnpm exec wrangler d1 execute rishi-sync --remote --file=drizzle/migrations/0007_apple_iap.sql
```

Confirm both tables landed remotely:

```bash
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'apple_%'"
```

Expected output (two rows):

```
apple_notifications_log
apple_subscriptions
```

If the second `SELECT` returns zero rows, the migration did not commit — re-run the `--remote` step and check `wrangler d1 migrations list rishi-sync --remote`.

### 1.2 Wrangler secrets (production)

The worker reads four Apple-specific secrets at runtime. Set them ONCE per environment:

```bash
cd workers/worker

# Apple Store Connect API key (Issuer + Key ID identify the key; PRIVATE_KEY is the .p8 contents)
pnpm exec wrangler secret put APPLE_ASC_KEY_ID
pnpm exec wrangler secret put APPLE_ASC_ISSUER_ID
pnpm exec wrangler secret put APPLE_ASC_PRIVATE_KEY    # paste the entire .p8 file contents, BEGIN/END markers included

# Bundle identifier the JWS environment claim must match
pnpm exec wrangler secret put APPLE_BUNDLE_ID          # value: org.fidexa.rishi
```

`APPLE_ASC_PRIVATE_KEY` is the only multi-line secret here — `wrangler secret put` will prompt and accept the full PEM block on stdin. Verify each value is set:

```bash
pnpm exec wrangler secret list
```

The list should include all four `APPLE_*` keys plus the existing `STRIPE_*` and `BETTER_AUTH_*` secrets (these stay untouched — Phase 14 added Apple IAP next to Stripe metered billing, not in place of it).

Local dev: put the same four keys in `workers/worker/.dev.vars` (gitignored). `wrangler dev` reads `.dev.vars` automatically — DO NOT use `wrangler secret put` for the local sim.

### 1.3 Deploy the worker

```bash
cd workers/worker
pnpm deploy
```

This wraps `wrangler deploy` using the script in `workers/worker/package.json`. After it completes, the three new endpoints are live at:

- `POST https://api.fidexa.org/api/billing/verify-receipt` — authed (Better Auth cookie or bearer).
- `POST https://api.fidexa.org/api/billing/apple-webhook` — unauthenticated (Apple JWS is the trust anchor).
- `GET  https://api.fidexa.org/api/billing/me` — authed (Better Auth cookie or bearer).

Smoke them immediately:

```bash
# /me — should return 401 without a session
curl -sS -o /dev/null -w "%{http_code}\n" https://api.fidexa.org/api/billing/me
# → 401

# With a real session cookie pasted from a signed-in browser
curl -sS https://api.fidexa.org/api/billing/me \
  -H "Cookie: rishi.session_token=<paste>"
# → {"premium":false,"premiumUntil":null}  (or the user's real entitlement)

# Webhook reachable but rejects empty body
curl -sS -X POST https://api.fidexa.org/api/billing/apple-webhook \
  -H "Content-Type: application/json" -d '{}'
# → 400 (envelope validation; this is correct — Apple posts a signed payload, not an empty body)
```

### 1.4 SIWA Provider (Apple Sign-In)

The worker provides Sign in with Apple via Better Auth's first-party Apple social provider (Phase 15). Full cross-team wire contract: see [`WORKER-CONTRACT-AUTH.md`](./WORKER-CONTRACT-AUTH.md) (repo path `apps/apple/docs/WORKER-CONTRACT-AUTH.md`). This section covers operator setup only.

#### Required Wrangler Secrets

The Apple provider only mounts when all four of these secrets are present (see `workers/worker/src/auth.ts:35-48` — the provider is conditionally added to `socialProviders`). Three are NEW for Phase 15; the fourth is shared with Phase 14 and already deployed.

| Secret                    | Source                                                                                                          | Status |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- | ------ |
| `APPLE_SIWA_CLIENT_ID`    | Static value: `org.fidexa.rishi` (iOS bundle identifier — doubles as the OAuth audience for native ID-token sign-in) | NEW    |
| `APPLE_SIWA_KEY_ID`       | Apple Developer Console > Certificates, IDs & Profiles > Keys > select the SIWA-enabled key > copy the 10-char `Key ID` | NEW    |
| `APPLE_SIWA_PRIVATE_KEY`  | Full contents of the downloaded `AuthKey_<KEY_ID>.p8` PKCS8 PEM file (BEGIN/END markers included)                | NEW    |
| `APPLE_TEAM_ID`           | Apple Developer Console > Membership > Team ID                                                                  | Shared with Phase 14 IAP — already deployed; do NOT duplicate |

Set them ONCE per environment:

```bash
cd workers/worker

pnpm exec wrangler secret put APPLE_SIWA_CLIENT_ID
# Value: org.fidexa.rishi

pnpm exec wrangler secret put APPLE_SIWA_KEY_ID
# Value: the 10-char Key ID from Apple Developer Console

pnpm exec wrangler secret put APPLE_SIWA_PRIVATE_KEY
# Value: paste the entire .p8 file contents, including
#   -----BEGIN PRIVATE KEY-----
#   ...
#   -----END PRIVATE KEY-----
# wrangler accepts multi-line input on stdin.
```

Confirm all four are present:

```bash
pnpm exec wrangler secret list | grep APPLE_
# Expect:
#   APPLE_ASC_KEY_ID         (Phase 14 IAP)
#   APPLE_ASC_ISSUER_ID      (Phase 14 IAP)
#   APPLE_ASC_PRIVATE_KEY    (Phase 14 IAP)
#   APPLE_BUNDLE_ID          (Phase 14 IAP)
#   APPLE_TEAM_ID            (Phase 14 IAP, reused by SIWA)
#   APPLE_SIWA_CLIENT_ID     (Phase 15)
#   APPLE_SIWA_KEY_ID        (Phase 15)
#   APPLE_SIWA_PRIVATE_KEY   (Phase 15)
```

Note: APPLE_TEAM_ID is shared between Phase 14 IAP and Phase 15 SIWA. Do NOT add a second copy under a Phase-15-only name.

#### .p8 Source

The `.p8` is generated in Apple Developer Console:

1. Sign in at https://developer.apple.com/account
2. **Certificates, IDs & Profiles** -> **Keys** (left rail)
3. Click **+** to register a new key
4. Name it (e.g. `Rishi SIWA`); enable **Sign in with Apple** capability; click **Configure** and select the primary App ID (`org.fidexa.rishi`)
5. Continue -> Register -> Download. Apple downloads `AuthKey_<KEY_ID>.p8`.

The downloaded path on this operator's machine is `~/Downloads/AuthKey_<KEY_ID>.p8`. Move it OUT of `~/Downloads/` after deploy — Apple's console allows the `.p8` file to be downloaded ONCE per key, ever. Lose it and the only recovery path is to issue a new key (and reset `APPLE_SIWA_KEY_ID` + `APPLE_SIWA_PRIVATE_KEY` accordingly).

Save the Key ID separately — the value goes into `APPLE_SIWA_KEY_ID` and ALSO appears as part of the `.p8` filename (`AuthKey_<KEY_ID>.p8`). Both reads must match.

#### Deploy

After setting the three new secrets:

```bash
cd workers/worker
pnpm deploy
```

Same single-command flow as Phase 14 IAP — `wrangler deploy` packages the worker including the new `auth-apple-secret.ts` module and the conditional Apple provider block in `auth.ts`.

#### Post-Deploy Verification

Run all four checks. All four must pass before flipping the iOS SIWA flag for production.

1. **Provider is mounted** — the literal-null get-session contract proves Better Auth wired up the apple provider AND that the Optional decoder fix from Plan 15-05 works end-to-end:

```bash
curl -sS -w "\nHTTP %{http_code}\n" https://api.fidexa.org/api/auth/get-session
# Expected:
#   null
#   HTTP 200
```

A 200 with body `null` means Better Auth is mounted (`/api/auth/*` catch-all is live) AND it correctly returns its standard "no session" envelope. If you see HTTP 401 or 404, the worker did not deploy with the new auth wiring — re-check `pnpm deploy` output.

2. **Apple provider is registered** — POST a deliberately invalid JWT and confirm the provider runs and rejects it (rather than returning `INVALID_PROVIDER`):

```bash
curl -sS -w "\nHTTP %{http_code}\n" https://api.fidexa.org/api/auth/sign-in/social \
  -H "Content-Type: application/json" \
  -d '{"provider":"apple","idToken":{"token":"deliberately-invalid","nonce":"x"},"disableRedirect":true}'
# Expected:
#   {"error":"INVALID_TOKEN"} (or equivalent Better Auth 401 envelope)
#   HTTP 401
```

If you see `{"error":"INVALID_PROVIDER"}` (HTTP 400) instead, the provider did NOT mount — one of the four secrets is missing or `mintAppleClientSecret` threw at startup. Check `pnpm exec wrangler tail rishi-worker --format pretty` for a startup error.

If you see HTTP 500 with a stack trace mentioning `importPKCS8`, the `APPLE_SIWA_PRIVATE_KEY` value is not a valid PKCS8 PEM — most likely the BEGIN/END markers were dropped during `wrangler secret put`. Re-set the secret with the full PEM block.

3. **End-to-end iOS DEBUG simulator** — install the latest iOS DEBUG build on a simulator (or a real device with a development profile), tap **Sign in with Apple** on the signed-out screen, complete the Apple sheet, and confirm the app lands on the library screen. This exercises the full path: ASAuthorizationAppleIDProvider -> SignInWithAppleCoordinator -> `/api/auth/sign-in/social` -> Better Auth verify -> bearer-token Keychain persist -> `/api/auth/get-session` returns the `ProfileResponse` envelope on next launch -> library hydrates.

The DEBUG build target was lowered to iOS 18.0 in commit `474a5fb76`; any simulator running iOS 18.0 or later works.

4. **Worker logs are clean** — tail logs during the simulator sign-in and confirm no Sentry errors:

```bash
pnpm exec wrangler tail rishi-worker --format pretty | grep -i "auth\|apple"
```

Expected: a single `POST /api/auth/sign-in/social` line followed by a `GET /api/auth/get-session` line on the next launch. No `error` lines.

#### Note on Google Sign-In

Sign in with Google was removed from the iOS app in Phase 15 (Apple-only v1 scope). The worker's `socialProviders.google` block at `workers/worker/src/auth.ts:62-74` stays configured for future web / Android use, but iOS does NOT exercise it. No Google iOS coordinator, no Google button, no Google URL scheme in `Info.plist`. Marketing-site auth on `apps/web` is unchanged and continues to use Google's web OAuth as before.

If a future iOS plan re-adds Google (it won't for v1), it will register a new SIWA-style coordinator against `POST /api/auth/sign-in/social` with `provider: "google"` — the wire contract is provider-agnostic. There is no Google-specific iOS setup step to maintain in this runbook.

---

## 2. ASC Webhook Registration

Apple posts App Store Server Notifications V2 (ASSN V2) to a single URL. Phase 14 routes Sandbox and Production via the JWS `environment` claim — both ASC slots get the SAME URL.

1. Sign in to App Store Connect.
2. **My Apps** -> `Rishi` -> **App Information** (left rail).
3. Scroll to **App Store Server Notifications**.
4. **Production Server URL:** `https://api.fidexa.org/api/billing/apple-webhook`
5. **Sandbox Server URL:** `https://api.fidexa.org/api/billing/apple-webhook` (yes, the same URL — see [`WORKER-CONTRACT-IAP.md`](./WORKER-CONTRACT-IAP.md) §2 Pitfall 13).
6. **Version:** `Version 2` for both slots.
7. Click **Save**.
8. ASC immediately posts a synthetic `TEST` notification to the URL. Confirm:

```bash
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT notification_type, received_at FROM apple_notifications_log ORDER BY received_at DESC LIMIT 5"
```

You should see a row with `notification_type = 'TEST'` within ~30 seconds.

If no row appears within a minute:

- Re-check the URL in ASC has no trailing whitespace.
- Tail the worker logs: `pnpm exec wrangler tail rishi-worker --format pretty`. Apple's POSTs land as `POST /api/billing/apple-webhook` lines.
- Confirm the route is mounted: `curl -sS -X POST https://api.fidexa.org/api/billing/apple-webhook -d 'x'` should return 400, not 404.

---

## 3. Sandbox Smoke

Drive the StoreKit flow per `RUNBOOK-STOREKIT-SANDBOX.md` §5 first, then verify the worker side:

```bash
# Replace <txn> with the transactionId logged on the device after a Sandbox purchase
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT apple_transaction_id, user_id, status, current_period_end_ms, environment FROM apple_subscriptions WHERE apple_transaction_id = '<txn>'"
```

Expected row immediately after a Sandbox purchase:

- `status = 'active'`
- `environment = 'Sandbox'` (the JWS claim Apple set — NEVER a header you trusted)
- `current_period_end_ms` ~5 minutes ahead (Sandbox monthly cadence; see `RUNBOOK-STOREKIT-SANDBOX.md` §7)

Then watch for the renewal `DID_RENEW` ASSN V2 webhook within ~30 seconds of the accelerated 5-minute window:

```bash
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT notification_type, subtype FROM apple_notifications_log WHERE apple_transaction_id = '<txn>' ORDER BY received_at DESC LIMIT 10"
```

You should see a `SUBSCRIBED` row (initial purchase) followed by `DID_RENEW` rows as the accelerated renewals fire.

For refund validation use `RUNBOOK-STOREKIT-SANDBOX.md` §8 Path A (ASC Refund Test). Expected worker side: a `REFUND` row in `apple_notifications_log`, and the `apple_subscriptions.status` flips to `refunded` with `current_period_end_ms` set to ~now.

---

## 4. iOS DEBUG Stub Activation

For end-to-end UI testing WITHOUT a live worker round trip, Phase 14 plan 14-07 ships `DebugStubReceiptVerifier`. Activate per `RUNBOOK-STOREKIT-SANDBOX.md` §13 or the canonical two-flag form:

```bash
# Both flags required. The first enables IAP in the app; the second swaps in the stub.
defaults write org.fidexa.rishi StoreKitIAPFlag -bool YES
defaults write org.fidexa.rishi RishiUseStubReceiptVerifier -bool YES

# Verify it's wired (look for the log event on next launch)
log show --predicate 'subsystem == "org.fidexa.rishi" AND eventMessage CONTAINS "iap.verifier.stub.enabled"' \
  --info --last 5m
```

The stub returns `verified: true` with `premiumUntil` set to `now + 30 days` for any input. It is `#if DEBUG`-gated at the file level — Release builds physically cannot link it (see 14-07 summary's compile-strip guarantee).

To deactivate:

```bash
defaults delete org.fidexa.rishi RishiUseStubReceiptVerifier
# StoreKitIAPFlag can stay — it just re-enables real IAP wiring
```

---

## 5. Production Rollout Checklist

Tick before flipping `STORE_KIT_IAP_FLAG` (or equivalent) to ON for production users.

- [ ] §1.1 D1 migration applied to remote and the two `apple_*` tables exist.
- [ ] §1.2 all four `APPLE_*` secrets set on production via `wrangler secret put`.
- [ ] §1.3 `pnpm deploy` from `workers/worker/` succeeded and all three smoke curls pass.
- [ ] §2 ASC webhook registered for BOTH Production and Sandbox slots at the same URL; `TEST` notification row in `apple_notifications_log`.
- [ ] §3 a full Sandbox purchase + accelerated renewal produced rows in both `apple_subscriptions` and `apple_notifications_log`.
- [ ] §3 Sandbox refund (Path A) flipped `apple_subscriptions.status` to `refunded`.
- [ ] `pnpm test` -> 163/163 green in `workers/worker/` (Phase 14 net: schema + verify-receipt + webhook + /me + contract).
- [ ] `bash apps/apple/scripts/check-anti-steering.sh` exits 0.
- [ ] `RUNBOOK-STOREKIT-SANDBOX.md` §10 pre-submission checklist runs clean on a real device.
- [ ] iOS DEBUG stub disabled (`defaults delete org.fidexa.rishi RishiUseStubReceiptVerifier`) before TestFlight push.

---

## 6. Troubleshooting

### 6.1 "User paid but the app says free"

Most common cause: the device's local `Transaction.currentEntitlements` is fresh but `/api/billing/me` returned stale state from before the webhook landed. Steps:

```bash
# Confirm the row exists and is active
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT apple_transaction_id, status, current_period_end_ms FROM apple_subscriptions WHERE user_id = '<uid>'"
```

- `status = 'active'` and `current_period_end_ms > now` => the worker side is fine. Ask the user to background and foreground the app to trigger `EntitlementReconciler` to re-pull `/api/billing/me`. The 30s `Cache-Control` (see 14-06 summary) may also be in play — wait 30s and re-poll.
- No row exists => the `/api/billing/verify-receipt` call from the device never landed. Ask the user to tap **Restore Purchases** in the paywall; on-device `Transaction.unfinished` will replay.
- Row exists but `status != 'active'` (e.g. `refunded`, `expired`) => intentional revocation. Direct support to the App Store refund history.

### 6.2 "Refund didn't revoke entitlement"

```bash
# Is the REFUND webhook in the log?
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT notification_type, subtype, received_at FROM apple_notifications_log WHERE apple_transaction_id = '<txn>' AND notification_type IN ('REFUND','REVOKE') ORDER BY received_at DESC LIMIT 5"
```

- Row exists => the webhook landed; the `apple_subscriptions.status` should already be `refunded`. If not, check the dispatcher in `workers/worker/src/billing/apple-webhook.ts` and the deferred Phase 7 silent push (see Known Gaps §7) — until silent push ships, the device only learns about a refund on next foreground.
- No row exists => Apple either hasn't posted yet (refunds can take ~60s in Sandbox, longer in production) OR your webhook URL is misregistered. Re-check §2.

### 6.3 "verify-receipt returns 400 with reason: jws_signature_invalid"

Almost always one of three things:

1. **Environment mismatch.** A Sandbox JWS hit a production-only verifier (or vice versa). The Phase 14 verifier reads the JWS `environment` claim and routes accordingly — verify the claim wasn't tampered with by curling the raw JWS payload header decode (`echo "<jws-header>" | base64 -d`). If the claim is `Sandbox` and the worker rejected it, capture the JWS and file a `iap.verify-receipt.failure` Sentry alert with the raw payload (last 32 chars only — never log the full receipt).
2. **AppleRootCA-G3 mismatch.** The pinned root cert in `workers/worker/src/billing/apple-root-ca-g3.ts` is stale. Refresh from <https://www.apple.com/certificateauthority/> and redeploy. This is unlikely (Apple rotates roots roughly once per decade) but possible.
3. **Clock skew on the worker isolate.** JWS `exp` failed because the isolate's clock is ahead of Apple's `iat`. Cloudflare's isolate clocks are tightly NTP-synced — if this is happening repeatedly, file a Cloudflare ticket and re-verify with `pnpm exec wrangler tail rishi-worker --format pretty`.

### 6.4 "Webhook delivered twice — did we double-process?"

No. The webhook handler uses `INSERT ... ON CONFLICT DO NOTHING` on `notification_uuid` PK (Pitfall 3, see 14-05 summary). D1's `meta.changes === 0` short-circuits the dispatch and returns 200 OK to Apple immediately. Apple's retry policy hits ~5 times across 24h for any non-200; idempotency on the UUID PK is the only correct defense.

To verify a UUID was deduped:

```bash
pnpm exec wrangler d1 execute rishi-sync --remote \
  --command="SELECT notification_uuid, notification_type, received_at FROM apple_notifications_log WHERE notification_uuid = '<uuid>'"
```

There will be exactly one row regardless of how many times Apple POSTed.

### 6.5 "Webhook returns 400 with version_mismatch"

Apple shipped a payload claiming a `version` other than `'2.0'`. The handler rejects fast to keep a silent V3 migration from corrupting state (14-05 key-decisions). Action: open `workers/worker/src/billing/apple-webhook.ts`, read Apple's release notes, ship a version-bump migration in a follow-up plan.

### 6.6 "Webhook returns 400 with bundle_id_mismatch"

`data.bundleId` in the decoded payload was not `org.fidexa.rishi`. Either ASC misrouted (one team, multiple bundles) OR an attacker posted a forged JWS chain at the public URL. The handler logs the offending bundleId to Sentry — check there before assuming attack.

---

## 7. Known Gaps + Deferred Work

Tracked separately so a future operator does not chase them as bugs:

1. **Defense-in-depth Apple S2S `GetTransactionInfo` call** — deferred from plan 14-04. The verify-receipt handler currently trusts the device-supplied JWS after chain verification; a follow-up plan will re-fetch `GetTransactionInfo` from Apple for the extra hop. Risk is low because the JWS chain is cryptographically signed by Apple, but defense-in-depth catches a stolen-key scenario.
2. **Phase 7 silent-push emission on `REFUND` / `REVOKE`** — deferred from plan 14-05. Today the device picks up entitlement revocation on next foreground or via `Transaction.updates`. A future plan wires the Phase 7 silent-push channel so revocation propagates in real time.
3. **`originalTransactionId -> user_id` reverse lookup** — deferred from plan 14-05. Server-initiated `SUBSCRIBED` and `DID_RENEW` rows currently carry `user_id = ''` placeholder until the next device-side `/verify-receipt` reconciles the row to the real Better Auth user id. Operator impact: the `apple_subscriptions.user_id` column may be empty for a fresh server-initiated row for a few minutes.
4. **Daily reconciliation cron via Apple `GetAllSubscriptionStatuses`** — deferred from `14-RESEARCH.md` §12. Apple's webhook retry policy gives up after ~24h; a daily catch-up cron against `GetAllSubscriptionStatuses` would close the 1-in-100k missed-webhook gap. Until it ships, sustained webhook delivery failures need a manual replay from `apple_notifications_log.raw_payload`.
5. **Linker-symbol-grep CI guard for `DebugStubReceiptVerifier`** — deferred from plan 14-07. Source-grep already covers the stub via the anti-steering scan; mechanical proof via `nm` waits until CI builds Release configs of the package reliably.

---

## 8. References

- [`WORKER-CONTRACT-AUTH.md`](./WORKER-CONTRACT-AUTH.md) — cross-team SIWA auth contract (see also Section 1.4 ## SIWA Provider above for operator setup).
- [`RUNBOOK-STOREKIT-SANDBOX.md`](./RUNBOOK-STOREKIT-SANDBOX.md) — iOS-side Sandbox flow + §13 DEBUG stub activation.
- [`WORKER-CONTRACT-IAP.md`](./WORKER-CONTRACT-IAP.md) — cross-team contract reflecting Phase 14 deployed shapes.
- `workers/worker/BILLING.md` — Stripe metered billing runbook (parallel system; do not confuse Apple IAP with Stripe).
- `workers/worker/wrangler.jsonc` — Cloudflare bindings (D1 `rishi-sync`, R2 `rishi-books`, KV `RISHI_DESKTOP_STATE`, route `api.fidexa.org`).
- `workers/worker/drizzle/migrations/0007_apple_iap.sql` — the canonical schema (Phase 14 plan 14-01).
- `workers/worker/src/billing/apple-verify-receipt.ts` — verify-receipt handler + Hono route factory (Phase 14 plan 14-04).
- `workers/worker/src/billing/apple-webhook.ts` — ASSN V2 dispatch handler (Phase 14 plan 14-05).
- `workers/worker/src/billing/apple-me.ts` — `/me` entitlement resolver (Phase 14 plan 14-06).
- `workers/worker/src/billing/jws-verify.ts` + `apple-root-ca-g3.ts` — jose-based JWS verifier (Phase 14 plans 14-02 / 14-02b).
- `apps/apple/Packages/RishiAPI/Tests/RishiAPITests/Fixtures/verify-receipt-response.json` — frozen cross-side contract fixture (Phase 14 plan 14-08).
- Apple — **App Store Server API:** https://developer.apple.com/documentation/appstoreserverapi
- Apple — **App Store Server Notifications V2:** https://developer.apple.com/documentation/appstoreservernotifications
- Apple — **AppleRootCA-G3 cert:** https://www.apple.com/certificateauthority/

---

*Phase: 14-iap-backend / Plan: 09 / Owner: matovu90@gmail.com / Last reviewed: 2026-06-11*
