# Rishi pricing and trial launch prerequisites design

## Decision summary

Rishi launches its no-card trial and both paid plans together on one server-authoritative entitlement system.

| Plan | Price | Included each monthly allowance period |
| --- | --- | --- |
| Trial | $0, no card | 100 non-expiring credits; trial TTS costs one successful non-cache request credit; trial Voice Chat costs two credits per completed 30-second interval, up to 25 total minutes and 20 minutes per session |
| Rishi Reader | $7.99/month or $76.99/year | 6 hours Natural AI narration and 90 minutes Voice Chat; a Voice Chat session is at most 10 minutes |
| Rishi Voice | $14.99/month or $143.99/year | 12 hours Natural AI narration and 180 minutes Voice Chat; a Voice Chat session is at most 20 minutes |

Annual subscriptions pay upfront but receive the same allowance every monthly allowance period. Paid allowances do not roll over and have no overages. Rishi uses OpenAI-generated natural narration only; device narration is not a product fallback.

## Launch principle

StoreKit is Rishi's payment and client-entitlement authority. The Worker is Rishi's usage-enforcement authority: it applies stored trial or paid allowance to each OpenAI request and can terminate an in-progress Voice Chat without client cooperation. The client obtains StoreKit's locally verified entitlement and submits Apple-signed transaction JWS to the Worker; the Worker verifies that signature locally, without calling an Apple server, before persisting the Reader or Voice entitlement. A free trial must not become publicly available until the Worker can both reject a new provider request and terminate an in-progress Voice Chat without client cooperation.

## Architecture

```text
Rishi app
  -> Worker: authenticated TTS, entitlement, purchase, and voice-session routes
  -> UserUsageLedger Durable Object: one ledger per authenticated user
  -> D1 through Drizzle: durable entitlement/audit reporting
  -> OpenAI: TTS and direct WebRTC Realtime connection

Rishi app
  -> Worker WebSocket route: authenticated voice control upgrade
  -> UserUsageLedger Durable Object: hibernatable control WebSocket
```

The Worker is the only public gateway, but it is a thin one: it authenticates the WebSocket upgrade and routes the connection to the authenticated user's Durable Object. The Durable Object validates that the requested Rishi voice session belongs to its ledger, accepts the hibernatable WebSocket, persists active session state, and sends state snapshots, warnings, and terminal messages. This control channel is a user-experience aid; enforcement is the ledger state and server-side OpenAI hangup.

## Authoritative entitlement model

Create a server-owned entitlement snapshot with these states:

- `trial_active`: remaining non-expiring trial credits;
- `trial_exhausted`: core reading remains available and AI features direct the user to plans;
- `reader_active`: current monthly allowance period plus remaining narration and Voice Chat time;
- `voice_active`: current monthly allowance period plus remaining narration and Voice Chat time; and
- `subscription_expired`: core reading remains available and AI features direct the user to renew or upgrade.

The snapshot includes plan, allowance-period start/end, remaining narration seconds, remaining Voice Chat seconds, remaining trial credits, and any active voice-session status. `/api/billing/me` evolves from its binary premium response into this snapshot. The iOS app uses it for routing and display only.

Drizzle-backed durable records must include the one-time trial grant, Apple-signed verified subscription/product mapping, monthly allowance periods, usage reservations, usage settlements, and an append-only audit record. Product IDs map to `reader` or `voice`. StoreKit must define Reader monthly/yearly and Voice monthly/yearly products in one subscription group, with Voice at the higher level.

When an authenticated user initiates an Apple purchase, Rishi passes that user's stable `appAccountToken` UUID in StoreKit's purchase options. Apple returns it in the signed transaction. The Worker accepts an entitlement sync only when the Apple signature is valid, the bundle/environment/product are expected, the transaction's `appAccountToken` matches the authenticated Rishi user, and the transaction has not been attached to another Rishi account. The Worker stores the transaction/original-transaction identifiers idempotently and derives active/expired status from the signed payload. It never trusts a client-supplied tier string.

The client performs entitlement sync at launch, foreground, purchase completion, restore, and StoreKit transaction updates. App Store Server API lookups and App Store Server Notifications are deliberately deferred. Therefore a cancellation, refund, or renewal is reflected in Rishi when the user next opens or foregrounds the app and submits StoreKit's current signed entitlement.

## Subscription transitions

Place all four products in one StoreKit subscription group. Voice monthly and yearly products are level 1; Reader monthly and yearly products are level 2. Apple calculates all proration, refunds, and charges; Rishi never calculates a price difference.

| Customer action | Apple transition | Rishi transition |
| --- | --- | --- |
| Reader to Voice, any billing duration | Immediate upgrade. Apple credits/refunds the unused Reader portion and charges the Voice product; the upgrade date becomes the new Voice renewal date. | The verified Voice transaction immediately closes the Reader allowance period with reason `upgraded` and starts a fresh Voice allowance period with the full 4-hour narration and 30-minute Voice Chat allowance. Previously used Reader allowance is not subtracted. |
| Voice to Reader | Deferred downgrade at the next renewal. | Keep Voice access and its current allowance period through renewal; create a fresh Reader allowance period only when StoreKit reports the Reader transaction as active. |
| Monthly to annual or annual to monthly within Reader, or within Voice | Same-level crossgrade; because duration changes, it takes effect at the next renewal. | Retain the current plan and allowance period until StoreKit reports the newly active product, then begin its fresh allowance period. |

The full allowance on an immediate Reader-to-Voice upgrade is intentional. Apple has ended the Reader period and begun a newly paid Voice period; it gives the customer an understandable upgrade benefit and does not create a repeating loophole because a downgrade is deferred until renewal. Allowance records store their start transaction, transition reason, and prior-period link for auditability.

## User usage ledger

`UserUsageLedger` is a Durable Object addressed deterministically by authenticated user ID. It is the sole coordinator for a user’s OpenAI allowance decisions and one active Voice Chat.

It atomically:

- grants or reads the 100-credit trial;
- reserves, commits, releases, and expires narration work;
- creates, tracks, and terminates one active voice session;
- deducts two trial credits every completed 30 seconds or deducts paid Voice Chat seconds;
- enforces the 20-minute trial/Voice cap and 10-minute Reader cap;
- stores the OpenAI Realtime call ID, one-time registration nonce, and terminal reason; and
- uses one alarm for the next voice charge, session limit, abandoned-session reconciliation, or bounded hangup retry.

The Durable Object hibernates when its control WebSocket is idle. Its persistent ledger state remains until normal account-data retention/deletion handling removes it. D1 is retained for reporting and cross-system audit; it is not used as a concurrent-session coordinator.

## Narration flow

1. The app sends an authenticated narration request to the Worker.
2. The Worker validates the request and checks the R2 cache before allocating any allowance.
3. A cache hit returns audio and consumes nothing.
4. For a miss, the ledger reserves one trial credit or a conservative paid narration-duration estimate. The Worker limits a request to a standard-sized chunk, initially no more than 1,000 characters, and limits prefetch to one upcoming chunk.
5. The Worker requests OpenAI narration and immediately streams the provider audio to the app once response headers/body are available.
6. A sidecar stream concurrently parses generated audio duration, writes the cache, and records provider telemetry without buffering the full audio or delaying first audio. The pending reservation remains authoritative while this work completes.
7. The sidecar settles the paid duration reservation, or commits the trial credit, after successful generation. On provider failure/cancellation it releases the reservation. If the sidecar is interrupted, a Durable Object alarm finds and reconciles the durable pending reservation; client delivery never depends on this recovery.
8. The response returns the last known entitlement snapshot; the next entitlement fetch or control message reflects the finalized allowance.

Generated audio duration—not client playback time—governs paid narration usage. The server must use a validated streaming audio-duration parser and preserve the reservation/audit record. This prevents pause, playback-speed, navigation, and client modification from affecting entitlement accounting.

## Latency and background-work contract

Rishi prioritizes the start of audio and Voice Chat over noncritical accounting work. The synchronous critical path is deliberately small: authenticate, validate input, check cache, reserve a bounded allowance, and begin the OpenAI request. The Worker must not wait for complete audio bytes, MP3 duration parsing, R2 cache writes, analytics, cost reconciliation, or client-facing allowance refresh before streaming audio.

For TTS, use a streaming sidecar pipeline: one branch reaches the app immediately; concurrent branches incrementally parse duration and populate R2. Lightweight cache writes and telemetry may use `waitUntil`; they must finish within its limit and never determine access. Any critical reservation settlement is persisted before streaming and is recoverable by the ledger alarm, rather than relying solely on best-effort background work. Longer or retryable reconciliation is queued for out-of-band processing.

For Voice Chat, session creation and client-secret minting are synchronous and intentionally short. The WebSocket control connection, OpenAI `call_id` registration, 30-second allowance ticks, hangup retries, token telemetry, and audit logging run independently of the audio path. The app may begin its direct WebRTC negotiation before the registration acknowledgement returns, but must close if registration fails or exceeds a short server-defined grace period. This permits a fast start while limiting any untracked provider use to that brief grace window.

## Voice Chat flow

1. The app calls `POST /api/voice-sessions`.
2. The ledger verifies the applicable trial or plan allowance, creates a Rishi session ID and a single-use registration nonce, records the session cap, and returns the existing short-lived OpenAI client secret.
3. The app opens the authenticated Worker WebSocket control route. The Worker routes it to the user's ledger, which validates session ownership and accepts the hibernatable connection. The app also connects to OpenAI over WebRTC.
4. The vendored Swift Realtime connector captures the OpenAI `call_id` from the `Location` header returned while creating the WebRTC call. The app immediately registers `{ rishiSessionId, callId, nonce }` with the Worker.
5. The Worker accepts that call ID once only when it belongs to the active session. Missing/late registration fails closed: the app closes the OpenAI connection and offers retry.
6. The ledger alarm deducts usage every 30 seconds. It sends `allowance_remaining`, then `session_ending` for the final interval, and `session_ended` when the account, monthly allowance-period, or session cap is reached.
7. At a terminal state, the ledger persists the closure, rejects future work for that session, closes the control channel, and calls OpenAI’s Realtime hangup endpoint. The app closes gracefully when it receives the terminal message.

On control-WebSocket reconnect, the ledger sends a current snapshot (`active`, `warning`, or `ended`) rather than replaying a complete history. A client close acknowledgement may be carried on the WebSocket, but the server never derives duration or authorization from it.

## App and billing changes

- Replace the binary signed-in subscription redirect with server-derived routing: trial and paid users enter the app; trial exhausted and subscription-expired users retain core reading but see upgrade paths when attempting AI features.
- Add no-card onboarding after authentication: 100 starter credits, no expiry, and a concise explanation of narration and Voice Chat use.
- Replace the two generic Pro StoreKit products and unlimited-use copy with four Reader/Voice products, accurate monthly/annual prices, plan comparison, restore/manage purchase flow, and plan-aware receipt mapping.
- Use an Rishi-controlled StoreKit purchase action rather than an opaque purchase view when necessary to pass `appAccountToken`; after every verified purchase or restore, send its JWS representation to the authenticated Worker entitlement-sync route.
- Add remaining-allowance UI: trial users see credits; paid users see Natural AI narration hours/minutes and Voice Chat minutes. Warn before a limit and show the reset date. Never expose paid internal credits.
- Add typed client states for trial exhaustion, paid narration exhaustion, paid Voice Chat exhaustion, Voice Chat warning, terminal cap, and provider setup failure.
- Update the vendored Realtime connector and Rishi voice adapter so the OpenAI call ID is retained and registered. Add a hibernatable-WebSocket control client with reconnect/background handling.
- Bound narration prefetch to one next chunk and cancel it on pause, navigation, or preference changes.

## Telemetry, abuse, and rollout controls

Current request counters and Stripe usage metering are supplementary telemetry only; they cannot enforce the new model. Correct the production TTS rate-card mismatch for `gpt-4o-mini-tts`, and write auditable provider-use events for cache result, request size, reservation outcome, generated duration, model/rate-card version, Realtime token totals, session duration, plan source, and terminal reason. Do not record book text, audio, ephemeral secrets, or OpenAI call IDs in general logs.

Add server-owned flags for shadow accounting, public trial availability, paid-limit enforcement, Voice Chat availability, and an emergency AI kill switch. Before public launch, use shadow accounting and internal/TestFlight operation to verify telemetry and product routing; public trial and both paid tiers are enabled together only after the launch gates below are satisfied.

Rate-limit trial grants, narration cache misses, Voice Chat starts, and repeated call-ID registration by account and IP. Reject concurrent sessions, duplicate/late call registration, and new Voice Chat starts until the existing session is terminal.

## Launch gates

- The Worker synchronously authorizes and settles every TTS request after cache evaluation.
- The Worker can enforce paid and trial limits even if a modified client lies or disconnects.
- A tracked OpenAI WebRTC call can be terminated from the backend at a hard cap.
- StoreKit and server map all four products to the same Reader/Voice policies; annual products create monthly allowance periods.
- The app correctly routes trial, exhausted, Reader, Voice, expired, restored-purchase, and allowance-warning states.
- Cost and reconciliation telemetry is live, alerting on failed hangups, missing call IDs, reservation leaks, unusual per-user spend, and usage/cost drift.

## Deferred scope

This first implementation deliberately excludes automated test work, top-ups, overages, family plans, annual allowance rollover, device narration, and a Realtime traffic proxy. Automated tests are a follow-up workstream before broad production expansion, but the implementation must keep components small and interfaces explicit so they are testable later.
