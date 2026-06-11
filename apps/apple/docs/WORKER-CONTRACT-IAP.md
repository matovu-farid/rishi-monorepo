# Worker Contract — StoreKit IAP

> This is the cross-team contract the worker team implements to serve iOS-side IAP verification + entitlement state.
>
> **Owned by:** iOS team (`apps/apple/Packages/RishiBilling/`)
> **Implemented by:** worker team (separate repo).
> **Last updated:** Phase 13 Plan 09.

Companion to [`RUNBOOK-STOREKIT-SANDBOX.md`](./RUNBOOK-STOREKIT-SANDBOX.md) — that doc tells the operator how to drive the Sandbox; this doc tells the worker dev what to build.

---

## 0. Summary

iOS does TWO things requiring worker support:

1. **On every purchase / renewal / restore:** iOS posts the signed JWS to `POST /api/billing/verify-receipt`. The worker re-verifies the JWS against Apple's certificate chain and is **authoritative** — iOS will NOT finalize a purchase (`transaction.finish()`) until the worker confirms.

2. **Out-of-band events:** Apple posts App Store Server Notifications V2 (ASSN V2) to a worker webhook for renewals, refunds, billing retries, and revocations. The worker updates `users.premium_until` from these events. iOS picks up the change on next launch via `Transaction.updates` plus the Phase 7 silent-push channel.

Both flows together yield the "most permissive wins" reconciliation contract documented in `13-RESEARCH.md` §3.4 — if either the device's on-device `Transaction.currentEntitlements` OR the worker's `users.premium_until` says the user has Pro, the user has Pro.

---

## 1. Endpoint: `POST /api/billing/verify-receipt`

### 1.1 Auth

- Standard Rishi worker Bearer token — same auth chain every other `/api/*` route the iOS app calls uses (Phase 2 `WorkerClient`).
- Token resolves to a `users.id` row.
- `401 Unauthorized` → iOS treats the response as 5xx-equivalent: leaves the transaction UNFINISHED and replays on the next launch via `Transaction.unfinished`. Do NOT issue a 401 for a perfectly valid token just because the JWS is bad — use the body's `reason` field for that (§1.5).

### 1.2 Request

```http
POST /api/billing/verify-receipt HTTP/1.1
Host: api.fidexa.org
Authorization: Bearer <user JWT>
Content-Type: application/json

{
  "jws": "<VerificationResult.jwsRepresentation: signed JWS string>",
  "productId": "org.fidexa.rishi.pro.monthly",
  "transactionId": 2000000300000001
}
```

Schema:

| Field           | Type     | Notes                                                                                                                |
| --------------- | -------- | -------------------------------------------------------------------------------------------------------------------- |
| `jws`           | `string` | Apple's signed JWS string. The canonical receipt. Encoded as a JWS Compact Serialization (three base64url segments). |
| `productId`     | `string` | The product the user purchased. Worker MUST cross-check against the decoded JWS to defeat replay.                    |
| `transactionId` | `uint64` | Apple-issued transaction ID. Worker MUST cross-check against the decoded JWS.                                        |

Wire shape comes verbatim from `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/VerifyReceiptAPI.swift` (Plan 13-03).

### 1.3 Worker MUST do

1. **Verify the JWS** using jose 6.x against pinned AppleRootCA-G3 (see `workers/worker/src/billing/jws-verify.ts`). The `@apple/app-store-server-library` package was rejected during Phase 14 research due to Cloudflare Workers compatibility concerns — open issue #318 in that repo tracks the maintainers' planned jose swap.
   - Decode against Apple's x.509 cert chain (full walk: leaf -> intermediate -> pinned root).
   - Root cert: **AppleRootCA-G3** — DER bytes pinned in `workers/worker/src/billing/apple-root-ca-g3.ts`.
   - Verify the JWT `alg`, `kid`, signature, and `exp`.
2. **Decode** the payload (a `JWSTransactionDecodedPayload` from Apple's library).
3. **Cross-check** the decoded `productId` matches the request body — reject `product_id_mismatch` if not.
4. **Cross-check** the decoded `transactionId` matches the request body — reject `transaction_id_mismatch` if not.
5. **Look up** the bearer-token user — reject `user_not_found` if not.
6. **Check for replay:** if the same `transactionId` is already finalized for a DIFFERENT user, reject `replay_detected` and log to Sentry with both user IDs.
7. **Verify against Apple's S2S API** (defense in depth) by calling Apple's `GetTransactionInfo` endpoint with the `transactionId` — both URLs:
   - **Production:** `https://api.storekit.itunes.apple.com/inApps/v1/transactions/{transactionId}`
   - **Sandbox:** `https://api.storekit-sandbox.itunes.apple.com/inApps/v1/transactions/{transactionId}`

   Apple's library exposes `AppStoreServerAPIClient.getTransactionInfo(transactionId)` for this. Reject `apple_unreachable` if both URLs time out after retry.
8. **Update** `users.premium_until` to the decoded payload's `expiresDate` (ms-precision UNIX timestamp from Apple, converted to ISO8601 UTC in DB).
9. **Persist** the finalized `transactionId` to `users.last_iap_transaction_id` for replay defense.
10. **Respond** per §1.4.

### 1.4 Response

Success:

```json
{
  "verified": true,
  "premiumUntil": 1812585600,
  "reason": null
}
```

> **Encoding:** `premiumUntil` is a JSON number of seconds since the UNIX epoch (NOT an ISO8601 string). Matches the per-endpoint `JSONDecoder` strategy used by iOS `WorkerClient` for this endpoint specifically. Phase 14 plan 14-08 freezes this in a shared JSON fixture both sides verify against — see `apps/apple/Packages/RishiAPI/Tests/RishiAPITests/Fixtures/verify-receipt-response.json`.
>
> **Per-endpoint contract divergence:** `GET /api/billing/me` returns `premiumUntil` as an ISO8601 string (see §3 of `WORKER-CONTRACT-IAP.md` summary — that endpoint pairs with a different iOS decoder). The two shapes are intentional and locked.

Failure (worker says "this JWS does not grant Pro" — distinct from a 5xx):

```json
{
  "verified": false,
  "premiumUntil": null,
  "reason": "jws_signature_invalid"
}
```

HTTP status:

| Status | Meaning                                                                                                                                      |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `200`  | BOTH success and `verified: false` responses. The body distinguishes them.                                                                   |
| `401`  | Invalid bearer token. iOS treats as transient — leaves transaction unfinished.                                                               |
| `5xx`  | Unexpected worker-side error (DB outage, Apple cert chain fetch failed, etc.). iOS treats as transient — leaves transaction unfinished, retries on next launch via `Transaction.unfinished`. |

### 1.5 Error reasons (canonical strings — iOS surfaces these as logs)

| `reason`                  | Meaning                                                                                              | iOS behavior                                          |
| ------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `jws_signature_invalid`   | Apple's signature did not verify against the cert chain.                                             | Finish transaction; do not grant; log + Sentry.       |
| `product_id_mismatch`     | Decoded productID does not match the request body.                                                   | Finish; do not grant.                                 |
| `transaction_id_mismatch` | Decoded transactionID does not match the request body.                                               | Finish; do not grant.                                 |
| `user_not_found`          | Bearer token resolved to no user (deleted account?).                                                 | Surface "sign in again" error to the user.            |
| `replay_detected`         | Same `transactionId` already finalized for a different user.                                         | Finish; do not grant; surface support contact prompt. |
| `apple_unreachable`       | Worker could not reach Apple's S2S endpoints after retry.                                            | Treat as 5xx-equivalent — leave UNFINISHED, retry.    |

The canonical list lives in code at `apps/apple/Packages/RishiBilling/Sources/RishiBilling/StoreKit/ReceiptVerifier.swift` (`VerifyReceiptResponse.reason: String?`).

### 1.6 Idempotency

- The endpoint is naturally idempotent: a duplicate request with the same `transactionId` for the same user MUST return `verified: true` with the same `premiumUntil` (within ms precision), NOT re-bill or double-extend.
- Worker SHOULD short-circuit duplicate requests by looking up `users.last_iap_transaction_id` before hitting Apple's S2S — saves a network round trip.
- Use the request's `transactionId` as the natural idempotency key. Do NOT require a separate `Idempotency-Key` header — iOS does not send one.

---

## 2. Webhook: App Store Server Notifications V2

Apple posts to a worker URL registered in App Store Connect → **My Apps** → `org.fidexa.rishi` → **App Information** → **App Store Server Notifications**. Both Production URL and Sandbox URL slots need to be filled.

### 2.1 Endpoint shape (worker-owned URL)

- **Path:** `POST /api/billing/apple-webhook` (registered at `https://api.fidexa.org/api/billing/apple-webhook` for both ASC Production and Sandbox slots — see [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md) §2).
- **Auth:** NONE at the HTTP layer (Apple does not authenticate). Worker MUST verify the JWS `signedPayload` instead — see §2.3.
- **Body:** Apple posts a small JSON envelope. The decoded JWS holds the actual notification.

### 2.2 Request body (verbatim from Apple)

```json
{
  "signedPayload": "<JWS>"
}
```

Decoded `signedPayload` (Apple's `responseBodyV2DecodedPayload`):

| Field                            | Notes                                                                                                                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `notificationType`               | One of: `SUBSCRIBED`, `DID_RENEW`, `DID_FAIL_TO_RENEW`, `REFUND`, `REVOKE`, `EXPIRED`, `DID_CHANGE_RENEWAL_STATUS`, `GRACE_PERIOD_EXPIRED`. Apple may add more — handle unknown by logging + 200. |
| `subtype`                        | Finer-grained context (e.g. `BILLING_RETRY`, `VOLUNTARY`, `AUTO_RENEW_ENABLED`, `AUTO_RENEW_DISABLED`, `INITIAL_BUY`, `RESUBSCRIBE`).                                                  |
| `notificationUUID`               | Apple's per-notification unique ID — primary idempotency key (see §2.4).                                                                                                              |
| `data.signedTransactionInfo`     | Another JWS — decode for transaction details (`productId`, `transactionId`, `expiresDate`, `revocationDate`, etc.).                                                                  |
| `data.signedRenewalInfo`         | Another JWS — decode for renewal info (`autoRenewStatus`, `expirationIntent`, `gracePeriodExpiresDate`, etc.).                                                                        |
| `data.bundleId`                  | Will be `org.fidexa.rishi` — assert as a cheap sanity check.                                                                                                                          |
| `data.environment`               | `Sandbox` or `Production` — route to the matching DB (or single DB with an environment column).                                                                                       |
| `version`                        | Always `"2.0"` for the V2 format. Reject anything else.                                                                                                                              |

### 2.3 Handling

Always verify the outer `signedPayload` JWS against Apple's cert chain BEFORE acting on the contents. Same library + same root (AppleRootCA-G3) as §1.3.

| `notificationType`           | Action                                                                                                                                                                                                                                       |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SUBSCRIBED`                 | Initial purchase — typically already handled via `/api/billing/verify-receipt`. Idempotent: no-op if `transactionId` already processed. Subtype `INITIAL_BUY` = first ever; `RESUBSCRIBE` = same user re-buying after lapse.                  |
| `DID_RENEW`                  | Update `users.premium_until` to new `expiresDate` from `signedTransactionInfo`. Idempotent on `transactionId`.                                                                                                                                |
| `DID_FAIL_TO_RENEW`          | If subtype is `GRACE_PERIOD` — leave `premium_until` alone until grace expires. Apple will retry; expect `EXPIRED` if it never recovers, `DID_RENEW` if it does.                                                                              |
| `GRACE_PERIOD_EXPIRED`       | The grace window elapsed without recovery. Set `premium_until = expiresDate`.                                                                                                                                                                |
| `EXPIRED`                    | Set `premium_until = expiresDate` (effectively now or near-past). Distinguish from REFUND/REVOKE in logs.                                                                                                                                     |
| `REFUND`                     | Apple-issued refund. Set `premium_until = now()` (effective immediately). Emit a Phase 7 silent-push to all of the user's device tokens so iOS picks up reconciliation on next foreground.                                                    |
| `REVOKE`                     | Family Sharing revocation (Family organizer removed the user) or Apple ad-hoc revoke. Same handling as `REFUND`.                                                                                                                              |
| `DID_CHANGE_RENEWAL_STATUS`  | Update internal `users.iap_auto_renew_status` (UI badge: "renews on YYYY-MM-DD" vs "ends on YYYY-MM-DD"). Subtype `AUTO_RENEW_DISABLED` means user cancelled — entitlement remains active until `expiresDate`.                                |

For any unknown `notificationType`: log to Sentry at `warning`, return 200 (Apple does NOT redeliver on 200), keep the row in `apple_notifications_log` so a worker dev can inspect later.

### 2.4 Idempotency + retry

- Worker MUST persist every incoming notification (`apple_notifications_log` table — see §3) with the decoded `notificationUUID` BEFORE acting on the contents.
- If `notificationUUID` already exists in the log, return `200` immediately — do NOT reprocess. Apple's retry curve will hit you with the same UUID up to ~5 times over several days.
- Use `notificationUUID` as the unique index — Apple guarantees it is globally unique per notification.
- Apple retries the webhook ~5 times on a curve (immediate, ~5min, ~30min, ~6h, ~24h) on any non-200 response. After that Apple gives up (Pitfall 13 below).

### 2.5 Daily reconciliation — defense in depth (RESEARCH §10 Pitfall 13)

Apple WILL eventually give up retrying a missed webhook. If your worker is down for a week, refunds silently miss. Catch-up mechanism:

- **Daily cron:** for every user with `users.premium_until > now() - 7 days` (active or recently-active subscribers), call Apple's S2S `GetAllSubscriptionStatuses` endpoint to read the canonical state.

  - **Production:** `https://api.storekit.itunes.apple.com/inApps/v1/subscriptions/{transactionId}`
  - **Sandbox:** `https://api.storekit-sandbox.itunes.apple.com/inApps/v1/subscriptions/{transactionId}`

  Use `appAppleId` instead of `transactionId` for the user-level query (`/v1/subscriptions/{appAppleId}` is the user-level path in the latest API revision).

- **Reconcile** the returned state against `users.premium_until`. If Apple says expired/revoked but DB says active, update the DB and emit a Phase 7 silent push to the user's devices.
- **Log** discrepancies to Sentry — sustained discrepancies indicate a webhook delivery issue worth a Slack ping.

This is **belt-and-braces** — under normal operation ASSN V2 carries everything in real time. The reconciliation job catches the 1-in-100k outage gap, which is exactly the gap Apple's retry policy leaves open.

---

## 3. Database Schema Implications

The worker adds NO new tables for v1 — `users.premium_until` already exists from the Phase-11 schema. New columns are suggested but optional:

| Column                            | Type                | Notes                                                                                                                                |
| --------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `users.last_iap_transaction_id`   | `bigint nullable`   | Last `transactionId` finalized for this user; used in the `replay_detected` check (§1.3 step 6) and idempotency short-circuit (§1.6). |
| `users.iap_auto_renew_status`     | `boolean nullable`  | Reflects `DID_CHANGE_RENEWAL_STATUS` events. UI badge only — does NOT gate entitlement.                                              |
| `users.iap_environment`           | `varchar(16)` enum  | `'Sandbox'` or `'Production'` — captured from the JWS payload; useful for support ticket triage.                                     |
| `apple_notifications_log` (table) | new table           | Append-only log of every received ASSN V2 notification. See schema below.                                                            |

**Implemented:** see `workers/worker/drizzle/migrations/0007_apple_iap.sql` for the canonical schema. Phase 14 chose D1 (SQLite) — `notification_uuid` is `text` (not `uuid`), `raw_payload` is `text` (not `jsonb`), timestamps are `integer` ms-epoch. The names + idempotency contract carry over unchanged. The `users.*` column additions originally suggested (`last_iap_transaction_id`, `iap_auto_renew_status`, `iap_environment`) were NOT added — they are derivable from `apple_subscriptions` joins.

Original Phase 13 sketch (kept here for posterity — DO NOT treat as the truth, the migration is):

```sql
CREATE TABLE apple_notifications_log (
  notification_uuid uuid PRIMARY KEY,
  notification_type varchar(64) NOT NULL,
  subtype varchar(64),
  user_id uuid REFERENCES users(id),
  transaction_id bigint,
  raw_payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  processing_error text
);
CREATE INDEX idx_apple_notifications_log_user_id ON apple_notifications_log(user_id);
CREATE INDEX idx_apple_notifications_log_received_at ON apple_notifications_log(received_at);
```

---

## 4. iOS-Side Mock Surface

For iOS development BEFORE the worker ships, the iOS app talks to a stub.

Production protocol — declared in `apps/apple/Packages/RishiBilling/Sources/RishiBilling/StoreKit/ReceiptVerifier.swift`:

```swift
public protocol ReceiptVerifier: Sendable {
    func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse
}

public struct VerifyReceiptResponse: Sendable, Equatable, Decodable {
    public let verified: Bool
    public let premiumUntil: Date?
    public let reason: String?
}
```

Test stub — `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Stubs/StubReceiptVerifier.swift`:

```swift
StubReceiptVerifier(result: .success(
  .init(verified: true, premiumUntil: .distantFuture, reason: nil)
))
```

The real implementation is `WorkerReceiptVerifier` which calls `WorkerClient.send(VerifyReceiptEndpoint(...))` and decodes the response into `VerifyReceiptResponse`. Wire shape is identical to §1.2 / §1.4 above — both sides share the JSON contract via `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/VerifyReceiptAPI.swift`.

---

## 5. Cross-Team Checklist

Tick before the worker deploys IAP support to production.

### Worker team confirms:

- [ ] `POST /api/billing/verify-receipt` returns the canonical shape in §1.4 (both success and `verified: false` use HTTP 200).
- [ ] All six `reason` enum strings from §1.5 are exhaustively handled — no synonyms, no extras.
- [ ] `app-store-server-library` (or equivalent Apple-blessed library) is the JWS verifier — NOT a hand-rolled JWT decoder.
- [ ] AppleRootCA-G3 is pinned in the worker image; cert chain expiry alarmed.
- [ ] Apple S2S endpoint URLs are env-configurable so Sandbox and Production can be tested without code changes.
- [ ] ASSN V2 webhook URL is registered with Apple via ASC for BOTH Production and Sandbox slots.
- [ ] `signedPayload` JWS is re-verified on every notification (not blindly trusted — Apple's IP allow-list is not sufficient).
- [ ] `apple_notifications_log` table is in place with `notification_uuid` as PRIMARY KEY for idempotency.
- [ ] Daily reconciliation job is scheduled and alerts on discrepancies.
- [ ] All worker logs forward `iap.*` events to Sentry with `user_id` + `transaction_id` tags.
- [ ] Reviewed Pitfall 13 (RESEARCH §10) and confirmed the reconciliation pattern addresses it.

### iOS team confirms:

- [ ] `WorkerReceiptVerifier` calls the verified endpoint via cookie OR bearer — both supported by the existing `requireAuth` middleware in `workers/worker/src/index.ts` (Better Auth + `@better-auth/passkey` bearer plugin).
- [ ] `WorkerReceiptVerifier` calls the verified endpoint URL (env-vared via `WORKER_BASE_URL`, not hardcoded).
- [ ] `EntitlementService` polling after notable transitions catches webhook-side updates within < 60 s of foreground.
- [ ] Phase 7 silent-push channel is used by the worker for `REFUND` / `REVOKE` — wakes iOS for immediate reconciliation.
- [ ] `Transaction.unfinished` replay runs at app launch via `AppDependencies.init()` (`PurchaseService.replayUnfinished()`).

### Support team confirms:

- [ ] Runbook for "user reports they paid but app says free" includes: check `users.premium_until`, check `users.last_iap_transaction_id`, check the most recent rows in `apple_notifications_log` for that user, and (if all OK) ask the user to tap **Restore Purchases**.
- [ ] Runbook for refund requests points the user at App Store Connect refund request flow, NOT at the worker DB.

### DevOps team confirms:

- [ ] Webhook URL is publicly reachable from Apple's IP ranges (Apple does NOT publish a static IP list — must accept from any source after JWS verification).
- [ ] Webhook URL is allowlisted in WAF rules so Apple's POSTs are not rate-limited.
- [ ] Sentry receives `iap.verify-receipt.failure` and `iap.webhook.unknown-type` as on-call alerts.

---

## 6. References

- `13-CONTEXT.md` — "Worker contract" decision block (this doc's source of authority).
- `13-RESEARCH.md` §6 — Worker Contract Draft (this doc's source-of-truth content).
- `13-RESEARCH.md` §10 Pitfall 13 — Server-Notifications V2 unreachable worker (reconciliation pattern).
- `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/VerifyReceiptAPI.swift` — wire shape Codable definitions.
- `apps/apple/Packages/RishiBilling/Sources/RishiBilling/StoreKit/WorkerReceiptVerifier.swift` — production verifier implementation.
- Apple — **App Store Server API:** https://developer.apple.com/documentation/appstoreserverapi
- Apple — **App Store Server Notifications V2:** https://developer.apple.com/documentation/appstoreservernotifications/responsebodyv2
- Apple — **app-store-server-library (Node):** https://github.com/apple/app-store-server-library-node
- Apple — **Get Transaction Info:** `https://api.storekit.itunes.apple.com/inApps/v1/transactions/{transactionId}` (production)
- Apple — **Get All Subscription Statuses:** `https://api.storekit.itunes.apple.com/inApps/v1/subscriptions/{transactionId}` (production)
- Apple — **Sandbox S2S host:** `https://api.storekit-sandbox.itunes.apple.com` (substitute for the production host above when reconciling Sandbox transactions).
- Apple — **AppleRootCA-G3 cert:** https://www.apple.com/certificateauthority/

---

## 7. Phase 14 Reconciliation (2026-06)

This doc was authored as the Phase 13 contract draft, against an assumed worker in `apps/web` that did not exist. Phase 14 shipped the real backend at `workers/worker/` on `api.fidexa.org` and the seven items below reconcile this contract back against deployed reality. Operations for the deployed system live in [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md).

1. **Host header (§1.2):** `Host: rishi.fidexa.org` -> `Host: api.fidexa.org`. The worker lives on the Cloudflare custom domain; the marketing site never served billing traffic.
2. **Verify-receipt response `premiumUntil` (§1.4):** ISO8601 string -> JSON number of seconds-since-1970. Matches the iOS `WorkerClient` decoder strategy locked by Phase 14 plan 14-04 and frozen by the cross-side fixture from plan 14-08. The `GET /api/billing/me` endpoint intentionally keeps an ISO8601 string for its own iOS decoder — the per-endpoint divergence is locked, not a drift bug.
3. **JWS library (§1.3 step 1):** `@apple/app-store-server-library` (Node) -> `jose` 6.x against pinned AppleRootCA-G3. The Apple package was rejected during Phase 14 research due to Cloudflare Workers compatibility concerns (open issue #318 tracks the maintainers' planned jose swap).
4. **Webhook path (§2.1):** Suggested `POST /api/billing/apple-notifications` -> implemented `POST /api/billing/apple-webhook`. Registered at `https://api.fidexa.org/api/billing/apple-webhook` for both ASC Production and Sandbox slots — the JWS `environment` claim routes the two environments inside a single endpoint.
5. **D1 schema (§3):** SQL block replaced with a pointer to `workers/worker/drizzle/migrations/0007_apple_iap.sql`. Phase 14 chose D1 (SQLite) over Postgres; the table names and idempotency contract carry over unchanged. The originally suggested `users.last_iap_transaction_id`, `users.iap_auto_renew_status`, and `users.iap_environment` columns were NOT added — they are derivable via joins against `apple_subscriptions`.
6. **Cross-Team Checklist (§5):** Added a note that `WorkerReceiptVerifier` may authenticate via cookie OR bearer (Better Auth + `@better-auth/passkey` bearer plugin), reflecting the existing `requireAuth` middleware in `workers/worker/src/index.ts`.
7. **Anti-steering scope:** the anti-steering CI guard (`apps/apple/scripts/check-anti-steering.sh`) scans Swift sources only — this contract doc and the runbook are out of scope for the grep but still avoid banned strings as a matter of hygiene.

Operational follow-ups (deferred from Phase 14 — tracked in [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md) §7):

- Defense-in-depth Apple S2S `GetTransactionInfo` call (deferred from plan 14-04).
- Phase 7 silent-push emission on `REFUND` / `REVOKE` (deferred from plan 14-05).
- `originalTransactionId -> user_id` reverse lookup for server-initiated `SUBSCRIBED` rows (deferred from plan 14-05).
- Daily reconciliation cron via Apple `GetAllSubscriptionStatuses` (deferred — RESEARCH §12).
- Linker-symbol-grep CI guard for `DebugStubReceiptVerifier` (deferred from plan 14-07).
