# Rishi Data Use Consent and Provider Disclosure Design

> **Status:** Draft for implementation; the user approved one combined consent covering cloud sync and all four AI feature families.

## Goal

Address Apple App Review Guidelines 5.1.1(i) and 5.1.2(i) with one consent surface that explains, before remote transmission, what Rishi sends to its own cloud service and what it sends to third-party AI providers, who receives each category, and why.

## Scope

One combined consent covers ordinary cloud data use and four AI feature families.

Rishi cloud data includes account identity, imported books, reading progress, highlights, bookmarks, conversations, and messages sent to Rishi/Fidexa cloud infrastructure for authentication, sync, backup, and account features. This is clearly separated from third-party AI sharing in the same screen.

1. Text chat: prompts, book identifiers, and book-derived context sent through Rishi’s worker to OpenAI.
2. Read Aloud/narration: paragraph text sent through the worker to OpenAI TTS. The worker also exposes an ElevenLabs TTS path, which is disclosed as conditional provider behavior rather than claimed as the current iOS default.
3. Realtime voice: microphone audio, speech transcripts, and book/page context sent through OpenAI Realtime, with the worker minting the session configuration. OpenAI’s realtime transcription model is part of this same provider flow.
4. Transcription: microphone/audio bytes sent through the worker to Deepgram when the standalone transcription endpoint is used. The current iOS voice production flow uses OpenAI Realtime transcription instead.

The implementation plan must carry this provider matrix into tests and review metadata:

| Feature | Data sent | Provider | Current Apple reachability |
|---|---|---|---|
| Text chat | Prompt, book ID, book-derived context | OpenAI | Production |
| Read Aloud | Paragraph text, voice, speed | OpenAI TTS | Production |
| Alternate TTS | Paragraph text, voice, speed | ElevenLabs | Worker endpoint; conditional |
| Realtime voice | Microphone PCM, transcripts, page/book context | OpenAI Realtime | Production |
| Standalone transcription | Audio bytes and MIME type | Deepgram | Worker endpoint; no current Apple caller |

The public privacy policy documents both groups independently. The user sees one decision and one popup, but the disclosure does not collapse the recipients or purposes into vague “data sharing.”

## User experience and state

Create one focused Apple consent surface shown after sign-in and before the first remote sync or AI action, and reachable from Settings. It must:

- use a clear title such as “How Rishi uses your data”;
- name OpenAI, ElevenLabs, and Deepgram as third-party providers;
- list the categories sent: prompts/chat, book or page text, narration text, microphone audio, and transcripts;
- state that Rishi uses the data to answer questions, generate narration, transcribe speech, and provide voice conversations;
- state the verified retention boundaries without promising provider behavior: OpenAI response storage is disabled for chat/text-completion requests; Rishi may persist generated narration audio in an R2 cache whose retention policy is separately documented; Rishi may persist chat/transcript content through conversation synchronization; and provider-side retention/model-training behavior is governed by provider terms and must not be asserted until verified;
- link to the public privacy policy;
- provide one affirmative “Allow data use” action and a non-destructive “Not now” action; “Not now” leaves local reading available while remote sync and AI features wait for consent.

Store the consent version and timestamp under a deterministic key `dataUseConsent.<userId>` only after the signed-in user ID is known. There is no device-wide fallback grant. Bootstrap and account-switch behavior is: unknown/signed-out account means no grant; signing in loads only that user’s key; signing out clears the in-memory grant and leaves the persisted per-user record for that user; a different user can never read it. A consent version change requires reconfirmation. Revocation from Settings clears the current user’s persisted grant and prevents new sync or AI requests; in-flight requests are allowed to finish but no new remote data request may begin.

The existing microphone system permission remains separate. AI consent must be granted before the microphone permission prompt or before creating a remote voice session. The system microphone prompt does not substitute for AI-data consent.

## Client/server contract

Define one shared versioned header constant, `X-Rishi-Data-Use-Consent: 2026-07-29`, in the Apple networking layer and worker boundary. The Apple client adds it only after the local consent record is valid. The worker rejects missing or unsupported content/data consent headers before invoking sync or AI providers.

The worker applies the check as the first middleware after authentication, before request-body parsing, usage accounting, cache lookup, allowance refresh, ledger mutation, or provider calls. It covers every remote content/data route, including the provider-facing routes:

- `/api/chat`;
- `/api/text/completions`;
- `/api/embed`;
- `/api/audio/speech`;
- `/api/audio/speech/elevenlabs`;
- `/api/audio/transcribe`;
- the current `/api/voice-sessions` route and its `/api/voice-sessions/:id/control` WebSocket;
- the current `/api/voice-sessions` route and its `/api/voice-sessions/:id/control` WebSocket. The worker’s removed `/api/realtime/client_secrets` endpoint stays removed, and the Apple app’s legacy `EphemeralKeyFetcher` path is removed or made unreachable in production; tests must prove no production Apple voice start can select that path;
- sync upload, sync push, conversation, message, highlight, bookmark, and reading-position routes that transmit user content or metadata. Authentication-only and billing/entitlement requests remain outside this gate.

The rejection response is a stable `AI_DATA_CONSENT_REQUIRED` error with HTTP 428, so an outdated client cannot accidentally transmit personal content. The worker does not persist a consent decision; the Apple client’s current versioned grant is the explicit authorization for each request.

## Privacy policy

Update `apps/web/src/app/privacy/page.tsx` sections covering collection, use, storage/security, retention/deletion, and third parties. Name the providers and describe collection, transmission, use, storage/caching, operational usage records, and deletion/retention for each AI data category. Correct the existing contradictory claims that no analytics/usage data is collected and that no external entities receive reading data; distinguish content from service metadata and Sentry diagnostics. Do not claim that providers process only the data needed for the requested feature or promise model-training/retention behavior without verified provider terms.

Add a small content-level test or exported policy-content model so the provider names, data categories, purposes, and consent language cannot silently disappear from the rendered page.

## Testing and verification

- Apple: test the consent state model first, then one request-builder path for normal HTTP, streaming HTTP, and worker WebSocket requests. Cover fresh install, grant, deny, version invalidation, revocation, account switch/sign-out, remote sync, chat, TTS, realtime voice, and standalone transcription. Ensure onboarding and `VoiceSessionPresenter` cannot request the microphone or create a session before the data-use consent gate is satisfied.
- Worker: add failing tests proving every provider-facing route rejects missing/unsupported consent and accepts the current version. Confirm the guard runs before provider mocks, usage accounting, cache lookup, allowance refresh, and ledger mutation. Test both current voice-session creation/control and the legacy endpoint decision.
- Web: test the privacy page’s required provider/data/purpose disclosures.
- Build the iOS test target and run focused Bun worker tests. Inspect the final diff for every AI call site listed above.

## Explicitly out of scope

- Changing Apple subscription prices or product metadata; the `143.99` Voice Annual question must be answered in App Store Connect.
- Adding persistent consent records to the worker database.
- Replacing OpenAI, ElevenLabs, or Deepgram.
- Treating the two recipient groups as one vague purpose; the single dialog must still label Rishi cloud use separately from third-party AI use.
- Claiming verified provider retention or model-training behavior that is not documented by the provider agreement/configuration.

## Adversarial review loop

Each round: review → log findings → update the design → re-review.

### Round 1 — Research/design review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The design named `/api/realtime/client_secrets` although the worker removed it while a legacy Apple caller still exists. | Preferred migration to the ledger-backed `/api/voice-sessions`; any retained legacy route must be equally guarded and tested. |
| 2 | High | Onboarding and `VoiceSessionPresenter` can request microphone access independently of the AI consent state. | Explicitly gate both flows and order AI consent before microphone/session setup. |
| 3 | High | A route guard could run after usage or ledger side effects. | Require first middleware placement before parsing, usage, cache, allowance, ledger, and provider work. |
| 4 | High | The provider matrix incorrectly described Deepgram as realtime transcription and omitted OpenAI realtime transcription. | Added a feature/provider/reachability matrix and corrected the disclosures. |
| 5 | High | Existing privacy-page claims contradict actual provider sharing, Sentry, and operational usage records. | Require replacement edits to the relevant policy sections, including content vs metadata distinctions. |
| 6 | High | Retention claims about R2 caches, transcripts, and provider behavior were not grounded. | Replaced them with verified boundaries and explicit unknowns; require cache/transcript retention documentation. |
| 7 | High | Header injection has separate normal/streaming builders and a separate WebSocket surface. | Require one consent-aware path for all three and tests asserting coverage. |
| 8 | Medium | Account-scoped consent lifecycle was unspecified and could leak a grant across accounts. | Defined `aiDataConsent.<userId>` keys and sign-in/sign-out/account-switch rules. |

**Round 1 result:** Re-review required; the design was updated for all Critical/High findings.

### Round 2 — Re-review

The updated design now has explicit legacy-route handling, pre-microphone ordering, side-effect ordering, a provider matrix, contradictory-policy cleanup, retention boundaries, all networking surfaces, and account-key lifecycle. **PASS — 0 open Critical/High issues.**
