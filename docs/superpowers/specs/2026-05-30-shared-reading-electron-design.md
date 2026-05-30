# Shared Reading Sessions (Electron) — Design Spec

**Date:** 2026-05-30
**Status:** Draft
**Platforms:** Electron (rishi-electron) only for v1
**Supersedes:** [`2026-04-13-collaborative-reading-sessions-design.md`](./2026-04-13-collaborative-reading-sessions-design.md) (Tauri-era; capped at 3 users; no file transfer)

## Overview

A real-time co-reading feature in the Electron app. Up to **5 participants** (host + 4) join a session tied to one book. One participant at a time is the **sharer**, whose reading state — current page, scroll, zoom, TTS playback, transient annotations — is mirrored on every viewer's app. All participants can speak via open microphones; the sharer/host has mute controls. Viewers who don't already have the book file can receive it from the sharer via WebRTC data channel.

The implementation is built on:

- **XState v5 actor model** in the renderer — a parent `sessionMachine` plus per-concern child actors (`signalingActor`, `peerActor` × N, `syncActor`, `micActor`, `fileTransferActor`, `reconnectActor`).
- **WebRTC mesh** between Electron clients for audio and data (no media server at ≤5 peers).
- **Cloudflare Worker + Durable Object** for signaling, presence, role enforcement, and the approval queue. No media transits Cloudflare.
- **No new Next.js work.** The Electron client searches users via existing main-process DB infrastructure.

## Why this is the right shape

1. **Synced state, not pixels.** Each viewer renders their own legitimate copy of the book locally — same legal posture as a book club, no DRM transmission, ~1000× less bandwidth than video streaming, crisp text. The cost — viewers need the file — is mitigated by P2P file transfer over WebRTC data channel for the side-load workflow Rishi already uses.
2. **Cloudflare Durable Objects map naturally onto sessions.** One DO instance per session = isolated state, WebSocket-hibernation pricing, edge-distributed signaling, no infra to maintain. Uses Cloudflare CLI already in the project.
3. **Actor model matches WebRTC's per-peer concurrency.** Each remote participant gets a `peerActor`; spawn on join, stop on leave. This avoids encoding N peers' lifecycles into one giant state chart, and fits the existing `actors/` directory convention.
4. **Existing reader machines stay untouched.** `playerMachine`, `pdfReaderMachine`, and `ttsFetchActor` continue to own reading behavior. `syncActor` is a thin adapter that subscribes to their snapshots and dispatches existing events back into them.

## Requirements (locked)

| Aspect | Decision |
|---|---|
| Share mode | Synced state + P2P file transfer when viewer lacks the book |
| Backend | Cloudflare Worker + Durable Object only (no Next.js, no node1 for v1) |
| Identity | Logged-in users only; email search + auth-gated invite link |
| Audio | Open mics for all; sharer + host can mute any/all; TTS played locally on each viewer, state-synced |
| Sync scope | Book ID + position (CFI/page/scroll/zoom) + TTS state + transient session annotations (annotations save to sharer's account, not viewers') |
| Roles | Host = creator = default sharer; host can pass sharer role; sharer drop reverts role to host; host disconnect ends session after 120s grace |
| Reconnect | Yes — 30s viewer slot hold, 120s host grace, signed `reconnectToken` |
| Approval queue | Yes — `requiresApproval` defaults to ON; sharer can flip off at session creation |
| Capacity | ≤5 participants (server-enforced) |
| State management | XState v5 (already in app) |

## Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│ Electron renderer (one per participant)                                │
│                                                                        │
│   sessionMachine ──spawns──> signalingActor (WSS → CF Durable Object) │
│         │                                                              │
│         ├──spawns──> peerActor[id]   ×N                                │
│         │              ├── audio:  mic out + remote audio in           │
│         │              ├── sync:   reliable ordered RTCDataChannel     │
│         │              └── files:  reliable ordered RTCDataChannel     │
│         │                                                              │
│         ├──spawns──> syncActor (producer or consumer mode)             │
│         ├──spawns──> micActor                                          │
│         ├──spawns──> fileTransferActor[id] (when viewer lacks book)    │
│         └──spawns──> reconnectActor (transient; only in 'reconnecting')│
│                                                                        │
│   Existing untouched: playerMachine, pdfReaderMachine, ttsFetchActor   │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ IPC (sharing:* channels)
┌──────────────────────────────────┴─────────────────────────────────────┐
│ Electron main                                                          │
│   auth/      → mints short-lived signaling JWT                         │
│   database/  → searchUsersByEmail                                      │
│   library    → saveTransferredBook (writes blob into library)          │
│   protocol   → rishi:// deep link handler + single-instance lock       │
└────────────────────────────────────────────────────────────────────────┘
                                   │ WSS (JWT in subprotocol)
┌──────────────────────────────────┴─────────────────────────────────────┐
│ Cloudflare Worker  →  Durable Object per session (SessionRoom)         │
│   - validates JWT, joinToken, reconnectToken                           │
│   - enforces ≤5 cap, single host, single sharer                        │
│   - relays SDP/ICE between peers                                       │
│   - broadcasts presence, role transfers, approval results              │
│   - holds dropped slots (viewer 30s, host 120s)                        │
│   - NO media transits the DO                                           │
└────────────────────────────────────────────────────────────────────────┘
                                   │ ICE (STUN; TURN deferred)
                          Direct WebRTC mesh between peers
                          (mic audio + sync data + file chunks)
```

### Process-model facts

- WebRTC, mic capture, TTS, and all XState actors live in the renderer.
- Auth tokens, user DB queries, and library file writes live in main.
- The DO never sees media — only signed JSON metadata.

## `sessionMachine` state chart

```
context:
  me:            { userId, displayName, avatarUrl, authToken }
  sessionId:     string | null
  joinToken:     string | null
  reconnectToken: string | null
  role:          'host' | 'viewer'
  sharerId:      userId | null
  participants:  Map<userId, ParticipantInfo>
  pendingJoiners: Map<userId, JoinRequest>     // host only
  approvalStatus: 'none' | 'awaiting' | 'approved' | 'rejected'
  bookContext:   { bookId, contentHash, format } | null
  signalingRef:  ActorRef | null
  syncRef:       ActorRef | null
  micRef:        ActorRef | null
  reconnect:     { attemptsLeft, nextDelayMs, reservedUntil, schedule }
  error:         { code, message, recoverable } | null

states:
  idle
    on:
      CREATE_SESSION  → creating
      ACCEPT_INVITE   → joining

  creating
    invoke: createSessionOnDO  (POST /v1/sessions)
    on: done → connecting, error → failed

  joining
    invoke: redeemJoinToken    (POST /v1/sessions/:id/redeem)
    on:
      done → if requiresApproval && role=viewer → awaitingApproval else connecting
      error → failed

  awaitingApproval                                   ← from delta 1
    on:
      APPROVED   → connecting
      REJECTED   → failed { code: 'rejected_by_host' }
      after 120s → failed { code: 'approval_timeout' }

  connecting
    entry: spawn signalingActor, spawn micActor
    on:
      ROSTER_READY        → live
      SIGNALING_FAILED    → failed
      SIGNALING_DROPPED   → reconnecting
      CAP_REACHED         → failed

  live (parallel)
    entry: spawn syncActor (producer for host&sharer, consumer otherwise)
    on (any region):
      SIGNALING_DROPPED → reconnecting

    region: roster
      on:
        PEER_JOINED       → spawn peerActor(remoteId)
        PEER_LEFT         → stop peerActor, delete participant
        ROLE_TRANSFERRED  → update sharerId, swap syncActor mode if me involved
        JOIN_REQUESTED    → pendingJoiners.set(userId, request)             (host only)

    region: host-control (only when role=host)
      on:
        APPROVE_JOIN  {userId} → signaling.send('approve'), pendingJoiners.delete
        REJECT_JOIN   {userId} → signaling.send('reject'),  pendingJoiners.delete
        MUTE_PEER     {userId} → signaling.send('mute-peer')
        UNMUTE_PEER   {userId} → signaling.send('unmute-peer')
        PASS_SHARER   {userId} → signaling.send('pass.sharer')              (target must have hasBookFile)
        KICK_PEER     {userId} → signaling.send('kick.peer')
        END_SESSION            → ending

    region: self-state
      on:
        TOGGLE_MIC          → micActor SET_MUTED
        REQUEST_SHARER      → signaling.send('request.sharer')
        LEAVE               → ending

  reconnecting                                       ← from delta 2
    entry: stop signalingActor cleanly, pause peerActors
    invoke: reconnectActor (uses reconnectToken; backoff schedule [500,1000,2000,4000,8000])
    on:
      RECONNECTED → live
      HARD_FAIL   → ending
      after reservedUntil expires → ending

  ending
    entry: notify DO 'leaving', stop syncActor, stop micActor
    exit:  stop all peerActors, stop signalingActor
    after 500ms → idle

  failed
    on:
      RETRY   → creating | joining (based on prior role)
      DISMISS → idle
```

**Invariants enforced by the parent:**
1. `sharerId` only changes via DO-broadcast `ROLE_TRANSFERRED`. Local clicks send a request; they never mutate `sharerId` directly.
2. Peer actors are created only from roster events, never speculatively.
3. `syncActor` mode swap on role transfer is atomic — stopped and respawned in the same transition.
4. `ending` always runs cleanup, even on transport failure.

## Actor contracts

### `signalingActor`
Single WebSocket to the DO. Heartbeat ping every 20s; emits `SIGNALING_DROPPED` on missed pong / `close`.

| In events | Out events |
|---|---|
| `SEND { payload: ClientMsg }` | `CONNECTED`, `ROSTER_UPDATE`, `SDP_OFFER`, `SDP_ANSWER`, `ICE_CANDIDATE`, `PEER_JOINED`, `PEER_LEFT`, `ROLE_TRANSFERRED`, `JOIN_REQUESTED`, `APPROVAL_RESULT`, `HOST_SUSPENDED`, `HOST_RESUMED`, `KICKED`, `SIGNALING_DROPPED` |

Input: `{ wsUrl, sessionId, jwt, reconnectToken? }`.

### `peerActor` (one per remote participant)
Owns one `RTCPeerConnection` plus two data channels: `'sync'` (ordered, reliable) and `'files'` (ordered, reliable, separate to avoid head-of-line blocking). Trickle ICE.

States: `negotiating → connected → (failed | closed)`.

| In events | Out events |
|---|---|
| `REMOTE_SDP`, `REMOTE_ICE`, `SET_MIC_TRACK`, `SEND_SYNC`, `SEND_FILE_CHUNK` | `LOCAL_SDP`, `LOCAL_ICE`, `REMOTE_AUDIO`, `SYNC_RECEIVED`, `FILE_CHUNK`, `PEER_CONNECTED`, `PEER_FAILED` |

### `syncActor` (producer/consumer)
Bridges `playerMachine`/`pdfReaderMachine` to the wire. The only actor that touches the existing reader machines.

| Mode | In events | Out events |
|---|---|---|
| producer | `SUBSCRIBE_LOCAL`, `BROADCAST` | `OUTGOING_SYNC { msg }` |
| consumer | `SYNC_RECEIVED { msg }` | `APPLY_TO_READER { event }`, `TTS_SYNC { isPlaying, position, voiceId, rate }` |

**Sync payload schema** (versioned, `v: 1`):
```ts
type SyncMsg =
  | { v:1; t:'reader.position'; bookId; cfi?; pageIndex?; scrollY; zoom; ts }
  | { v:1; t:'tts.state'; isPlaying; position:{sentenceIdx,charOffset}; voiceId; rate; ts }
  | { v:1; t:'annotation.add'; id; range; color; ts }
  | { v:1; t:'annotation.remove'; id; ts }
  | { v:1; t:'cursor'; x; y; ts };        // throttled to 30Hz; optional in v1
```

**Throttling:** position 100ms coalesced; cursor 30Hz; annotations immediate. Monotonic `ts` per producer.

**Ordering:** consumer drops `reader.position` / `tts.state` with `ts <= lastAppliedTs` (per-type). Annotations are CRDT-style by id.

**Mode swap:** new producer's first emission is a full state snapshot so newly-promoted viewers stay in sync without waiting for the next event.

**Annotation ownership across role transfer:** annotations are persisted by the account of the participant who *created* them, not by whoever holds the sharer role at the time. A viewer who becomes sharer and adds annotations persists them to their own account; if they pass the role back, those annotations remain theirs. Viewers continue to see all in-session annotations live regardless of who created them, but only their own creations persist to their library after the session ends.

### `micActor`
Owns `getUserMedia`, mute states, and remote `<audio>` elements.

| In events | Out events |
|---|---|
| `SET_MUTED { muted, source: 'self' | 'host' }`, `SET_DEVICE`, `ATTACH_REMOTE`, `DETACH_REMOTE` | `LOCAL_TRACK_READY`, `LOCAL_LEVEL`, `REMOTE_LEVEL`, `MIC_DENIED`, `MIC_ERROR` |

Mute semantics: `'self'` is user-toggled and clearable by user. `'host'` is enforced — `SET_MUTED { muted: false, source: 'self' }` is rejected while a `'host'` mute is active. Remote audio is also ignored renderer-side for host-muted peers as defense in depth.

### `fileTransferActor` (per-peer, only when needed)
16KB chunks, 32-chunk sliding window with `CHUNK_ACK`, SHA-256 verified on completion. Receiver writes the verified blob via `sharing:saveTransferredBook` IPC and flips its `hasBookFile` to `true` only after that.

| Mode | In events | Out events |
|---|---|---|
| sender | `START`, `CHUNK_ACK { seq }` | `SEND_FILE_CHUNK`, `PROGRESS`, `COMPLETED`, `FAILED` |
| receiver | `FILE_CHUNK` | `PROGRESS`, `COMPLETED { blob, hash }`, `FAILED` |

### `reconnectActor` (transient, spawned in `reconnecting`)
Exponential backoff with `schedule = [500, 1000, 2000, 4000, 8000]` ms and hard ceiling `reservedUntil`.

| Out events |
|---|
| `RECONNECTED { freshSignalingRef }`, `HARD_FAIL { reason }` |

## Cloudflare Worker + Durable Object

### Auth model

- **App JWT** — Rishi-issued, RS256, audience `'rishi-sharing'`, ~5min TTL. Worker verifies with `env.AUTH_PUBLIC_KEY`.
- **`joinToken`** — Worker HMAC, payload `{ sessionId, issuedAt, expiresAt, maxUses? }`, embedded in `rishi://sharing/join?t=...`. Validates *the link*.
- **`reconnectToken`** — Worker HMAC, payload `{ sessionId, userId, reservedUntil }`. Issued on first successful WS upgrade. Bypasses approval queue but not JWT auth.

All three are required for a full WS handshake.

### HTTP endpoints

```
POST  /v1/sessions                       Auth: Bearer appJwt
      body: { bookContext, requiresApproval }
      200:  { sessionId, joinToken, joinUrl, wsUrl }

POST  /v1/sessions/:id/redeem            Auth: Bearer appJwt
      body: { joinToken }
      200:  { sessionId, bookContext, requiresApproval, hostProfile, wsUrl }
      4xx:  { code: 'expired'|'session_ended'|'cap_reached'|'token_invalid' }

GET   /v1/sessions/:id/wss               WebSocket upgrade
      Subprotocols: 'rishi.sharing.v1', 'jwt.<appJwt>', ('reconnect.<reconnectToken>')?
```

### DO state shape (persisted via `state.storage`)

```ts
type SessionState = {
  sessionId; hostUserId; sharerUserId; bookContext;
  requiresApproval; status: 'live' | 'host-suspended' | 'ended';
  createdAt; hostSuspendedUntil?;
  participants: Record<userId, {
    profile; joinedAt; hasBookFile;
    micState: 'unmuted' | 'self-muted' | 'host-muted';
    connectionState: 'connected' | 'reconnecting';
    reservedUntil?;
  }>;
  pendingJoiners: Record<userId, { profile; requestedAt }>;
  joinTokens: Record<tokenId, { issuedAt; expiresAt; uses }>;
};
```

DO uses the **WebSocket Hibernation API** (`acceptWebSocket`) so cost stays near zero between messages.

### WebSocket protocol (JSON, all frames `{ v: 1, t, ... }`)

**Client → DO**
```
hello { hasBookFile }
sdp.offer { to, sdp } | sdp.answer { to, sdp } | ice { to, candidate }
request.sharer | pass.sharer { to }       (pass: host only; target must have book)
mute.peer { userId, muted } | kick.peer { userId }   (host only)
approve.join { userId } | reject.join { userId }     (host only)
has.book { value } | mic.state { value }
leave | ping
```

**DO → client**
```
welcome { you, role, sharerId, reconnectToken, reservedUntil }
roster  { participants, pendingJoiners?, requiresApproval, bookContext, status, hostSuspendedUntil? }
peer.joined { userId, profile, hasBookFile }
peer.left   { userId, reason: 'left'|'kicked'|'dropped' }
peer.updated { userId, patch }
sdp.offer / sdp.answer / ice { from, ... }
role.transferred { newSharerId }
join.requested { userId, profile }                   (host only)
approval.result { approved, reason? }                (target viewer only)
host.suspended { until } | host.resumed
kicked { reason }
session.ended { reason: 'host_left'|'host_ended'|'host_grace_expired' }
error { code, message }
pong
```

### Server-side lifecycle rules

| Event | Behavior |
|---|---|
| First `hello` from non-host with valid `joinToken`, `requiresApproval=true` | Add to `pendingJoiners`, hold socket, notify host. |
| `hello` with `reconnectToken` valid & within `reservedUntil` | Restore slot, send fresh roster, broadcast `peer.updated`. |
| Admitted + reconnecting ≥ 5 | Reject new admissions with `cap_reached`. |
| Host socket closes | `status='host-suspended'`; `hostSuspendedUntil = now + 120s`; block new admissions. |
| Host reconnects in window | `host.resumed`. Sharer role does NOT auto-revert to host. |
| Host grace expires | Broadcast `session.ended { host_grace_expired }`; close sockets; cleanup after 5min. |
| Sharer (non-host) closes | Sharer reverts to host; broadcast `role.transferred`. Slot held 30s. |
| Viewer closes | Slot held 30s, then `peer.left { dropped }`. |
| `pass.sharer` | Host only. Target must be in roster with `hasBookFile = true`. |
| Host-only ops by non-host | `error { code: 'forbidden' }`. |

### Rate limits (Worker-side, before DO)

| Action | Limit |
|---|---|
| Session creation per user | 10/hour |
| Join attempts per IP per token | 5/min |
| WS frames per socket | 60/sec sustained |
| `request.sharer` per viewer | 1 every 15s |
| SDP relays per session total | 200 |

Counters live in DO storage; reset per-session.

### Logging

DO emits structured logs via logpush: `session.created`, `peer.admitted`, `peer.rejected`, `role.transferred`, `session.ended`. Metadata only — no message bodies, no user content.

## IPC contract (renderer ↔ main)

Added under `sharing:*` in `src/preload/ipc-contract.ts`.

```ts
// renderer → main (invoke)
sharing:getSigningJwt       () → { jwt, expiresAt }
sharing:searchUsersByEmail  ({ query, limit }) → User[]
sharing:saveTransferredBook ({ bookId, contentHash, blob }) → { localPath }
sharing:hasBookFile         ({ contentHash }) → boolean
sharing:getConfig           () → { wsBaseUrl, workerBaseUrl, iceServers }

// main → renderer (send/broadcast)
sharing:deepLinkReceived    ({ joinToken })
sharing:authStateChanged    ({ isAuthed })     // existing channel; sessionMachine reacts
```

### Deep-link flow

Invite link: `rishi://sharing/join?t=<joinToken>`. Registered in `electron-builder.yml` under `protocols`.

- **App closed:** OS dispatches URL to OS-registered handler; main captures from `process.argv` (Win/Linux) or `open-url` (macOS); holds until renderer ready; sends `sharing:deepLinkReceived`.
- **App open:** `second-instance` event fires (requires `app.requestSingleInstanceLock()`); main focuses window, sends `sharing:deepLinkReceived`. If `sessionMachine` is already `live`, the UI surfaces a confirm dialog before dispatching `LEAVE` then `ACCEPT_INVITE`.
- **Not signed in:** machine queues the intent in `idle`; existing auth flow runs; on `sharing:authStateChanged { isAuthed: true }`, queued `ACCEPT_INVITE` fires automatically.

Implementation note: if the app does not already enable `app.requestSingleInstanceLock()`, doing so is part of this feature's main-process work.

## UI surface

New components under `src/renderer/src/components/sharing/`:

| Component | Purpose |
|---|---|
| `StartSessionPopover` | Anchored to "Share" button on reader toolbar. Toggle for `requiresApproval` (default ON). |
| `SessionPanel` | Right-side Sheet. Sections: Participants, Pending, Invite, Controls. Persistent. |
| `ParticipantTile` | Avatar, name, mic ring, role badges; host menu (Mute, Pass sharer, Kick). |
| `InvitePanel` | Tabs: "Search by email" (debounced → `sharing:searchUsersByEmail`) and "Copy link". |
| `ApprovalQueueItem` | Host's view of a pending joiner with Approve / Reject. |
| `ApprovalWaitingScreen` | Viewer-side blocking modal during `awaitingApproval`. |
| `FileTransferRow` | Per-peer progress bar inside SessionPanel. |
| `HostSuspendedBanner` | Top banner during `status='host-suspended'`. |
| `RoleTransferToast` | "You are now the sharer" / "Sharer changed to {name}". |
| `KickedDialog` | Blocking dialog explaining kick; OK → `idle`. |
| `MicChip` | Reader chrome; click to toggle; shows host-muted read-only. |
| `CursorOverlay` | Viewer-side dot for sharer's cursor (throttled). Optional in v1. |

### State → UI map

| `sessionMachine` state | Visible UI |
|---|---|
| `idle` | "Share" button only |
| `creating` | Popover spinner |
| `joining` | Full-pane spinner |
| `awaitingApproval` | `ApprovalWaitingScreen` |
| `connecting` | Tray pill "Connecting…" |
| `live` | Tray pill, optional `SessionPanel`, reader overlay, mic chip |
| `live` + pending joiners (host) | Tray pill badge + toast |
| `live` + host-suspended | `HostSuspendedBanner` |
| `reconnecting` | Tray pill "Reconnecting… (n)"; reader shows last synced view |
| `ending` | Brief "Leaving…" then collapses to `idle` |
| `failed` | Toast with reason + Retry/Dismiss |

### Viewer drift behavior

- Viewers can scroll their own copy. When position diverges from `syncedPosition` by more than half a page, a floating "Snap back" button appears. Auto-snaps on next sharer page-turn (configurable per-viewer; default ON).
- TTS play/pause syncs only on transitions, not every tick — viewers can pause locally without being force-resumed.

### Accessibility

- All controls keyboard-reachable; mic toggle has global shortcut `⌘⇧M` / `Ctrl+Shift+M`.
- Mute state changes announced via `aria-live="polite"`.
- `ApprovalWaitingScreen` has a clear cancel path.

### Non-UI in v1

- No text chat
- No raised-hand / reactions
- No video
- No recording

## Error handling

| Failure | Detection | Behavior | UI |
|---|---|---|---|
| Mic permission denied | `getUserMedia` rejects | Continue without mic; user self-muted; OS-settings link | Persistent toast |
| WS upgrade rejected (401) | HTTP status | Re-mint JWT once; second 401 → sign-out prompt | Failed banner |
| WS drops mid-session | heartbeat timeout / `close` | → `reconnecting` | Tray pill |
| Single peer ICE failure | `RTCPeerConnection.iceConnectionState='failed'` | One renegotiation retry; then mark peer `unreachable` | Tile subtitle "Cannot connect" |
| All ICE failures within 10s | All peerActors `failed` | NAT guidance modal; TURN is future work | "Direct connection blocked" modal |
| File transfer corruption | SHA-256 mismatch | Discard; request one resend; second failure → error | Transfer row "failed" |
| Approval timeout | `after 120s` in `awaitingApproval` | → `failed { approval_timeout }` | Toast |
| Host-grace expired | `session.ended { host_grace_expired }` | → `ending` | Banner |
| Two clients race for sharer | DO is single arbiter | DO emits `role.transferred` exactly once; loser's request dropped silently | No UI change for loser |
| Role transfer mid-page-turn | Sequence number gap | Consumer drops stale by `ts`; new producer emits full snapshot | One-frame flicker possible; acceptable |
| Self-kick attempt | Worker validation | DO rejects with `forbidden` | None (logged in dev) |
| App backgrounded | `visibilitychange` | No change; mic & sync continue | None |
| OS sleep | WS drop | Same as WS-drops path | Tray pill |
| Logout in session | `sharing:authStateChanged { false }` | Dispatch `LEAVE`; → `ending` | "Signed out" toast |
| Book file deleted mid-session | Reader machine error | `syncActor` halts; session continues with audio | Inline reader error; session pill unaffected |

## Test plan

### Unit (Vitest)

- `sessionMachine.test.ts` — happy-path transitions; rejected events asserted as no-ops; waiting room, reconnect, host-grace, sharer-revert deltas.
- `syncActor.test.ts` — producer throttling; consumer out-of-order drop by `ts`; mode-swap snapshot; annotation idempotence.
- `peerActor.test.ts` — SDP/ICE ordering; data-channel send routing; cleanup on stop.
- `micActor.test.ts` — self vs host mute distinction; remote-track attach/detach; permission-denied path.
- `fileTransferActor.test.ts` — sliding window; hash verification; failure on mismatch; backpressure.
- `reconnectActor.test.ts` — backoff schedule; `reservedUntil` ceiling; exhaustion.

### Integration (Vitest harness)

- `sharing.integration.test.ts` — in-memory mock Worker + DO connecting two `sessionMachine` instances; assert roster handshake, role transfer, mute, kick, approval queue, host grace + reconnect.
- `sync.integration.test.ts` — two real `playerMachine` instances bridged by real `syncActor`s over in-memory channel; assert position / TTS / annotation propagation within 200ms.

### Worker (`@cloudflare/vitest-pool-workers` in a sibling `apps/rishi-sharing-worker/`)

- DO state transitions (host suspension, slot reservation, cap, sharer revert).
- Rate-limit thresholds.
- JWT and joinToken validation (signature, expiry, audience).
- Approval queue end-to-end.

### E2E (Playwright)

- `sharing.e2e.ts` — two `electron.launch()` instances against `wrangler dev`:
  1. Host creates → viewer joins by link → both see roster.
  2. Sharer changes page → viewer follows.
  3. Sharer passes role → control transfers and works in reverse.
  4. Host kicks viewer → viewer returns to `idle` with reason.
  5. Host drops (close window) → viewer sees suspended banner; host reopens within 120s → resumed.
- `sharing.file-transfer.e2e.ts` — viewer joins without the book; completes P2P transfer; sync follows after.

### Manual verification before merge

- Real audio between two physical machines on different networks.
- macOS mic-permission dialog on fresh install (signed build, per existing entitlements).
- Windows signed build smoke test (per Windows signing infrastructure already in place).

## Out of scope (explicit non-goals for v1)

- Mobile (`apps/mobile`) and Web (`apps/web`) clients — copy the design, do not refactor; per project conventions, share via `packages/shared` if state shapes need to be reused.
- Video tracks.
- Session recording / playback.
- Text chat panel.
- TURN server deployment on `node1` — deferred until real-world ICE-failure rates justify it.
- LiveKit / SFU adoption — revisit only if cap rises above ~6 peers.
- Persistent friend list / contacts — invite is per-session via email search or link.

## File inventory (new + touched)

```
apps/rishi-electron/
  src/preload/ipc-contract.ts                                 (touched: add sharing:* channels)
  src/main/
    sharing/
      authToken.ts                                            (new: mint signaling JWT)
      userSearch.ts                                           (new: searchUsersByEmail)
      deepLink.ts                                             (new: rishi:// protocol handling + single-instance lock)
      libraryWrite.ts                                         (new: saveTransferredBook adapter)
    ipc/                                                      (touched: register sharing:* handlers)
  src/renderer/src/
    actors/sharing/
      signalingActor.ts
      peerActor.ts
      syncActor.ts
      micActor.ts
      fileTransferActor.ts
      reconnectActor.ts
      __tests__/
        signalingActor.test.ts
        peerActor.test.ts
        syncActor.test.ts
        micActor.test.ts
        fileTransferActor.test.ts
        reconnectActor.test.ts
    machines/
      sessionMachine.ts
      __tests__/
        sessionMachine.test.ts
        sessionMachine.recovery.test.ts
    components/sharing/
      StartSessionPopover.tsx
      SessionPanel.tsx
      ParticipantTile.tsx
      InvitePanel.tsx
      ApprovalQueueItem.tsx
      ApprovalWaitingScreen.tsx
      FileTransferRow.tsx
      HostSuspendedBanner.tsx
      RoleTransferToast.tsx
      KickedDialog.tsx
      MicChip.tsx
      CursorOverlay.tsx
      __tests__/
        SessionPanel.test.tsx
        InvitePanel.test.tsx
        ApprovalWaitingScreen.test.tsx
  electron-builder.yml                                        (touched: protocols.rishi)
  playwright/
    sharing.e2e.ts                                            (new)
    sharing.file-transfer.e2e.ts                              (new)

apps/rishi-sharing-worker/                                    (new project)
  wrangler.toml
  src/
    index.ts                                                  (HTTP routes + WS upgrade)
    SessionRoom.ts                                            (Durable Object class)
    auth.ts                                                   (JWT + HMAC token verification)
    tokens.ts                                                 (joinToken, reconnectToken issuance)
    rateLimit.ts
    schemas.ts                                                (Zod schemas for wire messages)
    __tests__/
      SessionRoom.test.ts
      auth.test.ts
      tokens.test.ts
      rateLimit.test.ts
```
