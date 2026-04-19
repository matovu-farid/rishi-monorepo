# Collaborative Reading Sessions — Design Spec

**Date:** 2026-04-13
**Status:** Draft

## Overview

A feature that lets up to 3 users join a live audio reading session where they can discuss a book together and ask AI questions about what they're reading. The host's reader view is streamed to all participants — no book files are transferred, avoiding intellectual property concerns.

**Platforms:** Desktop (Tauri) + Mobile (React Native), cross-platform sessions supported.

## Core Concepts

- **Reading session**: A real-time audio room tied to a specific book. One host, up to 2 guests.
- **Host**: The user who creates the session. Controls the reader view (page navigation, scroll, cursor). Their rendered page is streamed to participants.
- **Participant**: A user who joins the session. Sees a read-only mirror of the host's view with the host's cursor visible. Can talk and ask AI questions.
- **Screen streaming**: The host's page content is sent as structured data (HTML for reflowable formats, page images for fixed-layout formats) — not video.
- **Ask AI**: Any participant can ask the AI about the current page. The AI responds via TTS audio played to everyone.

## Data Model

All session-related tables live server-side in Cloudflare D1. No local sync — sessions are inherently online-only.

### `friends`

| Column    | Type      | Notes                              |
|-----------|-----------|------------------------------------|
| id        | UUID      | PK                                 |
| userId    | string    | Clerk user ID — the requester      |
| friendId  | string    | Clerk user ID — the recipient      |
| status    | enum      | `pending`, `accepted`, `blocked`   |
| createdAt | timestamp |                                    |
| updatedAt | timestamp |                                    |

Unique constraint on `(userId, friendId)`. Bidirectional: accepting creates the reverse row or queries check both directions.

### `reading_sessions`

| Column     | Type      | Notes                                  |
|------------|-----------|----------------------------------------|
| id         | UUID      | PK                                     |
| bookId     | UUID      | FK to books — the book being read      |
| hostId     | string    | Clerk user ID                          |
| inviteCode | string    | 6-char alphanumeric code (e.g. RK4729) |
| status     | enum      | `waiting`, `active`, `ended`           |
| createdAt  | timestamp |                                        |
| endedAt    | timestamp | nullable                               |

Unique index on `inviteCode` for lookup. `inviteCode` is generated server-side, collision-checked.

### `session_participants`

| Column    | Type      | Notes                 |
|-----------|-----------|-----------------------|
| id        | UUID      | PK                    |
| sessionId | UUID      | FK to reading_sessions|
| userId    | string    | Clerk user ID         |
| joinedAt  | timestamp |                       |
| leftAt    | timestamp | nullable              |

## Real-Time Infrastructure

### WebRTC P2P Mesh (Audio)

- Max 3 participants = each maintains 2 peer connections.
- Audio only — no video tracks.
- Codec: Opus (built-in to WebRTC, optimized for voice).
- Each peer connection carries one bidirectional audio stream.

### Signaling via Cloudflare Durable Objects

Each reading session maps to one Durable Object instance. The DO:

1. Maintains WebSocket connections to all participants (max 3).
2. Relays SDP offers/answers and ICE candidates for P2P setup.
3. Broadcasts session events (participant join/leave, page updates, cursor position, AI responses).
4. Enforces the 3-participant cap (rejects connections when full).

### TURN Server

- Required for NAT traversal fallback (~15% of connections need it).
- Use Cloudflare TURN, Metered, or Twilio as a pay-per-use service.
- ICE server configuration is sent to clients when they join a session.

### Connection Flow

```
Host creates session
  → Worker creates DO instance + session row in D1
  → Returns invite link + room code

Participant joins (via invite link, room code, or friends list)
  → Worker validates: session exists, not full, user authenticated
  → Connects WebSocket to the Durable Object
  → DO broadcasts "participant joined" to existing members
  → Existing members send SDP offers to new participant via DO
  → ICE candidates exchanged via DO
  → P2P audio connections established
```

## Screen Streaming

The host's reader view is streamed as structured content over the DO WebSocket — not as video. Participants render it locally.

### Reflowable Formats (EPUB, MOBI)

- Host's reader extracts current chapter HTML + scroll offset.
- Sent via DO: `{ type: "page_update", html: "...", scrollY: 0.45 }`
- Participants render the HTML in a read-only webview with identical styles.
- Updates sent on page turn and scroll (debounced).

### Fixed-Layout Formats (PDF, DJVU)

- Host renders current page to an image (canvas → WebP, ~100-200KB).
- Sent via DO on page change only.
- Participants display the image.
- Much lower bandwidth — pages only update on navigation.

### Cursor Streaming

- Host's pointer position sent at ~10fps via DO WebSocket.
- Message: `{ type: "cursor", x: 0.34, y: 0.67 }` (normalized 0-1 coordinates).
- Participants render a colored dot/pointer overlay on the content.

### Bandwidth Estimates (per participant)

- EPUB: ~5-50KB per page change + ~2KB/s cursor updates.
- PDF: ~100-200KB per page change + ~2KB/s cursor.
- Lightweight compared to video streaming.

## AI "Ask" Feature

Any participant can press the "Ask AI" button during a session.

### Flow

1. Participant taps "Ask AI" → records voice question via existing STT (Deepgram).
2. Transcribed question sent to DO: `{ type: "ai_ask", userId, question }`.
3. DO broadcasts "User X is asking the AI..." to all participants.
4. DO forwards request to Worker endpoint with the current page content.
5. Worker calls OpenAI completions with: page text + cursor position + question + book metadata.
6. Worker calls OpenAI TTS with the response.
7. Worker returns TTS audio URL to DO.
8. DO broadcasts: `{ type: "ai_response", audioUrl, question, userId }`.
9. All participants fetch and play the TTS audio simultaneously.

### Context Sent to AI

- Current page/chapter text (from the screen stream — already available).
- Cursor position (what area the asker is pointing at).
- Question transcript.
- Book metadata (title, author).

No local RAG needed for session AI — the page content is small enough to include directly as context.

### Cooldown

10-second cooldown after each AI answer to prevent spam. Visual cooldown indicator shown to all participants.

## Friends System

### Friend Request Flow

1. User searches by username or email → Worker queries Clerk for matching users.
2. Sends friend request → creates `friends` row with `status: pending`.
3. Recipient sees pending request on next app open (poll on launch).
4. Accept → status updates to `accepted`. Decline → row deleted.
5. Block → `status: blocked`. Blocked user cannot send requests or see active sessions.

### Friends List

- See online friends and their active reading sessions (book title, participant count).
- Tap to join an active session directly.
- Remove friend / block.

### Privacy

- Users can only see active sessions of accepted friends.
- No public session discovery.

## Join Mechanisms (Priority Order)

### 1. Invite Link (Primary)

- Host shares link: `https://rishi.app/join/RK4729`.
- Recipient opens → deep links into app (Tauri custom protocol / Expo universal link).
- App validates session → connects.

### 2. Friends List

- Participant sees friend's active session in friends list.
- Taps "Join" → connects directly.

### 3. Room Code (Fallback)

- Participant manually enters 6-char code in a "Join Session" sheet.
- Worker looks up session by `inviteCode` → connects.

## Session Lifecycle

### States

- `waiting` — host has created session, waiting for participants.
- `active` — at least 2 participants connected, audio flowing.
- `ended` — session terminated.

### Ending a Session

- Host leaves → session ends for everyone.
- Non-host leaves → session continues with remaining participants.
- Idle timeout: 5 minutes with no audio/interaction → auto-end.
- DO cleans up WebSocket connections and updates D1 status.

## Platform Implementation

### Desktop (Tauri)

- **WebRTC**: Native browser APIs in Tauri webview (`RTCPeerConnection`).
- **Audio capture**: Existing `tauri-plugin-mic-recorder-api`.
- **Screen stream renderer**: Read-only webview component for participants.
- **Deep links**: Existing Tauri custom protocol for invite links.
- **WebSocket**: Standard browser WebSocket API.

### Mobile (React Native)

- **WebRTC**: Existing `react-native-webrtc` package.
- **Audio capture**: Existing `expo-audio` setup.
- **Screen stream renderer**: `react-native-webview` for HTML content, `Image` for PDF pages.
- **Deep links**: Expo universal links.
- **WebSocket**: React Native built-in WebSocket.

### Shared Code (`@rishi/shared`)

- Session state machine (waiting → active → ended).
- WebRTC peer connection manager (create offer/answer, handle ICE, manage 2 connections).
- Cursor position normalization.
- AI ask flow (record → transcribe → send → play response).

## New UI Components (Both Platforms)

- **`SessionToolbar`** — start session, invite, end session (host only).
- **`SessionOverlay`** — join banner, participant avatars, mute/unmute.
- **`AskAIButton`** — floating button with cooldown indicator.
- **`ParticipantView`** — read-only mirrored reader for non-host participants.
- **`FriendsSheet`** — friend list, pending requests, active sessions.
- **`JoinSessionSheet`** — enter room code / accept invite.

## Cost Estimate

At 500 MAU with ~1,200 sessions/month:

| Service                | Monthly Cost |
|------------------------|-------------|
| Durable Objects        | ~$5         |
| TURN server            | ~$8         |
| D1 database            | $0          |
| R2 storage             | ~$1         |
| OpenAI TTS             | ~$45        |
| OpenAI completions     | ~$54        |
| Workers                | $0          |
| **Total**              | **~$113**   |

Baseline cost with no users: **$0/month** (all pay-per-use).

## Out of Scope

- Video streaming.
- Text chat within sessions (audio only).
- Session recording/playback.
- Public session discovery.
- Push notifications for friend requests (poll-based initially).
