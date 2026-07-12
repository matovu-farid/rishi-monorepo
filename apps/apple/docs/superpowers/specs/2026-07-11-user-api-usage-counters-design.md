# Authenticated Voice and TTS Request Counters

## Goal

Track the number of authenticated voice-chat and text-to-speech API requests made by each user, while allowing these features to be previewed without an active subscription.

## Scope

The worker will count requests to these routes:

- `POST /api/realtime/client_secrets` — voice-chat session starts.
- `POST /api/audio/speech` — OpenAI TTS synthesis.
- `POST /api/audio/speech/elevenlabs` — ElevenLabs TTS synthesis.

`GET /api/audio/speech/options` is metadata discovery and is not counted. The direct OpenAI WebRTC connection is made outside the worker and cannot be counted by this worker-side table.

Authentication remains required for all counted routes. Missing or invalid credentials return the existing unauthorized response and do not create or update usage rows. These routes do not require an active subscription; other subscription-gated routes remain unchanged.

## Data model

Add one `user_api_usage` row per user in the shared Drizzle schema:

- `user_id` — primary key and cascading foreign key to users.
- `voice_chat_requests` — non-null integer counter, default `0`.
- `tts_requests` — non-null integer counter, default `0`.
- `created_at` and `updated_at` timestamps.

Request increments use an atomic insert-or-update statement so concurrent requests cannot overwrite one another. The first request creates the row; later requests increment only the relevant counter.

## Request flow

After authentication succeeds, each counted route schedules its counter increment with the request execution context using `waitUntil`. The counter is incremented for every authenticated attempt, including TTS cache hits and failures that occur after authentication. Counting is independent from existing token/cost metering.

The voice route will no longer depend on the subscription middleware. TTS routes are already authentication-only; their behavior remains so while gaining the request-count side effect.

## Testing

Add behavior-focused tests covering:

1. Authenticated voice requests increment the voice counter.
2. Authenticated OpenAI and ElevenLabs TTS requests increment the TTS counter.
3. Repeated requests accumulate rather than overwrite counts.
4. Different users receive independent counters.
5. Unauthenticated requests are rejected and do not write usage rows.
6. The route behavior does not require an active subscription.

The migration will be added using the repository's existing Drizzle/D1 migration conventions, without rewriting or deleting existing migration files.
