# No-card credit trial design

## Goal

Let a newly signed-up user try voice chat and text-to-speech without adding a payment method or encountering an immediate paywall. The app grants one non-expiring, account-level trial allowance and enforces it on the server.

## Product rules

- Each account receives 100 trial credits after signup. Credits do not expire.
- The onboarding explains that the trial requires no credit card, shows the 100-credit allowance, and does not redirect an unsubscribed user to a paywall.
- TTS consumes one credit only after a non-cached generation succeeds. Invalid, failed, and cache-hit requests consume no credit.
- Trial Voice Chat consumes two credits for each completed 30-second interval of an active voice session. This weights the costlier Realtime feature and makes a 100-credit trial capable of at most 25 total voice minutes.
- Trial Voice Chat has no separate minutes pool. It has a 40-interval maximum per session (20 minutes at the 30-second cadence); each interval costs two trial credits.
- A request is permitted only while the account has the relevant trial allowance or paid-plan allowance. When the trial is exhausted, the app presents subscription options.
- App Store and Stripe subscriptions remain payment entitlements. The credit trial is an app-owned backend entitlement; StoreKit cannot enforce it.

## Entitlement and session state

Create a `UserTrialLedger` Durable Object keyed by authenticated user ID. It is the single coordination point for an account's trial balance and its one active voice session. Persistent state includes:

- initial credits, used credits, and remaining credits;
- the active Rishi voice-session ID, its owner, maximum voice intervals, consumed voice intervals, trial credits per interval, state, and next billing deadline;
- the OpenAI Realtime call ID after it is registered;
- a one-time signed session-registration nonce; and
- the session termination reason and timestamps for audit and UI recovery.

The implementation must use Drizzle for application database schema and mutations. The ledger serializes related entitlement decisions so concurrent TTS requests and voice ticks cannot overspend the same balance.

## Paid-plan product policy

Paid plans use human-readable narration and Voice Chat time allowances, not credits. Their included allowances reset every monthly allowance period (including each of the twelve periods in an annual subscription), have no overages, and do not roll over. The trial's 100 starter credits remain a distinct, non-expiring onboarding entitlement.

| Plan | Monthly price | Annual price | Natural AI narration | Voice Chat | Per-session Voice Chat cap |
| --- | --- | --- | --- | --- | --- |
| Rishi Reader | $7.99/month | $76.99/year | 2 hours/month | 10 minutes/month | 10 minutes |
| Rishi Voice | $14.99/month | $143.99/year | 4 hours/month at launch | 30 minutes/month | 20 minutes |

The annual prices are approximately 20% below twelve monthly payments and should be presented as “Save about 20% with annual.” Annual billing does not bank or front-load usage: both paid plans retain the same monthly narration and Voice Chat reset, with no rollover or overages.

Both paid plans include unlimited core reading, library, highlights, and sync. All narration is OpenAI-generated natural narration; the product does not position device narration as an included fallback. The four-hour Rishi Voice narration allowance is deliberately conservative at launch and may be increased only after production cost telemetry validates the high-usage case.

Reader and Voice products are in the same StoreKit subscription group, with Voice ranked above Reader. A Reader-to-Voice upgrade takes effect immediately under StoreKit billing and begins a full fresh Voice allowance period; Rishi does not calculate the price difference or subtract Reader usage from the new Voice allowance. A Voice-to-Reader downgrade takes effect at renewal, so the user keeps Voice access until then. Same-tier monthly/annual changes take effect at renewal.

## TTS flow

1. Authenticate the user and ask the ledger to reserve the applicable allowance: one trial credit for a non-cached trial TTS generation, or a paid plan's narration allowance.
2. Generate audio or serve a cache hit.
3. Commit the reservation only for a successful, non-cached generation; release it for every other outcome.
4. Return the current remaining trial-credit count or paid narration allowance for client display.

This preserves the product promise that unsuccessful work costs nothing while still making concurrent usage safe.

## Voice flow

1. The app asks the backend to start a voice session. The ledger confirms that at least two trial credits or the applicable paid-plan allowance is available, creates a Rishi session ID and signed registration nonce, and records the plan-specific session cap: 40 trial intervals (20 minutes), 10 Reader minutes, or 20 Voice minutes.
2. The backend issues the existing OpenAI client secret. The app establishes WebRTC directly with OpenAI.
3. The OpenAI WebRTC call response includes the provider call ID in its `Location` header. The vendored Swift connector must retain this value, expose it to Rishi, and immediately register it with the authenticated backend using the Rishi session ID and its one-time nonce.
4. The ledger accepts the call ID once for its active session, accepts the authenticated hibernatable WebSocket control connection, and schedules the first 30-second charge.
5. At each 30-second boundary, the ledger atomically consumes two trial credits or 30 seconds of the paid plan's Voice Chat allowance. It sends the remaining applicable allowance and, when one interval remains, `session_ending` over the control WebSocket.
6. At the account, monthly allowance-period, or session cap, the ledger sends `session_ended` and calls OpenAI's `POST /v1/realtime/calls/{call_id}/hangup` with the server API key. The client also closes gracefully when it receives the control-WebSocket message.
7. If the app fails to register the OpenAI call ID promptly, it must close the just-opened voice connection and show a retryable error. The backend must not allow an untracked voice session to continue.

The server-side hangup is the authority. The hibernatable WebSocket provides the warning and polished user experience; it is not relied upon for enforcement.

## Control WebSocket

Use an authenticated WebSocket endpoint per Rishi voice session. The app connects only to the public Worker route; the Worker authenticates and routes the upgrade to the user-keyed Durable Object. The Durable Object authorizes that the requested session belongs to its ledger, then accepts the connection with Cloudflare's WebSocket Hibernation API. It persists enough attachment/session state to emit a current snapshot after reconnecting or hibernating.

Server messages are:

- `allowance_remaining`: updated trial-credit, narration, or Voice Chat allowance counts;
- `session_ending`: a warning that the final 30-second interval has begun;
- `session_ended`: the terminal reason (`voice_session_time_cap`, `trial_credits_exhausted`, `plan_voice_allowance_exhausted`, `subscription_required`, or `provider_hangup_failed`); and
- `session_error`: setup or reconciliation failures.

The app must reconnect its WebSocket while a session is active and recover state from the ledger after reconnecting. A terminal state always stops the local microphone and voice UI. The control WebSocket may carry an explicit client close acknowledgement, but session duration and enforcement are never derived from client messages.

## Client and payment behavior

- Onboarding contains a concise no-card trial message and remaining-credit display.
- Remove the current automatic subscription-screen redirect for signed-in, unsubscribed users; trial eligibility should instead open the app.
- At exhaustion, show a clear upgrade screen. On iOS, purchase uses StoreKit; on other surfaces, use their existing supported payment path.
- Paid plans display remaining narration and Voice Chat time in settings and at relevant limits; they do not expose internal credits. The credit trial is used only when no paid entitlement applies.

## Failure handling and abuse controls

- One active voice session per account prevents a user from multiplying their realtime allowance through parallel sessions.
- The ledger uses durable timestamps rather than client-reported duration. Alarms reconcile abandoned sessions and attempt provider hangup when a tracked session has reached its cap.
- Call-ID registration is authenticated, bound to a single active Rishi session, and accepted once. It is never exposed to another user or returned by public APIs.
- If OpenAI hangup fails, retain the terminal ledger state, retry with bounded backoff, and alert through existing operational logging. The client remains blocked from creating another voice session.
- Rate limits and account-abuse controls remain in front of trial endpoints. Provider rate limits do not replace account-level entitlement enforcement.

## Verification

Tests must cover:

- first-login grant and no-card onboarding/paywall routing;
- atomic TTS reserve, commit, release, cache-hit, and concurrent-request cases;
- voice call-ID capture and one-time registration;
- 30-second deductions: two credits for trial Voice Chat, 30 seconds of paid-plan Voice Chat allowance, the 40-interval/20-minute trial session cap, and paid-plan session caps;
- a 100-credit trial cannot provide more than 25 total Voice Chat minutes, below the Rishi Voice plan's 30 monthly minutes;
- hibernatable-WebSocket snapshot, warning, reconnect, and terminal messages;
- OpenAI hangup invocation at each terminal condition; and
- recovery after WebSocket reconnect, client crash, alarm firing, Durable Object hibernation, and hangup failure.

## Scope boundary

This design does not define top-ups or overage billing. Those are separate product decisions.
