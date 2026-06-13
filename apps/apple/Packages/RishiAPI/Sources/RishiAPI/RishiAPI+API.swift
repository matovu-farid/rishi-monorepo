// RishiAPI — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiAPI exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiAPI is the typed HTTP client for the Cloudflare Worker
// backend. WorkerClient is the single entry point. Every endpoint
// is a value type conforming to one of the WorkerEndpoint
// protocols. Add a new endpoint by adding a new struct under
// Endpoints/.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 11 unused exports).

// MARK: - Client
//
// WorkerClient                — `WorkerClient.swift`. Actor. The single HTTP entry point.
//                                .send(endpoint) for request/response, .stream(endpoint) for SSE.
//                                Built with a base URL, URLSession, and a TokenProvider.

// MARK: - Token provider
//
// TokenProvider               — `TokenProvider.swift`. Protocol that returns the current bearer
//                                token (or nil) for the next request. WorkerClient calls this
//                                before every send.
// StaticTokenProvider         — `TokenProvider.swift`. Always returns a fixed token. Convenience
//                                for tests and one-shot flows.

// MARK: - Endpoint protocols
//
// HTTPMethod                  — `WorkerEndpoint.swift`. .GET / .POST / .PUT / .DELETE / .PATCH.
// WorkerEndpoint              — `WorkerEndpoint.swift`. Base protocol for a typed request.
//                                Declares Response, method, path. No body.
// WorkerEndpointWithBody      — `WorkerEndpoint.swift`. WorkerEndpoint + Encodable Body.
// WorkerStreamingEndpoint     — `WorkerEndpoint.swift`. For SSE-style streaming responses.
// WorkerStreamingEndpointWithBody
//                             — `WorkerEndpoint.swift`. Streaming + Encodable Body.

// MARK: - Error envelope
//
// ErrorEnvelope               — `ErrorEnvelope.swift`. The standard `{ "error": { code, message,
//                                details } }` shape the Worker returns on 4xx/5xx.

// MARK: - Endpoint families
//
// Auth                        — `Endpoints/AuthAPI.swift`. SessionUser, OkResponse, ProfileResponse,
//                                SignInSocialEndpoint, SignOutEndpoint, DeleteUserEndpoint,
//                                GetSessionEndpoint. Sign in (Apple), sign out, delete account,
//                                read profile.
// Sessions                    — `Endpoints/SessionsAPI.swift`. CreateSessionEndpoint,
//                                RedeemSessionEndpoint. Desktop-handoff session bootstrap.
// Users                       — `Endpoints/UsersAPI.swift`. UsersSearchEndpoint (admin-side user lookup).
// Conversations sync          — `Endpoints/ConversationsSyncAPI.swift`. ConversationRowWire,
//                                ConversationsSyncEndpoint, ConversationsSyncSinceEndpoint.
//                                Push/pull conversations.
// Messages sync               — `Endpoints/MessagesSyncAPI.swift`. MessageRowWire,
//                                MessagesSyncEndpoint, MessagesSyncSinceEndpoint. Push/pull messages.
// Sync (generic)              — `Endpoints/SyncAPI.swift`. SyncChange, SyncChangesEndpoint,
//                                SyncChangesResponse, SyncPushEndpoint, SyncPushResponse,
//                                SyncOpaqueJSON, PresignedURLResponse, SyncUploadURLEndpoint,
//                                SyncDownloadURLEndpoint. Generic record-level sync + R2 file URLs.
// Audio                       — `Endpoints/AudioAPI.swift`. SpeechStreamEndpoint (TTS streaming),
//                                TranscribeEndpoint (Whisper).
// Realtime                    — `Endpoints/RealtimeAPI.swift`. RealtimeClientSecretsEndpoint.
//                                Mints ephemeral OpenAI Realtime keys for voice chat.
// Devices                     — `Endpoints/DevicesAPI.swift`. DevicesRegisterEndpoint,
//                                DevicesRegisterResponse. APNs device registration.
// Desktop handoff             — `Endpoints/DesktopAPI.swift`. DesktopStartEndpoint,
//                                DesktopPollEndpoint, DesktopCancelEndpoint. Used when the
//                                Mac/Windows app forwards sign-in to the phone.
// Billing                     — `Endpoints/VerifyReceiptAPI.swift`. VerifyReceiptEndpoint.
//                                Server-side StoreKit receipt verification.

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit f4e3f5d7a.)
//
// WorkerEndpoint family       — every endpoint protocol is referenced by name in callers'
//                                generic constraints (e.g. `func send<E: WorkerEndpoint>`).
//                                Demoting them would break WorkerClient's public surface.
// SessionUser, OkResponse,
// ProfileResponse,
// ResponseBody types          — kept public because they appear as the Response type of one or
//                                more public endpoint structs; Swift requires Response types to
//                                be at least as public as the endpoint that returns them.
