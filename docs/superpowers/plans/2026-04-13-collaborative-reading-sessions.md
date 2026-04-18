# Collaborative Reading Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable up to 3 users to join a live audio reading session where the host's book view is streamed to participants, everyone can talk via WebRTC P2P audio, and anyone can ask the AI about the current page with voice answers.

**Architecture:** Cloudflare Durable Objects manage per-session WebSocket rooms for signaling, page streaming, and cursor sync. WebRTC P2P mesh (max 3 participants, 2 peer connections each) handles audio. The host's reader content (HTML for reflowable, images for fixed-layout) is sent as structured data over the DO WebSocket. AI questions use the current page text as context, with TTS responses played to all participants.

**Tech Stack:** Cloudflare Workers + Durable Objects + D1, WebRTC (browser API on desktop, react-native-webrtc on mobile), Hono router, Drizzle ORM, Jotai atoms (desktop), React hooks, Radix UI / shadcn (desktop), NativeWind + @gorhom/bottom-sheet (mobile), OpenAI TTS + completions, Deepgram STT.

---

## File Structure

### Worker (workers/worker/)

| File | Responsibility |
|------|---------------|
| `src/db/schema.ts` (new) | Drizzle schema for friends, reading_sessions, session_participants |
| `src/routes/friends.ts` (new) | Friend request CRUD endpoints |
| `src/routes/sessions.ts` (new) | Session create/join/leave/status endpoints |
| `src/durable-objects/session-room.ts` (new) | Durable Object: WebSocket room for signaling, page streaming, cursor relay |
| `src/index.ts` (modify) | Mount new routes, export DO class |
| `wrangler.jsonc` (modify) | Add DO binding and migration |
| `drizzle/migrations/0001_reading_sessions.sql` (new) | D1 migration for new tables |

### Shared (packages/shared/)

| File | Responsibility |
|------|---------------|
| `src/session-types.ts` (new) | TypeScript types for session WebSocket messages, session state |
| `src/index.ts` (modify) | Re-export session types |

### Desktop (apps/main/)

| File | Responsibility |
|------|---------------|
| `src/stores/session_atoms.ts` (new) | Jotai atoms for session state |
| `src/hooks/useSessionHost.ts` (new) | Host-side logic: create session, stream page, send cursor |
| `src/hooks/useSessionParticipant.ts` (new) | Participant-side logic: receive page stream, render cursor |
| `src/hooks/useSessionAudio.ts` (new) | WebRTC P2P audio mesh management |
| `src/hooks/useSessionAI.ts` (new) | Ask AI: record question, receive TTS, play to all |
| `src/hooks/useFriends.ts` (new) | Friends list CRUD |
| `src/components/session/SessionToolbar.tsx` (new) | Start/end session, invite, participant count |
| `src/components/session/SessionOverlay.tsx` (new) | Participant avatars, mute/unmute, host cursor |
| `src/components/session/ParticipantView.tsx` (new) | Read-only mirrored reader view |
| `src/components/session/AskAIButton.tsx` (new) | Floating AI button with cooldown |
| `src/components/session/JoinSessionSheet.tsx` (new) | Enter room code / accept invite |
| `src/components/session/FriendsSheet.tsx` (new) | Friends list, requests, active sessions |
| `src/components/epub.tsx` (modify) | Add page content extraction for streaming |
| `src/components/pdf/components/pdf.tsx` (modify) | Add page image capture for streaming |
| `src/components/LoginButton.tsx` (modify) | Handle session invite deep links |

### Mobile (apps/mobile/)

| File | Responsibility |
|------|---------------|
| `hooks/useSessionHost.ts` (new) | Host-side logic (mirrors desktop) |
| `hooks/useSessionParticipant.ts` (new) | Participant-side logic (mirrors desktop) |
| `hooks/useSessionAudio.ts` (new) | WebRTC P2P audio via react-native-webrtc |
| `hooks/useSessionAI.ts` (new) | Ask AI flow |
| `hooks/useFriends.ts` (new) | Friends list CRUD |
| `components/session/SessionToolbar.tsx` (new) | Start/end session, invite |
| `components/session/SessionOverlay.tsx` (new) | Participant avatars, mute/unmute |
| `components/session/ParticipantView.tsx` (new) | Read-only mirrored view |
| `components/session/AskAIButton.tsx` (new) | Floating AI button |
| `components/session/JoinSessionSheet.tsx` (new) | Room code entry |
| `components/session/FriendsSheet.tsx` (new) | Friends list |
| `app/reader/[id].tsx` (modify) | Integrate session toolbar + page extraction |
| `app/(tabs)/index.tsx` (modify) | Add friends tab entry point |

---

## Task 1: D1 Schema & Migration

**Files:**
- Create: `workers/worker/src/db/schema.ts`
- Create: `workers/worker/drizzle/migrations/0001_reading_sessions.sql`
- Modify: `packages/shared/src/schema.ts` (add new tables)

- [ ] **Step 1: Add table definitions to shared schema**

Add to the end of `packages/shared/src/schema.ts`:

```typescript
// ─── Reading Sessions ───────────────────────────────────────────

export const friends = sqliteTable("friends", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  friendId: text("friend_id").notNull(),
  status: text("status").notNull().default("pending"), // pending | accepted | blocked
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
});

export type Friend = typeof friends.$inferSelect;
export type NewFriend = typeof friends.$inferInsert;

export const readingSessions = sqliteTable("reading_sessions", {
  id: text("id").primaryKey(),
  bookId: text("book_id").notNull(),
  hostId: text("host_id").notNull(),
  bookTitle: text("book_title").notNull(),
  bookAuthor: text("book_author").notNull().default("Unknown"),
  inviteCode: text("invite_code").notNull(),
  status: text("status").notNull().default("waiting"), // waiting | active | ended
  createdAt: integer("created_at").notNull(),
  endedAt: integer("ended_at"),
});

export type ReadingSession = typeof readingSessions.$inferSelect;
export type NewReadingSession = typeof readingSessions.$inferInsert;

export const sessionParticipants = sqliteTable("session_participants", {
  id: text("id").primaryKey(),
  sessionId: text("session_id").notNull(),
  userId: text("user_id").notNull(),
  joinedAt: integer("joined_at").notNull(),
  leftAt: integer("left_at"),
});

export type SessionParticipant = typeof sessionParticipants.$inferSelect;
export type NewSessionParticipant = typeof sessionParticipants.$inferInsert;
```

- [ ] **Step 2: Create D1 migration file**

Create `workers/worker/drizzle/migrations/0001_reading_sessions.sql`:

```sql
CREATE TABLE IF NOT EXISTS friends (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  friend_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(user_id, friend_id)
);

CREATE INDEX idx_friends_user ON friends(user_id);
CREATE INDEX idx_friends_friend ON friends(friend_id);
CREATE INDEX idx_friends_status ON friends(user_id, status);

CREATE TABLE IF NOT EXISTS reading_sessions (
  id TEXT PRIMARY KEY,
  book_id TEXT NOT NULL,
  host_id TEXT NOT NULL,
  book_title TEXT NOT NULL,
  book_author TEXT NOT NULL DEFAULT 'Unknown',
  invite_code TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'waiting',
  created_at INTEGER NOT NULL,
  ended_at INTEGER
);

CREATE INDEX idx_sessions_host ON reading_sessions(host_id);
CREATE INDEX idx_sessions_invite ON reading_sessions(invite_code);
CREATE INDEX idx_sessions_status ON reading_sessions(status);

CREATE TABLE IF NOT EXISTS session_participants (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  left_at INTEGER,
  FOREIGN KEY (session_id) REFERENCES reading_sessions(id)
);

CREATE INDEX idx_participants_session ON session_participants(session_id);
CREATE INDEX idx_participants_user ON session_participants(user_id);
```

- [ ] **Step 3: Run migration against D1**

```bash
cd workers/worker && npx wrangler d1 execute rishi-db --file=drizzle/migrations/0001_reading_sessions.sql --remote
```

Expected: `Executed 9 commands` (3 tables + 6 indexes).

- [ ] **Step 4: Commit**

```bash
git add packages/shared/src/schema.ts workers/worker/drizzle/migrations/0001_reading_sessions.sql
git commit -m "feat: add D1 schema for friends and reading sessions"
```

---

## Task 2: Shared Session Types

**Files:**
- Create: `packages/shared/src/session-types.ts`
- Modify: `packages/shared/src/index.ts`

- [ ] **Step 1: Create session message types**

Create `packages/shared/src/session-types.ts`:

```typescript
// ─── Session WebSocket Messages ─────────────────────────────────

/** Client → Server (via DO WebSocket) */
export type ClientSessionMessage =
  | { type: "sdp_offer"; targetUserId: string; sdp: RTCSessionDescriptionInit }
  | { type: "sdp_answer"; targetUserId: string; sdp: RTCSessionDescriptionInit }
  | { type: "ice_candidate"; targetUserId: string; candidate: RTCIceCandidateInit }
  | { type: "page_update"; html?: string; imageBase64?: string; scrollY: number; format: "reflowable" | "fixed" }
  | { type: "cursor_move"; x: number; y: number }
  | { type: "ai_ask"; question: string; pageText: string }
  | { type: "leave" };

/** Server → Client (via DO WebSocket) */
export type ServerSessionMessage =
  | { type: "participant_joined"; userId: string; displayName: string; participantCount: number }
  | { type: "participant_left"; userId: string; participantCount: number }
  | { type: "sdp_offer"; fromUserId: string; sdp: RTCSessionDescriptionInit }
  | { type: "sdp_answer"; fromUserId: string; sdp: RTCSessionDescriptionInit }
  | { type: "ice_candidate"; fromUserId: string; candidate: RTCIceCandidateInit }
  | { type: "page_update"; html?: string; imageBase64?: string; scrollY: number; format: "reflowable" | "fixed" }
  | { type: "cursor_move"; x: number; y: number }
  | { type: "ai_asking"; userId: string; displayName: string; question: string }
  | { type: "ai_response"; audioUrl: string; question: string; userId: string }
  | { type: "ai_error"; error: string }
  | { type: "session_ended"; reason: string }
  | { type: "error"; message: string };

/** Session info returned by REST endpoints */
export interface SessionInfo {
  id: string;
  bookId: string;
  bookTitle: string;
  bookAuthor: string;
  hostId: string;
  inviteCode: string;
  status: "waiting" | "active" | "ended";
  participantCount: number;
  participants: { userId: string; displayName: string }[];
  createdAt: number;
}

/** Friend with display info */
export interface FriendInfo {
  id: string;
  userId: string;
  displayName: string;
  email: string;
  status: "pending" | "accepted" | "blocked";
  activeSession: SessionInfo | null;
}

/** ICE server config sent to clients on join */
export interface IceServerConfig {
  urls: string | string[];
  username?: string;
  credential?: string;
}
```

- [ ] **Step 2: Export from shared index**

Add to `packages/shared/src/index.ts`:

```typescript
export * from "./session-types";
```

- [ ] **Step 3: Commit**

```bash
git add packages/shared/src/session-types.ts packages/shared/src/index.ts
git commit -m "feat: add shared TypeScript types for reading sessions"
```

---

## Task 3: Friends API Routes

**Files:**
- Create: `workers/worker/src/routes/friends.ts`
- Modify: `workers/worker/src/index.ts`

- [ ] **Step 1: Create friends route file**

Create `workers/worker/src/routes/friends.ts`:

```typescript
import { Hono } from "hono";
import { eq, and, or, desc } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { friends } from "@rishi/shared/schema";
import { requireWorkerAuth } from "../index";
import type { CloudflareBindings } from "../index";

export const friendsRoutes = new Hono<{
  Bindings: CloudflareBindings;
  Variables: { userId: string };
}>();

// List accepted friends + pending incoming requests
friendsRoutes.get("/", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const db = drizzle(c.env.DB);

  const rows = await db
    .select()
    .from(friends)
    .where(
      or(
        and(eq(friends.userId, userId), eq(friends.status, "accepted")),
        and(eq(friends.friendId, userId), eq(friends.status, "accepted")),
        and(eq(friends.friendId, userId), eq(friends.status, "pending"))
      )
    )
    .orderBy(desc(friends.updatedAt));

  return c.json({ friends: rows });
});

// Send friend request
friendsRoutes.post("/request", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const { friendEmail } = await c.req.json<{ friendEmail: string }>();
  const db = drizzle(c.env.DB);

  // Look up friend's Clerk user ID by email
  const clerkRes = await fetch(
    `https://api.clerk.com/v1/users?email_address=${encodeURIComponent(friendEmail)}`,
    { headers: { Authorization: `Bearer ${c.env.CLERK_SECRET_KEY}` } }
  );
  const clerkUsers = await clerkRes.json<any[]>();
  if (!clerkUsers.length) {
    return c.json({ error: "User not found" }, 404);
  }

  const friendId = clerkUsers[0].id;
  if (friendId === userId) {
    return c.json({ error: "Cannot add yourself" }, 400);
  }

  // Check for existing relationship
  const existing = await db
    .select()
    .from(friends)
    .where(
      or(
        and(eq(friends.userId, userId), eq(friends.friendId, friendId)),
        and(eq(friends.userId, friendId), eq(friends.friendId, userId))
      )
    )
    .get();

  if (existing) {
    if (existing.status === "blocked") {
      return c.json({ error: "Cannot send request" }, 403);
    }
    return c.json({ error: "Request already exists" }, 409);
  }

  const now = Date.now();
  const id = crypto.randomUUID();
  await db.insert(friends).values({
    id,
    userId,
    friendId,
    status: "pending",
    createdAt: now,
    updatedAt: now,
  });

  return c.json({ id, status: "pending" }, 201);
});

// Accept friend request
friendsRoutes.post("/accept", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const { requestId } = await c.req.json<{ requestId: string }>();
  const db = drizzle(c.env.DB);

  const request = await db
    .select()
    .from(friends)
    .where(and(eq(friends.id, requestId), eq(friends.friendId, userId), eq(friends.status, "pending")))
    .get();

  if (!request) {
    return c.json({ error: "Request not found" }, 404);
  }

  await db
    .update(friends)
    .set({ status: "accepted", updatedAt: Date.now() })
    .where(eq(friends.id, requestId));

  return c.json({ status: "accepted" });
});

// Decline or remove friend
friendsRoutes.delete("/:id", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const db = drizzle(c.env.DB);

  const row = await db
    .select()
    .from(friends)
    .where(
      and(
        eq(friends.id, id),
        or(eq(friends.userId, userId), eq(friends.friendId, userId))
      )
    )
    .get();

  if (!row) {
    return c.json({ error: "Not found" }, 404);
  }

  await db.delete(friends).where(eq(friends.id, id));
  return c.json({ deleted: true });
});

// Block user
friendsRoutes.post("/block", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const { targetUserId } = await c.req.json<{ targetUserId: string }>();
  const db = drizzle(c.env.DB);

  // Upsert: update existing or create new blocked entry
  const existing = await db
    .select()
    .from(friends)
    .where(
      or(
        and(eq(friends.userId, userId), eq(friends.friendId, targetUserId)),
        and(eq(friends.userId, targetUserId), eq(friends.friendId, userId))
      )
    )
    .get();

  const now = Date.now();
  if (existing) {
    await db
      .update(friends)
      .set({ userId, friendId: targetUserId, status: "blocked", updatedAt: now })
      .where(eq(friends.id, existing.id));
  } else {
    await db.insert(friends).values({
      id: crypto.randomUUID(),
      userId,
      friendId: targetUserId,
      status: "blocked",
      createdAt: now,
      updatedAt: now,
    });
  }

  return c.json({ status: "blocked" });
});

// Search users by email (for adding friends)
friendsRoutes.get("/search", requireWorkerAuth, async (c) => {
  const query = c.req.query("q");
  if (!query || query.length < 3) {
    return c.json({ users: [] });
  }

  const clerkRes = await fetch(
    `https://api.clerk.com/v1/users?query=${encodeURIComponent(query)}&limit=10`,
    { headers: { Authorization: `Bearer ${c.env.CLERK_SECRET_KEY}` } }
  );
  const clerkUsers = await clerkRes.json<any[]>();

  const users = clerkUsers.map((u: any) => ({
    id: u.id,
    displayName: `${u.first_name ?? ""} ${u.last_name ?? ""}`.trim() || u.username || "Unknown",
    email: u.email_addresses?.[0]?.email_address ?? "",
    imageUrl: u.image_url,
  }));

  return c.json({ users });
});
```

- [ ] **Step 2: Mount friends routes in index.ts**

Add to `workers/worker/src/index.ts` after the existing route mounts:

```typescript
import { friendsRoutes } from "./routes/friends";

// Add after existing app.route() calls:
app.route("/api/friends", friendsRoutes);
```

- [ ] **Step 3: Commit**

```bash
git add workers/worker/src/routes/friends.ts workers/worker/src/index.ts
git commit -m "feat: add friends API routes (search, request, accept, block, remove)"
```

---

## Task 4: Sessions API Routes

**Files:**
- Create: `workers/worker/src/routes/sessions.ts`
- Modify: `workers/worker/src/index.ts`

- [ ] **Step 1: Create sessions route file**

Create `workers/worker/src/routes/sessions.ts`:

```typescript
import { Hono } from "hono";
import { eq, and, isNull, ne } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { readingSessions, sessionParticipants, friends } from "@rishi/shared/schema";
import { requireWorkerAuth } from "../index";
import type { CloudflareBindings } from "../index";
import type { SessionInfo } from "@rishi/shared";

export const sessionsRoutes = new Hono<{
  Bindings: CloudflareBindings;
  Variables: { userId: string };
}>();

function generateInviteCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // No I/O/1/0 to avoid confusion
  let code = "";
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  for (const b of bytes) {
    code += chars[b % chars.length];
  }
  return code;
}

// Create a new session
sessionsRoutes.post("/create", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const { bookId, bookTitle, bookAuthor } = await c.req.json<{
    bookId: string;
    bookTitle: string;
    bookAuthor: string;
  }>();
  const db = drizzle(c.env.DB);

  // End any existing active sessions for this host
  await db
    .update(readingSessions)
    .set({ status: "ended", endedAt: Date.now() })
    .where(and(eq(readingSessions.hostId, userId), ne(readingSessions.status, "ended")));

  const sessionId = crypto.randomUUID();
  const inviteCode = generateInviteCode();
  const now = Date.now();

  await db.insert(readingSessions).values({
    id: sessionId,
    bookId,
    bookTitle,
    bookAuthor,
    hostId: userId,
    inviteCode,
    status: "waiting",
    createdAt: now,
  });

  // Add host as first participant
  await db.insert(sessionParticipants).values({
    id: crypto.randomUUID(),
    sessionId,
    userId,
    joinedAt: now,
  });

  return c.json({
    id: sessionId,
    inviteCode,
    inviteLink: `https://rishi.fidexa.org/join/${inviteCode}`,
  }, 201);
});

// Get session info by invite code
sessionsRoutes.get("/join/:inviteCode", requireWorkerAuth, async (c) => {
  const inviteCode = c.req.param("inviteCode");
  const db = drizzle(c.env.DB);

  const session = await db
    .select()
    .from(readingSessions)
    .where(and(eq(readingSessions.inviteCode, inviteCode), ne(readingSessions.status, "ended")))
    .get();

  if (!session) {
    return c.json({ error: "Session not found or ended" }, 404);
  }

  const participants = await db
    .select()
    .from(sessionParticipants)
    .where(and(eq(sessionParticipants.sessionId, session.id), isNull(sessionParticipants.leftAt)));

  if (participants.length >= 3) {
    return c.json({ error: "Session is full" }, 403);
  }

  // Fetch display names from Clerk
  const participantInfos = await Promise.all(
    participants.map(async (p) => {
      const res = await fetch(`https://api.clerk.com/v1/users/${p.userId}`, {
        headers: { Authorization: `Bearer ${c.env.CLERK_SECRET_KEY}` },
      });
      const user = await res.json<any>();
      return {
        userId: p.userId,
        displayName: `${user.first_name ?? ""} ${user.last_name ?? ""}`.trim() || "Unknown",
      };
    })
  );

  const info: SessionInfo = {
    id: session.id,
    bookId: session.bookId,
    bookTitle: session.bookTitle,
    bookAuthor: session.bookAuthor,
    hostId: session.hostId,
    inviteCode: session.inviteCode,
    status: session.status as SessionInfo["status"],
    participantCount: participants.length,
    participants: participantInfos,
    createdAt: session.createdAt,
  };

  return c.json(info);
});

// Join a session (record participation)
sessionsRoutes.post("/join/:sessionId", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const sessionId = c.req.param("sessionId");
  const db = drizzle(c.env.DB);

  const session = await db
    .select()
    .from(readingSessions)
    .where(and(eq(readingSessions.id, sessionId), ne(readingSessions.status, "ended")))
    .get();

  if (!session) {
    return c.json({ error: "Session not found or ended" }, 404);
  }

  const activeParticipants = await db
    .select()
    .from(sessionParticipants)
    .where(and(eq(sessionParticipants.sessionId, sessionId), isNull(sessionParticipants.leftAt)));

  if (activeParticipants.length >= 3) {
    return c.json({ error: "Session is full" }, 403);
  }

  // Check if already in session
  const existing = activeParticipants.find((p) => p.userId === userId);
  if (existing) {
    return c.json({ alreadyJoined: true });
  }

  await db.insert(sessionParticipants).values({
    id: crypto.randomUUID(),
    sessionId,
    userId,
    joinedAt: Date.now(),
  });

  // Update session status to active if now 2+ participants
  if (activeParticipants.length + 1 >= 2 && session.status === "waiting") {
    await db
      .update(readingSessions)
      .set({ status: "active" })
      .where(eq(readingSessions.id, sessionId));
  }

  return c.json({ joined: true });
});

// Leave a session
sessionsRoutes.post("/leave/:sessionId", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const sessionId = c.req.param("sessionId");
  const db = drizzle(c.env.DB);

  const session = await db
    .select()
    .from(readingSessions)
    .where(eq(readingSessions.id, sessionId))
    .get();

  if (!session) {
    return c.json({ error: "Session not found" }, 404);
  }

  // If host leaves, end the entire session
  if (session.hostId === userId) {
    await db
      .update(readingSessions)
      .set({ status: "ended", endedAt: Date.now() })
      .where(eq(readingSessions.id, sessionId));

    // Mark all participants as left
    await db
      .update(sessionParticipants)
      .set({ leftAt: Date.now() })
      .where(and(eq(sessionParticipants.sessionId, sessionId), isNull(sessionParticipants.leftAt)));

    return c.json({ ended: true, reason: "host_left" });
  }

  // Non-host leaves
  await db
    .update(sessionParticipants)
    .set({ leftAt: Date.now() })
    .where(and(eq(sessionParticipants.sessionId, sessionId), eq(sessionParticipants.userId, userId)));

  return c.json({ left: true });
});

// Get active sessions for user's friends
sessionsRoutes.get("/friends-active", requireWorkerAuth, async (c) => {
  const userId = c.get("userId");
  const db = drizzle(c.env.DB);

  // Get accepted friend IDs
  const friendRows = await db
    .select()
    .from(friends)
    .where(
      and(
        eq(friends.status, "accepted"),
        eq(friends.userId, userId)
      )
    );

  const friendRowsReverse = await db
    .select()
    .from(friends)
    .where(
      and(
        eq(friends.status, "accepted"),
        eq(friends.friendId, userId)
      )
    );

  const friendIds = [
    ...friendRows.map((f) => f.friendId),
    ...friendRowsReverse.map((f) => f.userId),
  ];

  if (friendIds.length === 0) {
    return c.json({ sessions: [] });
  }

  // Get active sessions hosted by friends
  const activeSessions: SessionInfo[] = [];
  for (const friendId of friendIds) {
    const session = await db
      .select()
      .from(readingSessions)
      .where(and(eq(readingSessions.hostId, friendId), ne(readingSessions.status, "ended")))
      .get();

    if (session) {
      const participants = await db
        .select()
        .from(sessionParticipants)
        .where(and(eq(sessionParticipants.sessionId, session.id), isNull(sessionParticipants.leftAt)));

      activeSessions.push({
        id: session.id,
        bookId: session.bookId,
        bookTitle: session.bookTitle,
        bookAuthor: session.bookAuthor,
        hostId: session.hostId,
        inviteCode: session.inviteCode,
        status: session.status as SessionInfo["status"],
        participantCount: participants.length,
        participants: [],
        createdAt: session.createdAt,
      });
    }
  }

  return c.json({ sessions: activeSessions });
});
```

- [ ] **Step 2: Mount sessions routes in index.ts**

Add to `workers/worker/src/index.ts`:

```typescript
import { sessionsRoutes } from "./routes/sessions";

// Add after friends route mount:
app.route("/api/sessions", sessionsRoutes);
```

- [ ] **Step 3: Commit**

```bash
git add workers/worker/src/routes/sessions.ts workers/worker/src/index.ts
git commit -m "feat: add session REST API routes (create, join, leave, friends-active)"
```

---

## Task 5: Durable Object — Session Room

**Files:**
- Create: `workers/worker/src/durable-objects/session-room.ts`
- Modify: `workers/worker/src/index.ts`
- Modify: `workers/worker/wrangler.jsonc`

- [ ] **Step 1: Create the Durable Object class**

Create `workers/worker/src/durable-objects/session-room.ts`:

```typescript
import type { ClientSessionMessage, ServerSessionMessage } from "@rishi/shared";

interface Participant {
  userId: string;
  displayName: string;
  ws: WebSocket;
}

export class SessionRoom implements DurableObject {
  private participants: Map<string, Participant> = new Map();
  private hostId: string | null = null;
  private idleTimeout: number | null = null;
  private env: any;
  private state: DurableObjectState;

  constructor(state: DurableObjectState, env: any) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/websocket") {
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("Expected websocket", { status: 426 });
      }

      const userId = url.searchParams.get("userId");
      const displayName = url.searchParams.get("displayName") ?? "Unknown";
      const isHost = url.searchParams.get("isHost") === "true";

      if (!userId) {
        return new Response("Missing userId", { status: 400 });
      }

      if (this.participants.size >= 3) {
        return new Response("Session full", { status: 403 });
      }

      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);

      this.state.acceptWebSocket(server);

      if (isHost) {
        this.hostId = userId;
      }

      this.participants.set(userId, { userId, displayName, ws: server });
      this.resetIdleTimeout();

      // Notify existing participants
      this.broadcast({
        type: "participant_joined",
        userId,
        displayName,
        participantCount: this.participants.size,
      }, userId);

      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response("Not found", { status: 404 });
  }

  async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const sender = this.findParticipantByWs(ws);
    if (!sender) return;

    this.resetIdleTimeout();

    const msg = JSON.parse(data as string) as ClientSessionMessage;

    switch (msg.type) {
      case "sdp_offer":
      case "sdp_answer":
      case "ice_candidate": {
        // Relay signaling to target peer
        const target = this.participants.get(msg.targetUserId);
        if (target) {
          const relayed: ServerSessionMessage = {
            ...msg,
            type: msg.type,
            fromUserId: sender.userId,
            ...(msg.type === "sdp_offer" ? { sdp: msg.sdp } :
              msg.type === "sdp_answer" ? { sdp: msg.sdp } :
              { candidate: msg.candidate }),
          } as any;
          target.ws.send(JSON.stringify(relayed));
        }
        break;
      }

      case "page_update": {
        // Only host can send page updates
        if (sender.userId !== this.hostId) return;
        this.broadcast({
          type: "page_update",
          html: msg.html,
          imageBase64: msg.imageBase64,
          scrollY: msg.scrollY,
          format: msg.format,
        }, sender.userId);
        break;
      }

      case "cursor_move": {
        // Only host sends cursor
        if (sender.userId !== this.hostId) return;
        this.broadcast({
          type: "cursor_move",
          x: msg.x,
          y: msg.y,
        }, sender.userId);
        break;
      }

      case "ai_ask": {
        // Broadcast that someone is asking
        this.broadcast({
          type: "ai_asking",
          userId: sender.userId,
          displayName: sender.displayName,
          question: msg.question,
        });

        // Call the AI endpoint
        try {
          const aiResponse = await this.callAI(msg.question, msg.pageText);
          this.broadcast({
            type: "ai_response",
            audioUrl: aiResponse.audioUrl,
            question: msg.question,
            userId: sender.userId,
          });
        } catch (err) {
          this.broadcast({
            type: "ai_error",
            error: "Failed to get AI response",
          });
        }
        break;
      }

      case "leave": {
        this.removeParticipant(sender.userId);
        break;
      }
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const participant = this.findParticipantByWs(ws);
    if (participant) {
      this.removeParticipant(participant.userId);
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    const participant = this.findParticipantByWs(ws);
    if (participant) {
      this.removeParticipant(participant.userId);
    }
  }

  private removeParticipant(userId: string): void {
    this.participants.delete(userId);

    if (userId === this.hostId) {
      // Host left — end session for everyone
      this.broadcast({ type: "session_ended", reason: "host_left" });
      for (const p of this.participants.values()) {
        p.ws.close(1000, "Session ended");
      }
      this.participants.clear();
    } else {
      this.broadcast({
        type: "participant_left",
        userId,
        participantCount: this.participants.size,
      });
    }
  }

  private broadcast(msg: ServerSessionMessage, excludeUserId?: string): void {
    const data = JSON.stringify(msg);
    for (const [uid, p] of this.participants) {
      if (uid !== excludeUserId) {
        try {
          p.ws.send(data);
        } catch {
          // WebSocket dead — will be cleaned up on close event
        }
      }
    }
  }

  private findParticipantByWs(ws: WebSocket): Participant | undefined {
    for (const p of this.participants.values()) {
      if (p.ws === ws) return p;
    }
    return undefined;
  }

  private resetIdleTimeout(): void {
    if (this.idleTimeout) {
      clearTimeout(this.idleTimeout);
    }
    // 5 minute idle timeout
    this.idleTimeout = setTimeout(() => {
      this.broadcast({ type: "session_ended", reason: "idle_timeout" });
      for (const p of this.participants.values()) {
        p.ws.close(1000, "Idle timeout");
      }
      this.participants.clear();
    }, 5 * 60 * 1000) as unknown as number;
  }

  private async callAI(question: string, pageText: string): Promise<{ audioUrl: string }> {
    // Step 1: Get text answer from OpenAI
    const completionRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [
          {
            role: "system",
            content: "You are a helpful reading assistant. Answer questions about the text the user is currently reading. Keep answers concise (2-3 sentences) since they will be read aloud.",
          },
          {
            role: "user",
            content: `Here is the page I'm reading:\n\n${pageText}\n\nMy question: ${question}`,
          },
        ],
        max_tokens: 200,
      }),
    });

    const completion = await completionRes.json<any>();
    const answerText = completion.choices[0].message.content;

    // Step 2: Convert answer to speech via OpenAI TTS
    const ttsRes = await fetch("https://api.openai.com/v1/audio/speech", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: "tts-1",
        input: answerText,
        voice: "nova",
        response_format: "mp3",
      }),
    });

    // Step 3: Store audio in R2 and return URL
    const audioBuffer = await ttsRes.arrayBuffer();
    const audioKey = `session-ai/${crypto.randomUUID()}.mp3`;
    await this.env.BOOK_STORAGE.put(audioKey, audioBuffer, {
      httpMetadata: { contentType: "audio/mpeg" },
    });

    // Generate presigned URL (valid for 1 hour)
    const audioUrl = `https://rishi.fidexa.org/api/sessions/ai-audio/${audioKey}`;
    return { audioUrl };
  }
}
```

- [ ] **Step 2: Update wrangler.jsonc to register the Durable Object**

Add to `workers/worker/wrangler.jsonc`:

```jsonc
{
  // ... existing config ...
  "durable_objects": {
    "bindings": [
      {
        "name": "SESSION_ROOM",
        "class_name": "SessionRoom"
      }
    ]
  },
  "migrations": [
    {
      "tag": "v1",
      "new_classes": ["SessionRoom"]
    }
  ]
}
```

- [ ] **Step 3: Export the DO class and add WebSocket upgrade route in index.ts**

Add to `workers/worker/src/index.ts`:

```typescript
export { SessionRoom } from "./durable-objects/session-room";

// Add route for WebSocket upgrade to DO
app.get("/api/sessions/ws/:sessionId", requireWorkerAuth, async (c) => {
  const sessionId = c.req.param("sessionId");
  const userId = c.get("userId");
  const displayName = c.req.query("displayName") ?? "Unknown";
  const isHost = c.req.query("isHost") ?? "false";

  const doId = c.env.SESSION_ROOM.idFromName(sessionId);
  const stub = c.env.SESSION_ROOM.get(doId);

  const url = new URL(c.req.url);
  url.pathname = "/websocket";
  url.searchParams.set("userId", userId);
  url.searchParams.set("displayName", displayName);
  url.searchParams.set("isHost", isHost);

  return stub.fetch(new Request(url.toString(), {
    headers: c.req.raw.headers,
  }));
});

// Add route for serving AI audio from R2
app.get("/api/sessions/ai-audio/*", requireWorkerAuth, async (c) => {
  const key = c.req.path.replace("/api/sessions/ai-audio/", "");
  const object = await c.env.BOOK_STORAGE.get(key);
  if (!object) {
    return c.json({ error: "Not found" }, 404);
  }
  return new Response(object.body, {
    headers: { "Content-Type": "audio/mpeg" },
  });
});
```

- [ ] **Step 4: Add SESSION_ROOM to CloudflareBindings type**

In `workers/worker/src/index.ts`, update the `CloudflareBindings` type to include:

```typescript
SESSION_ROOM: DurableObjectNamespace;
```

- [ ] **Step 5: Commit**

```bash
git add workers/worker/src/durable-objects/session-room.ts workers/worker/src/index.ts workers/worker/wrangler.jsonc
git commit -m "feat: add SessionRoom Durable Object for WebSocket signaling and AI relay"
```

---

## Task 6: Desktop — Session Atoms & Audio Hook

**Files:**
- Create: `apps/main/src/stores/session_atoms.ts`
- Create: `apps/main/src/hooks/useSessionAudio.ts`

- [ ] **Step 1: Create session atoms**

Create `apps/main/src/stores/session_atoms.ts`:

```typescript
import { atom } from "jotai";

export type SessionRole = "host" | "participant";
export type SessionStatus = "idle" | "connecting" | "waiting" | "active" | "ended";

export interface SessionParticipantInfo {
  userId: string;
  displayName: string;
  isMuted: boolean;
}

export const sessionIdAtom = atom<string | null>(null);
sessionIdAtom.debugLabel = "sessionIdAtom";

export const sessionRoleAtom = atom<SessionRole | null>(null);
sessionRoleAtom.debugLabel = "sessionRoleAtom";

export const sessionStatusAtom = atom<SessionStatus>("idle");
sessionStatusAtom.debugLabel = "sessionStatusAtom";

export const sessionParticipantsAtom = atom<SessionParticipantInfo[]>([]);
sessionParticipantsAtom.debugLabel = "sessionParticipantsAtom";

export const sessionInviteCodeAtom = atom<string | null>(null);
sessionInviteCodeAtom.debugLabel = "sessionInviteCodeAtom";

export const sessionWebSocketAtom = atom<WebSocket | null>(null);
sessionWebSocketAtom.debugLabel = "sessionWebSocketAtom";

export const isMutedAtom = atom<boolean>(false);
isMutedAtom.debugLabel = "isMutedAtom";

export const aiCooldownAtom = atom<boolean>(false);
aiCooldownAtom.debugLabel = "aiCooldownAtom";

export const aiAskingAtom = atom<{ userId: string; displayName: string; question: string } | null>(null);
aiAskingAtom.debugLabel = "aiAskingAtom";
```

- [ ] **Step 2: Create WebRTC audio hook**

Create `apps/main/src/hooks/useSessionAudio.ts`:

```typescript
import { useAtom } from "jotai";
import { useCallback, useEffect, useRef } from "react";
import {
  sessionWebSocketAtom,
  sessionParticipantsAtom,
  isMutedAtom,
} from "../stores/session_atoms";
import type { ServerSessionMessage, ClientSessionMessage } from "@rishi/shared";

interface PeerConnection {
  pc: RTCPeerConnection;
  userId: string;
  audioStream: MediaStream | null;
}

const ICE_SERVERS: RTCConfiguration = {
  iceServers: [
    { urls: "stun:stun.l.google.com:19302" },
    // TURN server config will be fetched from the worker at join time
  ],
};

export function useSessionAudio() {
  const [ws] = useAtom(sessionWebSocketAtom);
  const [, setParticipants] = useAtom(sessionParticipantsAtom);
  const [isMuted] = useAtom(isMutedAtom);
  const peersRef = useRef<Map<string, PeerConnection>>(new Map());
  const localStreamRef = useRef<MediaStream | null>(null);
  const audioElementsRef = useRef<Map<string, HTMLAudioElement>>(new Map());

  // Get local audio stream
  const startLocalAudio = useCallback(async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    localStreamRef.current = stream;
    return stream;
  }, []);

  // Create a peer connection for a remote user
  const createPeerConnection = useCallback(
    (remoteUserId: string): RTCPeerConnection => {
      const pc = new RTCPeerConnection(ICE_SERVERS);

      // Add local audio tracks
      if (localStreamRef.current) {
        for (const track of localStreamRef.current.getAudioTracks()) {
          pc.addTrack(track, localStreamRef.current);
        }
      }

      // Handle incoming audio
      pc.ontrack = (event) => {
        const [remoteStream] = event.streams;
        let audio = audioElementsRef.current.get(remoteUserId);
        if (!audio) {
          audio = new Audio();
          audio.autoplay = true;
          audioElementsRef.current.set(remoteUserId, audio);
        }
        audio.srcObject = remoteStream;
      };

      // Send ICE candidates via signaling
      pc.onicecandidate = (event) => {
        if (event.candidate && ws) {
          const msg: ClientSessionMessage = {
            type: "ice_candidate",
            targetUserId: remoteUserId,
            candidate: event.candidate.toJSON(),
          };
          ws.send(JSON.stringify(msg));
        }
      };

      peersRef.current.set(remoteUserId, { pc, userId: remoteUserId, audioStream: null });
      return pc;
    },
    [ws]
  );

  // Initiate a call to a new participant (create offer)
  const callPeer = useCallback(
    async (remoteUserId: string) => {
      const pc = createPeerConnection(remoteUserId);
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      if (ws) {
        const msg: ClientSessionMessage = {
          type: "sdp_offer",
          targetUserId: remoteUserId,
          sdp: offer,
        };
        ws.send(JSON.stringify(msg));
      }
    },
    [createPeerConnection, ws]
  );

  // Handle incoming signaling messages
  const handleSignaling = useCallback(
    async (msg: ServerSessionMessage) => {
      switch (msg.type) {
        case "sdp_offer": {
          const pc = createPeerConnection(msg.fromUserId);
          await pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);

          if (ws) {
            const reply: ClientSessionMessage = {
              type: "sdp_answer",
              targetUserId: msg.fromUserId,
              sdp: answer,
            };
            ws.send(JSON.stringify(reply));
          }
          break;
        }

        case "sdp_answer": {
          const peer = peersRef.current.get(msg.fromUserId);
          if (peer) {
            await peer.pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
          }
          break;
        }

        case "ice_candidate": {
          const peer = peersRef.current.get(msg.fromUserId);
          if (peer) {
            await peer.pc.addIceCandidate(new RTCIceCandidate(msg.candidate));
          }
          break;
        }

        case "participant_joined": {
          // When a new participant joins, existing members initiate calls
          await callPeer(msg.userId);
          setParticipants((prev) => [
            ...prev,
            { userId: msg.userId, displayName: msg.displayName, isMuted: false },
          ]);
          break;
        }

        case "participant_left": {
          const peer = peersRef.current.get(msg.userId);
          if (peer) {
            peer.pc.close();
            peersRef.current.delete(msg.userId);
          }
          const audio = audioElementsRef.current.get(msg.userId);
          if (audio) {
            audio.srcObject = null;
            audioElementsRef.current.delete(msg.userId);
          }
          setParticipants((prev) => prev.filter((p) => p.userId !== msg.userId));
          break;
        }
      }
    },
    [createPeerConnection, callPeer, ws, setParticipants]
  );

  // Toggle mute
  useEffect(() => {
    if (localStreamRef.current) {
      for (const track of localStreamRef.current.getAudioTracks()) {
        track.enabled = !isMuted;
      }
    }
  }, [isMuted]);

  // Cleanup on unmount
  const cleanup = useCallback(() => {
    for (const peer of peersRef.current.values()) {
      peer.pc.close();
    }
    peersRef.current.clear();

    for (const audio of audioElementsRef.current.values()) {
      audio.srcObject = null;
    }
    audioElementsRef.current.clear();

    if (localStreamRef.current) {
      for (const track of localStreamRef.current.getTracks()) {
        track.stop();
      }
      localStreamRef.current = null;
    }
  }, []);

  return { startLocalAudio, handleSignaling, cleanup };
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/stores/session_atoms.ts apps/main/src/hooks/useSessionAudio.ts
git commit -m "feat: add session atoms and WebRTC P2P audio hook for desktop"
```

---

## Task 7: Desktop — Host Session Hook

**Files:**
- Create: `apps/main/src/hooks/useSessionHost.ts`

- [ ] **Step 1: Create the host session hook**

Create `apps/main/src/hooks/useSessionHost.ts`:

```typescript
import { useAtom } from "jotai";
import { useCallback, useEffect, useRef } from "react";
import {
  sessionIdAtom,
  sessionRoleAtom,
  sessionStatusAtom,
  sessionInviteCodeAtom,
  sessionWebSocketAtom,
} from "../stores/session_atoms";
import { useSessionAudio } from "./useSessionAudio";
import type { ClientSessionMessage, ServerSessionMessage } from "@rishi/shared";

const API_BASE = import.meta.env.VITE_API_URL ?? "https://rishi.fidexa.org";

interface UseSessionHostOptions {
  bookId: string;
  bookTitle: string;
  bookAuthor: string;
  getToken: () => Promise<string>;
}

export function useSessionHost({ bookId, bookTitle, bookAuthor, getToken }: UseSessionHostOptions) {
  const [, setSessionId] = useAtom(sessionIdAtom);
  const [, setRole] = useAtom(sessionRoleAtom);
  const [, setStatus] = useAtom(sessionStatusAtom);
  const [, setInviteCode] = useAtom(sessionInviteCodeAtom);
  const [ws, setWs] = useAtom(sessionWebSocketAtom);
  const { startLocalAudio, handleSignaling, cleanup: cleanupAudio } = useSessionAudio();
  const cursorIntervalRef = useRef<number | null>(null);

  const createSession = useCallback(async () => {
    setStatus("connecting");
    const token = await getToken();

    // Create session via REST
    const res = await fetch(`${API_BASE}/api/sessions/create`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ bookId, bookTitle, bookAuthor }),
    });

    const { id, inviteCode } = await res.json<{ id: string; inviteCode: string }>();
    setSessionId(id);
    setInviteCode(inviteCode);
    setRole("host");

    // Start local audio
    await startLocalAudio();

    // Connect WebSocket to DO
    const wsUrl = `${API_BASE.replace("https://", "wss://")}/api/sessions/ws/${id}?displayName=Host&isHost=true`;
    const socket = new WebSocket(wsUrl, [token]);

    socket.onmessage = (event) => {
      const msg = JSON.parse(event.data) as ServerSessionMessage;
      handleSignaling(msg);
    };

    socket.onopen = () => {
      setStatus("waiting");
    };

    socket.onclose = () => {
      setStatus("ended");
      cleanupAudio();
    };

    setWs(socket);
    return { id, inviteCode };
  }, [bookId, bookTitle, bookAuthor, getToken, startLocalAudio, handleSignaling, cleanupAudio, setSessionId, setRole, setStatus, setInviteCode, setWs]);

  // Send page content to participants
  const sendPageUpdate = useCallback(
    (content: { html?: string; imageBase64?: string; scrollY: number; format: "reflowable" | "fixed" }) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        const msg: ClientSessionMessage = {
          type: "page_update",
          ...content,
        };
        ws.send(JSON.stringify(msg));
      }
    },
    [ws]
  );

  // Send cursor position
  const sendCursorMove = useCallback(
    (x: number, y: number) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        const msg: ClientSessionMessage = { type: "cursor_move", x, y };
        ws.send(JSON.stringify(msg));
      }
    },
    [ws]
  );

  // End session
  const endSession = useCallback(() => {
    if (ws) {
      ws.send(JSON.stringify({ type: "leave" }));
      ws.close();
    }
    if (cursorIntervalRef.current) {
      clearInterval(cursorIntervalRef.current);
    }
    cleanupAudio();
    setStatus("idle");
    setSessionId(null);
    setRole(null);
    setInviteCode(null);
    setWs(null);
  }, [ws, cleanupAudio, setStatus, setSessionId, setRole, setInviteCode, setWs]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "leave" }));
        ws.close();
      }
      cleanupAudio();
    };
  }, [ws, cleanupAudio]);

  return { createSession, sendPageUpdate, sendCursorMove, endSession };
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/hooks/useSessionHost.ts
git commit -m "feat: add useSessionHost hook for creating and managing host sessions"
```

---

## Task 8: Desktop — Participant Session Hook

**Files:**
- Create: `apps/main/src/hooks/useSessionParticipant.ts`

- [ ] **Step 1: Create participant session hook**

Create `apps/main/src/hooks/useSessionParticipant.ts`:

```typescript
import { useAtom } from "jotai";
import { useCallback, useEffect, useState } from "react";
import {
  sessionIdAtom,
  sessionRoleAtom,
  sessionStatusAtom,
  sessionWebSocketAtom,
} from "../stores/session_atoms";
import { useSessionAudio } from "./useSessionAudio";
import type { ServerSessionMessage, SessionInfo } from "@rishi/shared";

const API_BASE = import.meta.env.VITE_API_URL ?? "https://rishi.fidexa.org";

interface PageContent {
  html?: string;
  imageBase64?: string;
  scrollY: number;
  format: "reflowable" | "fixed";
}

interface CursorPosition {
  x: number;
  y: number;
}

interface UseSessionParticipantOptions {
  getToken: () => Promise<string>;
}

export function useSessionParticipant({ getToken }: UseSessionParticipantOptions) {
  const [, setSessionId] = useAtom(sessionIdAtom);
  const [, setRole] = useAtom(sessionRoleAtom);
  const [, setStatus] = useAtom(sessionStatusAtom);
  const [ws, setWs] = useAtom(sessionWebSocketAtom);
  const { startLocalAudio, handleSignaling, cleanup: cleanupAudio } = useSessionAudio();

  const [pageContent, setPageContent] = useState<PageContent | null>(null);
  const [cursorPosition, setCursorPosition] = useState<CursorPosition | null>(null);

  // Look up session by invite code
  const lookupSession = useCallback(
    async (inviteCode: string): Promise<SessionInfo | null> => {
      const token = await getToken();
      const res = await fetch(`${API_BASE}/api/sessions/join/${inviteCode}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) return null;
      return res.json<SessionInfo>();
    },
    [getToken]
  );

  // Join an existing session
  const joinSession = useCallback(
    async (sessionId: string, displayName: string) => {
      setStatus("connecting");
      const token = await getToken();

      // Record participation via REST
      await fetch(`${API_BASE}/api/sessions/join/${sessionId}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      });

      setSessionId(sessionId);
      setRole("participant");

      // Start local audio
      await startLocalAudio();

      // Connect WebSocket to DO
      const wsUrl = `${API_BASE.replace("https://", "wss://")}/api/sessions/ws/${sessionId}?displayName=${encodeURIComponent(displayName)}&isHost=false`;
      const socket = new WebSocket(wsUrl, [token]);

      socket.onmessage = (event) => {
        const msg = JSON.parse(event.data) as ServerSessionMessage;

        // Handle page/cursor updates
        if (msg.type === "page_update") {
          setPageContent({
            html: msg.html,
            imageBase64: msg.imageBase64,
            scrollY: msg.scrollY,
            format: msg.format,
          });
        } else if (msg.type === "cursor_move") {
          setCursorPosition({ x: msg.x, y: msg.y });
        } else if (msg.type === "session_ended") {
          setStatus("ended");
          cleanupAudio();
        } else {
          // Pass signaling messages to audio hook
          handleSignaling(msg);
        }
      };

      socket.onopen = () => {
        setStatus("active");
      };

      socket.onclose = () => {
        setStatus("ended");
        cleanupAudio();
      };

      setWs(socket);
    },
    [getToken, startLocalAudio, handleSignaling, cleanupAudio, setSessionId, setRole, setStatus, setWs]
  );

  // Leave session
  const leaveSession = useCallback(() => {
    if (ws) {
      ws.send(JSON.stringify({ type: "leave" }));
      ws.close();
    }
    cleanupAudio();
    setStatus("idle");
    setSessionId(null);
    setRole(null);
    setWs(null);
    setPageContent(null);
    setCursorPosition(null);
  }, [ws, cleanupAudio, setStatus, setSessionId, setRole, setWs]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "leave" }));
        ws.close();
      }
      cleanupAudio();
    };
  }, [ws, cleanupAudio]);

  return { lookupSession, joinSession, leaveSession, pageContent, cursorPosition };
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/hooks/useSessionParticipant.ts
git commit -m "feat: add useSessionParticipant hook for joining sessions and receiving page stream"
```

---

## Task 9: Desktop — AI Ask Hook

**Files:**
- Create: `apps/main/src/hooks/useSessionAI.ts`

- [ ] **Step 1: Create AI ask hook**

Create `apps/main/src/hooks/useSessionAI.ts`:

```typescript
import { useAtom } from "jotai";
import { useCallback, useRef } from "react";
import {
  sessionWebSocketAtom,
  aiCooldownAtom,
  aiAskingAtom,
} from "../stores/session_atoms";
import { useVoiceInput } from "./useVoiceInput";
import type { ClientSessionMessage, ServerSessionMessage } from "@rishi/shared";

const COOLDOWN_MS = 10_000;

export function useSessionAI(getCurrentPageText: () => string) {
  const [ws] = useAtom(sessionWebSocketAtom);
  const [aiCooldown, setAiCooldown] = useAtom(aiCooldownAtom);
  const [aiAsking, setAiAsking] = useAtom(aiAskingAtom);
  const { isRecording, startRecording, stopRecording } = useVoiceInput();
  const cooldownTimerRef = useRef<number | null>(null);

  // Start recording the question
  const startAskAI = useCallback(async () => {
    if (aiCooldown) return;
    await startRecording();
  }, [aiCooldown, startRecording]);

  // Stop recording and send the question
  const submitAskAI = useCallback(async () => {
    const transcript = await stopRecording();
    if (!transcript || !ws || ws.readyState !== WebSocket.OPEN) return;

    const pageText = getCurrentPageText();
    const msg: ClientSessionMessage = {
      type: "ai_ask",
      question: transcript,
      pageText,
    };
    ws.send(JSON.stringify(msg));

    // Start cooldown
    setAiCooldown(true);
    cooldownTimerRef.current = window.setTimeout(() => {
      setAiCooldown(false);
    }, COOLDOWN_MS);
  }, [stopRecording, ws, getCurrentPageText, setAiCooldown]);

  // Handle AI-related WebSocket messages
  const handleAIMessage = useCallback(
    (msg: ServerSessionMessage) => {
      if (msg.type === "ai_asking") {
        setAiAsking({
          userId: msg.userId,
          displayName: msg.displayName,
          question: msg.question,
        });
      } else if (msg.type === "ai_response") {
        // Play the TTS audio for all participants
        const audio = new Audio(msg.audioUrl);
        audio.play();
        setAiAsking(null);

        // Start cooldown for everyone
        setAiCooldown(true);
        if (cooldownTimerRef.current) clearTimeout(cooldownTimerRef.current);
        cooldownTimerRef.current = window.setTimeout(() => {
          setAiCooldown(false);
        }, COOLDOWN_MS);
      } else if (msg.type === "ai_error") {
        setAiAsking(null);
      }
    },
    [setAiAsking, setAiCooldown]
  );

  return {
    isRecording,
    aiCooldown,
    aiAsking,
    startAskAI,
    submitAskAI,
    handleAIMessage,
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/hooks/useSessionAI.ts
git commit -m "feat: add useSessionAI hook for voice AI questions during reading sessions"
```

---

## Task 10: Desktop — Friends Hook

**Files:**
- Create: `apps/main/src/hooks/useFriends.ts`

- [ ] **Step 1: Create friends hook**

Create `apps/main/src/hooks/useFriends.ts`:

```typescript
import { useState, useCallback, useEffect } from "react";
import type { FriendInfo, SessionInfo } from "@rishi/shared";

const API_BASE = import.meta.env.VITE_API_URL ?? "https://rishi.fidexa.org";

interface UseFriendsOptions {
  getToken: () => Promise<string>;
}

export function useFriends({ getToken }: UseFriendsOptions) {
  const [friends, setFriends] = useState<FriendInfo[]>([]);
  const [activeSessions, setActiveSessions] = useState<SessionInfo[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  const authFetch = useCallback(
    async (path: string, init?: RequestInit) => {
      const token = await getToken();
      return fetch(`${API_BASE}${path}`, {
        ...init,
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
          ...init?.headers,
        },
      });
    },
    [getToken]
  );

  const loadFriends = useCallback(async () => {
    setIsLoading(true);
    const res = await authFetch("/api/friends");
    const data = await res.json<{ friends: FriendInfo[] }>();
    setFriends(data.friends);
    setIsLoading(false);
  }, [authFetch]);

  const loadActiveSessions = useCallback(async () => {
    const res = await authFetch("/api/sessions/friends-active");
    const data = await res.json<{ sessions: SessionInfo[] }>();
    setActiveSessions(data.sessions);
  }, [authFetch]);

  const searchUsers = useCallback(
    async (query: string) => {
      const res = await authFetch(`/api/friends/search?q=${encodeURIComponent(query)}`);
      const data = await res.json<{ users: any[] }>();
      return data.users;
    },
    [authFetch]
  );

  const sendRequest = useCallback(
    async (friendEmail: string) => {
      const res = await authFetch("/api/friends/request", {
        method: "POST",
        body: JSON.stringify({ friendEmail }),
      });
      if (res.ok) await loadFriends();
      return res.ok;
    },
    [authFetch, loadFriends]
  );

  const acceptRequest = useCallback(
    async (requestId: string) => {
      await authFetch("/api/friends/accept", {
        method: "POST",
        body: JSON.stringify({ requestId }),
      });
      await loadFriends();
    },
    [authFetch, loadFriends]
  );

  const removeFriend = useCallback(
    async (id: string) => {
      await authFetch(`/api/friends/${id}`, { method: "DELETE" });
      await loadFriends();
    },
    [authFetch, loadFriends]
  );

  const blockUser = useCallback(
    async (targetUserId: string) => {
      await authFetch("/api/friends/block", {
        method: "POST",
        body: JSON.stringify({ targetUserId }),
      });
      await loadFriends();
    },
    [authFetch, loadFriends]
  );

  // Load on mount
  useEffect(() => {
    loadFriends();
    loadActiveSessions();
  }, [loadFriends, loadActiveSessions]);

  return {
    friends,
    activeSessions,
    isLoading,
    loadFriends,
    loadActiveSessions,
    searchUsers,
    sendRequest,
    acceptRequest,
    removeFriend,
    blockUser,
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/hooks/useFriends.ts
git commit -m "feat: add useFriends hook for friend management on desktop"
```

---

## Task 11: Desktop — Session UI Components

**Files:**
- Create: `apps/main/src/components/session/SessionToolbar.tsx`
- Create: `apps/main/src/components/session/SessionOverlay.tsx`
- Create: `apps/main/src/components/session/ParticipantView.tsx`
- Create: `apps/main/src/components/session/AskAIButton.tsx`
- Create: `apps/main/src/components/session/JoinSessionSheet.tsx`
- Create: `apps/main/src/components/session/FriendsSheet.tsx`

- [ ] **Step 1: Create SessionToolbar**

Create `apps/main/src/components/session/SessionToolbar.tsx`:

```tsx
import { useAtom } from "jotai";
import {
  sessionStatusAtom,
  sessionInviteCodeAtom,
  sessionParticipantsAtom,
  sessionRoleAtom,
} from "../../stores/session_atoms";
import { Users, LinkIcon, X, Copy } from "lucide-react";

interface SessionToolbarProps {
  onStartSession: () => void;
  onEndSession: () => void;
  onOpenJoinSheet: () => void;
  onOpenFriendsSheet: () => void;
}

export function SessionToolbar({
  onStartSession,
  onEndSession,
  onOpenJoinSheet,
  onOpenFriendsSheet,
}: SessionToolbarProps) {
  const [status] = useAtom(sessionStatusAtom);
  const [inviteCode] = useAtom(sessionInviteCodeAtom);
  const [participants] = useAtom(sessionParticipantsAtom);
  const [role] = useAtom(sessionRoleAtom);

  const copyInviteLink = () => {
    if (inviteCode) {
      navigator.clipboard.writeText(`https://rishi.fidexa.org/join/${inviteCode}`);
    }
  };

  if (status === "idle") {
    return (
      <div className="flex items-center gap-2">
        <button
          onClick={onStartSession}
          className="flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground hover:bg-primary/90"
        >
          <Users className="h-4 w-4" />
          Start Session
        </button>
        <button
          onClick={onOpenJoinSheet}
          className="flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted"
        >
          <LinkIcon className="h-4 w-4" />
          Join
        </button>
        <button
          onClick={onOpenFriendsSheet}
          className="flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted"
        >
          <Users className="h-4 w-4" />
          Friends
        </button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-3 rounded-md bg-muted px-3 py-1.5">
      <div className="flex items-center gap-1.5 text-sm">
        <div className="h-2 w-2 rounded-full bg-green-500 animate-pulse" />
        <span>{status === "waiting" ? "Waiting..." : `${participants.length}/3`}</span>
      </div>

      {role === "host" && inviteCode && (
        <button
          onClick={copyInviteLink}
          className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
        >
          <Copy className="h-3 w-3" />
          {inviteCode}
        </button>
      )}

      <button
        onClick={onEndSession}
        className="ml-auto flex items-center gap-1 text-sm text-destructive hover:text-destructive/80"
      >
        <X className="h-4 w-4" />
        {role === "host" ? "End" : "Leave"}
      </button>
    </div>
  );
}
```

- [ ] **Step 2: Create SessionOverlay**

Create `apps/main/src/components/session/SessionOverlay.tsx`:

```tsx
import { useAtom } from "jotai";
import {
  sessionParticipantsAtom,
  isMutedAtom,
  sessionStatusAtom,
  aiAskingAtom,
} from "../../stores/session_atoms";
import { Mic, MicOff } from "lucide-react";

export function SessionOverlay() {
  const [participants] = useAtom(sessionParticipantsAtom);
  const [isMuted, setIsMuted] = useAtom(isMutedAtom);
  const [status] = useAtom(sessionStatusAtom);
  const [aiAsking] = useAtom(aiAskingAtom);

  if (status !== "active" && status !== "waiting") return null;

  return (
    <div className="fixed bottom-4 left-1/2 z-50 flex -translate-x-1/2 items-center gap-3 rounded-full bg-background/90 px-4 py-2 shadow-lg backdrop-blur">
      {/* Participant avatars */}
      <div className="flex -space-x-2">
        {participants.map((p) => (
          <div
            key={p.userId}
            className="flex h-8 w-8 items-center justify-center rounded-full border-2 border-background bg-primary text-xs text-primary-foreground"
            title={p.displayName}
          >
            {p.displayName.charAt(0).toUpperCase()}
          </div>
        ))}
      </div>

      {/* Mute toggle */}
      <button
        onClick={() => setIsMuted(!isMuted)}
        className={`rounded-full p-2 ${isMuted ? "bg-destructive text-destructive-foreground" : "bg-muted hover:bg-muted/80"}`}
      >
        {isMuted ? <MicOff className="h-4 w-4" /> : <Mic className="h-4 w-4" />}
      </button>

      {/* AI asking indicator */}
      {aiAsking && (
        <div className="ml-2 flex items-center gap-1.5 text-xs text-muted-foreground">
          <div className="h-2 w-2 rounded-full bg-blue-500 animate-pulse" />
          {aiAsking.displayName} asked AI...
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 3: Create ParticipantView**

Create `apps/main/src/components/session/ParticipantView.tsx`:

```tsx
import { useEffect, useRef } from "react";

interface ParticipantViewProps {
  pageContent: {
    html?: string;
    imageBase64?: string;
    scrollY: number;
    format: "reflowable" | "fixed";
  } | null;
  cursorPosition: { x: number; y: number } | null;
}

export function ParticipantView({ pageContent, cursorPosition }: ParticipantViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const iframeRef = useRef<HTMLIFrameElement>(null);

  // Update iframe content for reflowable
  useEffect(() => {
    if (!pageContent || pageContent.format !== "reflowable" || !pageContent.html) return;
    if (!iframeRef.current) return;

    const doc = iframeRef.current.contentDocument;
    if (doc) {
      doc.open();
      doc.write(`
        <!DOCTYPE html>
        <html>
        <head>
          <style>
            body { font-family: serif; line-height: 1.6; padding: 2rem; margin: 0; color: #1a1a1a; pointer-events: none; user-select: none; }
          </style>
        </head>
        <body>${pageContent.html}</body>
        </html>
      `);
      doc.close();

      // Sync scroll position
      const scrollTarget = doc.documentElement.scrollHeight * pageContent.scrollY;
      doc.documentElement.scrollTop = scrollTarget;
    }
  }, [pageContent]);

  if (!pageContent) {
    return (
      <div className="flex h-full items-center justify-center text-muted-foreground">
        Waiting for host to share their screen...
      </div>
    );
  }

  return (
    <div ref={containerRef} className="relative h-full w-full overflow-hidden">
      {pageContent.format === "reflowable" ? (
        <iframe
          ref={iframeRef}
          className="h-full w-full border-none"
          sandbox="allow-same-origin"
          title="Shared reading view"
        />
      ) : (
        <img
          src={`data:image/webp;base64,${pageContent.imageBase64}`}
          alt="Shared page"
          className="mx-auto h-full object-contain"
        />
      )}

      {/* Host cursor overlay */}
      {cursorPosition && (
        <div
          className="pointer-events-none absolute z-10 h-5 w-5 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-primary bg-primary/30 transition-all duration-75"
          style={{
            left: `${cursorPosition.x * 100}%`,
            top: `${cursorPosition.y * 100}%`,
          }}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 4: Create AskAIButton**

Create `apps/main/src/components/session/AskAIButton.tsx`:

```tsx
import { BotMessageSquare, Mic } from "lucide-react";

interface AskAIButtonProps {
  isRecording: boolean;
  isCooldown: boolean;
  onPress: () => void;
  onRelease: () => void;
}

export function AskAIButton({ isRecording, isCooldown, onPress, onRelease }: AskAIButtonProps) {
  return (
    <button
      onMouseDown={onPress}
      onMouseUp={onRelease}
      onMouseLeave={onRelease}
      disabled={isCooldown}
      className={`fixed bottom-4 right-4 z-50 flex h-14 w-14 items-center justify-center rounded-full shadow-lg transition-all ${
        isCooldown
          ? "bg-muted text-muted-foreground cursor-not-allowed"
          : isRecording
            ? "bg-red-500 text-white scale-110 animate-pulse"
            : "bg-primary text-primary-foreground hover:bg-primary/90"
      }`}
      title={isCooldown ? "Cooldown..." : isRecording ? "Release to ask" : "Hold to ask AI"}
    >
      {isRecording ? <Mic className="h-6 w-6" /> : <BotMessageSquare className="h-6 w-6" />}
    </button>
  );
}
```

- [ ] **Step 5: Create JoinSessionSheet**

Create `apps/main/src/components/session/JoinSessionSheet.tsx`:

```tsx
import { useState } from "react";
import * as SheetPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";

interface JoinSessionSheetProps {
  open: boolean;
  onClose: () => void;
  onJoin: (inviteCode: string) => void;
}

export function JoinSessionSheet({ open, onClose, onJoin }: JoinSessionSheetProps) {
  const [code, setCode] = useState("");

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (code.trim().length >= 6) {
      onJoin(code.trim().toUpperCase());
      setCode("");
      onClose();
    }
  };

  return (
    <SheetPrimitive.Root open={open} onOpenChange={(o) => !o && onClose()}>
      <SheetPrimitive.Portal>
        <SheetPrimitive.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <SheetPrimitive.Content className="fixed right-0 top-0 z-50 h-full w-[380px] bg-background p-6 shadow-lg">
          <div className="flex items-center justify-between mb-6">
            <h2 className="text-lg font-semibold">Join Session</h2>
            <SheetPrimitive.Close asChild>
              <button className="rounded-sm opacity-70 hover:opacity-100">
                <X className="h-4 w-4" />
              </button>
            </SheetPrimitive.Close>
          </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="text-sm font-medium">Room Code</label>
              <input
                type="text"
                value={code}
                onChange={(e) => setCode(e.target.value.toUpperCase())}
                placeholder="e.g. RK4729"
                maxLength={6}
                className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-center text-lg tracking-widest"
                autoFocus
              />
            </div>
            <button
              type="submit"
              disabled={code.length < 6}
              className="w-full rounded-md bg-primary px-4 py-2 text-sm text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            >
              Join Session
            </button>
          </form>

          <p className="mt-4 text-xs text-muted-foreground">
            Or paste an invite link directly — the app will handle it automatically.
          </p>
        </SheetPrimitive.Content>
      </SheetPrimitive.Portal>
    </SheetPrimitive.Root>
  );
}
```

- [ ] **Step 6: Create FriendsSheet**

Create `apps/main/src/components/session/FriendsSheet.tsx`:

```tsx
import { useState } from "react";
import * as SheetPrimitive from "@radix-ui/react-dialog";
import { X, Search, UserPlus, Check, Ban, Users } from "lucide-react";
import type { FriendInfo, SessionInfo } from "@rishi/shared";

interface FriendsSheetProps {
  open: boolean;
  onClose: () => void;
  friends: FriendInfo[];
  activeSessions: SessionInfo[];
  onSearch: (query: string) => Promise<any[]>;
  onSendRequest: (email: string) => Promise<boolean>;
  onAccept: (requestId: string) => void;
  onRemove: (id: string) => void;
  onBlock: (userId: string) => void;
  onJoinSession: (sessionId: string) => void;
}

export function FriendsSheet({
  open,
  onClose,
  friends,
  activeSessions,
  onSearch,
  onSendRequest,
  onAccept,
  onRemove,
  onBlock,
  onJoinSession,
}: FriendsSheetProps) {
  const [searchQuery, setSearchQuery] = useState("");
  const [searchResults, setSearchResults] = useState<any[]>([]);
  const [tab, setTab] = useState<"friends" | "requests" | "search">("friends");

  const handleSearch = async (q: string) => {
    setSearchQuery(q);
    if (q.length >= 3) {
      const results = await onSearch(q);
      setSearchResults(results);
    } else {
      setSearchResults([]);
    }
  };

  const pendingRequests = friends.filter((f) => f.status === "pending");
  const acceptedFriends = friends.filter((f) => f.status === "accepted");

  return (
    <SheetPrimitive.Root open={open} onOpenChange={(o) => !o && onClose()}>
      <SheetPrimitive.Portal>
        <SheetPrimitive.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <SheetPrimitive.Content className="fixed right-0 top-0 z-50 h-full w-[400px] bg-background p-6 shadow-lg overflow-y-auto">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold">Friends</h2>
            <SheetPrimitive.Close asChild>
              <button className="rounded-sm opacity-70 hover:opacity-100">
                <X className="h-4 w-4" />
              </button>
            </SheetPrimitive.Close>
          </div>

          {/* Tabs */}
          <div className="flex gap-1 mb-4 rounded-md bg-muted p-1">
            {(["friends", "requests", "search"] as const).map((t) => (
              <button
                key={t}
                onClick={() => setTab(t)}
                className={`flex-1 rounded-sm px-3 py-1 text-sm capitalize ${tab === t ? "bg-background shadow-sm" : "text-muted-foreground"}`}
              >
                {t}
                {t === "requests" && pendingRequests.length > 0 && (
                  <span className="ml-1 inline-flex h-4 w-4 items-center justify-center rounded-full bg-primary text-[10px] text-primary-foreground">
                    {pendingRequests.length}
                  </span>
                )}
              </button>
            ))}
          </div>

          {/* Friends tab */}
          {tab === "friends" && (
            <div className="space-y-2">
              {/* Active sessions from friends */}
              {activeSessions.length > 0 && (
                <div className="mb-4">
                  <h3 className="text-xs font-medium text-muted-foreground uppercase mb-2">Active Sessions</h3>
                  {activeSessions.map((s) => (
                    <div key={s.id} className="flex items-center justify-between rounded-md border p-3 mb-2">
                      <div>
                        <p className="text-sm font-medium">{s.bookTitle}</p>
                        <p className="text-xs text-muted-foreground">{s.participantCount}/3 participants</p>
                      </div>
                      <button
                        onClick={() => onJoinSession(s.id)}
                        className="rounded-md bg-primary px-3 py-1 text-xs text-primary-foreground"
                      >
                        Join
                      </button>
                    </div>
                  ))}
                </div>
              )}

              {acceptedFriends.map((f) => (
                <div key={f.id} className="flex items-center justify-between rounded-md border p-3">
                  <div className="flex items-center gap-2">
                    <div className="flex h-8 w-8 items-center justify-center rounded-full bg-muted text-sm">
                      {f.displayName.charAt(0).toUpperCase()}
                    </div>
                    <div>
                      <p className="text-sm font-medium">{f.displayName}</p>
                      <p className="text-xs text-muted-foreground">{f.email}</p>
                    </div>
                  </div>
                  <button onClick={() => onRemove(f.id)} className="text-muted-foreground hover:text-destructive">
                    <X className="h-4 w-4" />
                  </button>
                </div>
              ))}

              {acceptedFriends.length === 0 && activeSessions.length === 0 && (
                <p className="text-center text-sm text-muted-foreground py-8">
                  No friends yet. Search to add some!
                </p>
              )}
            </div>
          )}

          {/* Requests tab */}
          {tab === "requests" && (
            <div className="space-y-2">
              {pendingRequests.map((f) => (
                <div key={f.id} className="flex items-center justify-between rounded-md border p-3">
                  <div>
                    <p className="text-sm font-medium">{f.displayName}</p>
                    <p className="text-xs text-muted-foreground">{f.email}</p>
                  </div>
                  <div className="flex gap-1">
                    <button onClick={() => onAccept(f.id)} className="rounded-md bg-primary p-1.5 text-primary-foreground">
                      <Check className="h-4 w-4" />
                    </button>
                    <button onClick={() => onBlock(f.userId)} className="rounded-md bg-muted p-1.5">
                      <Ban className="h-4 w-4" />
                    </button>
                  </div>
                </div>
              ))}
              {pendingRequests.length === 0 && (
                <p className="text-center text-sm text-muted-foreground py-8">No pending requests.</p>
              )}
            </div>
          )}

          {/* Search tab */}
          {tab === "search" && (
            <div className="space-y-3">
              <div className="relative">
                <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  type="text"
                  value={searchQuery}
                  onChange={(e) => handleSearch(e.target.value)}
                  placeholder="Search by name or email..."
                  className="w-full rounded-md border bg-background pl-9 pr-3 py-2 text-sm"
                  autoFocus
                />
              </div>

              {searchResults.map((user) => (
                <div key={user.id} className="flex items-center justify-between rounded-md border p-3">
                  <div className="flex items-center gap-2">
                    {user.imageUrl ? (
                      <img src={user.imageUrl} className="h-8 w-8 rounded-full" alt="" />
                    ) : (
                      <div className="flex h-8 w-8 items-center justify-center rounded-full bg-muted text-sm">
                        {user.displayName.charAt(0).toUpperCase()}
                      </div>
                    )}
                    <div>
                      <p className="text-sm font-medium">{user.displayName}</p>
                      <p className="text-xs text-muted-foreground">{user.email}</p>
                    </div>
                  </div>
                  <button
                    onClick={() => onSendRequest(user.email)}
                    className="rounded-md bg-primary p-1.5 text-primary-foreground"
                  >
                    <UserPlus className="h-4 w-4" />
                  </button>
                </div>
              ))}
            </div>
          )}
        </SheetPrimitive.Content>
      </SheetPrimitive.Portal>
    </SheetPrimitive.Root>
  );
}
```

- [ ] **Step 7: Commit**

```bash
git add apps/main/src/components/session/
git commit -m "feat: add desktop session UI components (toolbar, overlay, participant view, AI button, sheets)"
```

---

## Task 12: Desktop — Integrate Session into Readers

**Files:**
- Modify: `apps/main/src/components/epub.tsx`
- Modify: `apps/main/src/components/pdf/components/pdf.tsx`
- Modify: `apps/main/src/components/LoginButton.tsx`

This task wires the session hooks and components into the existing readers. The exact integration points depend on how the reader components expose their content. The key actions are:

- [ ] **Step 1: Add page content extraction to EPUB reader**

In `apps/main/src/components/epub.tsx`, add a function that extracts the current chapter's visible HTML from the epubjs rendition. The rendition object exposes the displayed content via `rendition.getContents()`. Add a callback that the `useSessionHost` hook can call:

```typescript
// Add inside the EPUB component, after rendition is initialized:
const getPageContent = useCallback((): { html: string; scrollY: number } => {
  const rendition = renditionRef.current;
  if (!rendition) return { html: "", scrollY: 0 };

  const contents = rendition.getContents();
  if (contents.length === 0) return { html: "", scrollY: 0 };

  const content = contents[0];
  const doc = content.document;
  const body = doc?.body;
  const html = body?.innerHTML ?? "";
  const scrollY = (content.window?.scrollY ?? 0) / (doc?.documentElement?.scrollHeight ?? 1);

  return { html, scrollY };
}, []);

const getPageText = useCallback((): string => {
  const rendition = renditionRef.current;
  if (!rendition) return "";

  const contents = rendition.getContents();
  if (contents.length === 0) return "";

  return contents[0].document?.body?.innerText ?? "";
}, []);
```

Add a mouse move listener for cursor streaming:

```typescript
// Inside the component, when session is active as host:
useEffect(() => {
  if (sessionRole !== "host" || !containerRef.current) return;

  const handler = (e: MouseEvent) => {
    const rect = containerRef.current!.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    const y = (e.clientY - rect.top) / rect.height;
    sendCursorMove(x, y);
  };

  containerRef.current.addEventListener("mousemove", handler);
  return () => containerRef.current?.removeEventListener("mousemove", handler);
}, [sessionRole, sendCursorMove]);
```

Wire `SessionToolbar`, `SessionOverlay`, `AskAIButton`, and conditionally render `ParticipantView` when the user is a participant.

- [ ] **Step 2: Add page capture to PDF reader**

In `apps/main/src/components/pdf/components/pdf.tsx`, add a function that captures the current page as a base64 image:

```typescript
const getPageContent = useCallback((): { imageBase64: string; scrollY: number } => {
  // Find the currently visible canvas element from react-pdf
  const canvas = document.querySelector(".react-pdf__Page__canvas") as HTMLCanvasElement | null;
  if (!canvas) return { imageBase64: "", scrollY: 0 };

  // Convert to WebP for smaller size
  const dataUrl = canvas.toDataURL("image/webp", 0.8);
  const imageBase64 = dataUrl.replace("data:image/webp;base64,", "");

  return { imageBase64, scrollY: 0 };
}, []);

const getPageText = useCallback((): string => {
  // Use the existing text extractor to get current page text
  const textLayer = document.querySelector(".react-pdf__Page__textContent");
  return textLayer?.textContent ?? "";
}, []);
```

Wire session components the same way as EPUB.

- [ ] **Step 3: Handle session invite deep links**

In `apps/main/src/components/LoginButton.tsx`, extend the `onOpenUrl` handler to detect session invite URLs:

```typescript
// Inside the existing onOpenUrl callback, add:
if (url.includes("/join/")) {
  const inviteCode = url.split("/join/")[1]?.split("?")[0];
  if (inviteCode) {
    // Navigate to join session flow
    // This will be handled by the session participant hook
    window.dispatchEvent(new CustomEvent("session-invite", { detail: { inviteCode } }));
  }
  continue;
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/epub.tsx apps/main/src/components/pdf/components/pdf.tsx apps/main/src/components/LoginButton.tsx
git commit -m "feat: integrate reading sessions into EPUB and PDF readers with page streaming"
```

---

## Task 13: Mobile — Session Hooks

**Files:**
- Create: `apps/mobile/hooks/useSessionAudio.ts`
- Create: `apps/mobile/hooks/useSessionHost.ts`
- Create: `apps/mobile/hooks/useSessionParticipant.ts`
- Create: `apps/mobile/hooks/useSessionAI.ts`
- Create: `apps/mobile/hooks/useFriends.ts`

- [ ] **Step 1: Create mobile WebRTC audio hook**

Create `apps/mobile/hooks/useSessionAudio.ts`:

```typescript
import { useCallback, useRef } from "react";
import {
  RTCPeerConnection,
  RTCSessionDescription,
  RTCIceCandidate,
  mediaDevices,
  MediaStream,
} from "react-native-webrtc";
import type { ServerSessionMessage, ClientSessionMessage } from "@rishi/shared";

interface PeerConnection {
  pc: RTCPeerConnection;
  userId: string;
}

const ICE_SERVERS = {
  iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
};

export function useSessionAudio(
  sendMessage: (msg: ClientSessionMessage) => void
) {
  const peersRef = useRef<Map<string, PeerConnection>>(new Map());
  const localStreamRef = useRef<MediaStream | null>(null);

  const startLocalAudio = useCallback(async () => {
    const stream = await mediaDevices.getUserMedia({ audio: true, video: false });
    localStreamRef.current = stream as MediaStream;
    return stream;
  }, []);

  const createPeerConnection = useCallback(
    (remoteUserId: string): RTCPeerConnection => {
      const pc = new RTCPeerConnection(ICE_SERVERS);

      if (localStreamRef.current) {
        localStreamRef.current.getTracks().forEach((track) => {
          pc.addTrack(track, localStreamRef.current!);
        });
      }

      pc.ontrack = (event: any) => {
        // react-native-webrtc auto-plays remote audio tracks
      };

      pc.onicecandidate = (event: any) => {
        if (event.candidate) {
          sendMessage({
            type: "ice_candidate",
            targetUserId: remoteUserId,
            candidate: event.candidate.toJSON(),
          });
        }
      };

      peersRef.current.set(remoteUserId, { pc, userId: remoteUserId });
      return pc;
    },
    [sendMessage]
  );

  const callPeer = useCallback(
    async (remoteUserId: string) => {
      const pc = createPeerConnection(remoteUserId);
      const offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);

      sendMessage({
        type: "sdp_offer",
        targetUserId: remoteUserId,
        sdp: offer,
      });
    },
    [createPeerConnection, sendMessage]
  );

  const handleSignaling = useCallback(
    async (msg: ServerSessionMessage) => {
      if (msg.type === "sdp_offer") {
        const pc = createPeerConnection(msg.fromUserId);
        await pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);

        sendMessage({
          type: "sdp_answer",
          targetUserId: msg.fromUserId,
          sdp: answer,
        });
      } else if (msg.type === "sdp_answer") {
        const peer = peersRef.current.get(msg.fromUserId);
        if (peer) {
          await peer.pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
        }
      } else if (msg.type === "ice_candidate") {
        const peer = peersRef.current.get(msg.fromUserId);
        if (peer) {
          await peer.pc.addIceCandidate(new RTCIceCandidate(msg.candidate));
        }
      } else if (msg.type === "participant_joined") {
        await callPeer(msg.userId);
      } else if (msg.type === "participant_left") {
        const peer = peersRef.current.get(msg.userId);
        if (peer) {
          peer.pc.close();
          peersRef.current.delete(msg.userId);
        }
      }
    },
    [createPeerConnection, callPeer, sendMessage]
  );

  const toggleMute = useCallback((muted: boolean) => {
    if (localStreamRef.current) {
      localStreamRef.current.getAudioTracks().forEach((track) => {
        track.enabled = !muted;
      });
    }
  }, []);

  const cleanup = useCallback(() => {
    for (const peer of peersRef.current.values()) {
      peer.pc.close();
    }
    peersRef.current.clear();

    if (localStreamRef.current) {
      localStreamRef.current.getTracks().forEach((track) => track.stop());
      localStreamRef.current = null;
    }
  }, []);

  return { startLocalAudio, handleSignaling, toggleMute, cleanup };
}
```

- [ ] **Step 2: Create mobile host, participant, AI, and friends hooks**

These follow the same patterns as the desktop hooks (Tasks 7-10), adapted for React Native:

- `hooks/useSessionHost.ts` — same as desktop but uses `useAuth()` from `@clerk/expo` for tokens
- `hooks/useSessionParticipant.ts` — same as desktop, receives page content as state
- `hooks/useSessionAI.ts` — uses mobile `useVoiceInput` hook + `expo-audio` for TTS playback instead of `new Audio()`
- `hooks/useFriends.ts` — identical to desktop (pure fetch logic)

Create each file following the desktop hook structure, replacing:
- `import.meta.env.VITE_API_URL` → `process.env.EXPO_PUBLIC_API_URL`
- `useAtom(...)` → `useState(...)` (mobile uses React state, not Jotai)
- `new Audio(url)` → `Audio.Sound.createAsync({ uri: url })` from `expo-audio`
- `navigator.clipboard.writeText(...)` → `Clipboard.setStringAsync(...)` from `expo-clipboard`

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/hooks/useSessionAudio.ts apps/mobile/hooks/useSessionHost.ts apps/mobile/hooks/useSessionParticipant.ts apps/mobile/hooks/useSessionAI.ts apps/mobile/hooks/useFriends.ts
git commit -m "feat: add mobile session hooks (audio, host, participant, AI, friends)"
```

---

## Task 14: Mobile — Session UI Components

**Files:**
- Create: `apps/mobile/components/session/SessionToolbar.tsx`
- Create: `apps/mobile/components/session/SessionOverlay.tsx`
- Create: `apps/mobile/components/session/ParticipantView.tsx`
- Create: `apps/mobile/components/session/AskAIButton.tsx`
- Create: `apps/mobile/components/session/JoinSessionSheet.tsx`
- Create: `apps/mobile/components/session/FriendsSheet.tsx`

- [ ] **Step 1: Create mobile SessionToolbar**

Create `apps/mobile/components/session/SessionToolbar.tsx`:

```tsx
import { View, Text, TouchableOpacity } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import * as Clipboard from "expo-clipboard";

interface SessionToolbarProps {
  status: "idle" | "connecting" | "waiting" | "active" | "ended";
  role: "host" | "participant" | null;
  inviteCode: string | null;
  participantCount: number;
  onStartSession: () => void;
  onEndSession: () => void;
  onOpenJoinSheet: () => void;
  onOpenFriendsSheet: () => void;
}

export function SessionToolbar({
  status,
  role,
  inviteCode,
  participantCount,
  onStartSession,
  onEndSession,
  onOpenJoinSheet,
  onOpenFriendsSheet,
}: SessionToolbarProps) {
  const copyInviteLink = async () => {
    if (inviteCode) {
      await Clipboard.setStringAsync(`https://rishi.fidexa.org/join/${inviteCode}`);
    }
  };

  if (status === "idle") {
    return (
      <View className="flex-row items-center gap-2">
        <TouchableOpacity
          onPress={onStartSession}
          className="flex-row items-center gap-1 rounded-lg bg-blue-600 px-3 py-2"
        >
          <Ionicons name="people" size={16} color="white" />
          <Text className="text-sm font-medium text-white">Start Session</Text>
        </TouchableOpacity>
        <TouchableOpacity
          onPress={onOpenJoinSheet}
          className="flex-row items-center gap-1 rounded-lg border border-gray-300 px-3 py-2"
        >
          <Ionicons name="link" size={16} color="#666" />
          <Text className="text-sm text-gray-700">Join</Text>
        </TouchableOpacity>
        <TouchableOpacity
          onPress={onOpenFriendsSheet}
          className="flex-row items-center gap-1 rounded-lg border border-gray-300 px-3 py-2"
        >
          <Ionicons name="people-outline" size={16} color="#666" />
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <View className="flex-row items-center gap-3 rounded-lg bg-gray-100 px-3 py-2">
      <View className="flex-row items-center gap-1">
        <View className="h-2 w-2 rounded-full bg-green-500" />
        <Text className="text-sm">
          {status === "waiting" ? "Waiting..." : `${participantCount}/3`}
        </Text>
      </View>

      {role === "host" && inviteCode && (
        <TouchableOpacity onPress={copyInviteLink} className="flex-row items-center gap-1">
          <Ionicons name="copy-outline" size={12} color="#999" />
          <Text className="text-xs text-gray-500">{inviteCode}</Text>
        </TouchableOpacity>
      )}

      <TouchableOpacity onPress={onEndSession} className="ml-auto flex-row items-center gap-1">
        <Ionicons name="close" size={16} color="#ef4444" />
        <Text className="text-sm text-red-500">{role === "host" ? "End" : "Leave"}</Text>
      </TouchableOpacity>
    </View>
  );
}
```

- [ ] **Step 2: Create mobile SessionOverlay, ParticipantView, AskAIButton**

Create `apps/mobile/components/session/SessionOverlay.tsx`:

```tsx
import { View, Text, TouchableOpacity } from "react-native";
import { Ionicons } from "@expo/vector-icons";

interface SessionOverlayProps {
  participants: { userId: string; displayName: string; isMuted: boolean }[];
  isMuted: boolean;
  onToggleMute: () => void;
  aiAsking: { displayName: string; question: string } | null;
}

export function SessionOverlay({ participants, isMuted, onToggleMute, aiAsking }: SessionOverlayProps) {
  return (
    <View className="absolute bottom-6 left-4 right-4 flex-row items-center justify-center gap-3 rounded-full bg-black/80 px-4 py-2">
      <View className="flex-row -space-x-2">
        {participants.map((p) => (
          <View
            key={p.userId}
            className="h-8 w-8 items-center justify-center rounded-full border-2 border-black bg-blue-600"
          >
            <Text className="text-xs font-bold text-white">
              {p.displayName.charAt(0).toUpperCase()}
            </Text>
          </View>
        ))}
      </View>

      <TouchableOpacity
        onPress={onToggleMute}
        className={`rounded-full p-2 ${isMuted ? "bg-red-500" : "bg-gray-700"}`}
      >
        <Ionicons name={isMuted ? "mic-off" : "mic"} size={18} color="white" />
      </TouchableOpacity>

      {aiAsking && (
        <View className="ml-2 flex-row items-center gap-1">
          <View className="h-2 w-2 rounded-full bg-blue-400" />
          <Text className="text-xs text-gray-300">{aiAsking.displayName} asked AI...</Text>
        </View>
      )}
    </View>
  );
}
```

Create `apps/mobile/components/session/ParticipantView.tsx`:

```tsx
import { View, Text, Image } from "react-native";
import { WebView } from "react-native-webview";

interface ParticipantViewProps {
  pageContent: {
    html?: string;
    imageBase64?: string;
    scrollY: number;
    format: "reflowable" | "fixed";
  } | null;
  cursorPosition: { x: number; y: number } | null;
}

export function ParticipantView({ pageContent, cursorPosition }: ParticipantViewProps) {
  if (!pageContent) {
    return (
      <View className="flex-1 items-center justify-center">
        <Text className="text-gray-500">Waiting for host to share their screen...</Text>
      </View>
    );
  }

  return (
    <View className="flex-1 relative">
      {pageContent.format === "reflowable" && pageContent.html ? (
        <WebView
          source={{
            html: `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{font-family:serif;line-height:1.6;padding:16px;margin:0;color:#1a1a1a;-webkit-user-select:none;}</style></head><body>${pageContent.html}</body></html>`,
          }}
          scrollEnabled={false}
          className="flex-1"
        />
      ) : pageContent.imageBase64 ? (
        <Image
          source={{ uri: `data:image/webp;base64,${pageContent.imageBase64}` }}
          className="flex-1"
          resizeMode="contain"
        />
      ) : null}

      {cursorPosition && (
        <View
          className="absolute h-5 w-5 rounded-full border-2 border-blue-500 bg-blue-500/30"
          style={{
            left: `${cursorPosition.x * 100}%`,
            top: `${cursorPosition.y * 100}%`,
            transform: [{ translateX: -10 }, { translateY: -10 }],
          }}
        />
      )}
    </View>
  );
}
```

Create `apps/mobile/components/session/AskAIButton.tsx`:

```tsx
import { TouchableOpacity } from "react-native";
import { Ionicons } from "@expo/vector-icons";

interface AskAIButtonProps {
  isRecording: boolean;
  isCooldown: boolean;
  onPressIn: () => void;
  onPressOut: () => void;
}

export function AskAIButton({ isRecording, isCooldown, onPressIn, onPressOut }: AskAIButtonProps) {
  return (
    <TouchableOpacity
      onPressIn={onPressIn}
      onPressOut={onPressOut}
      disabled={isCooldown}
      className={`absolute bottom-20 right-4 h-14 w-14 items-center justify-center rounded-full shadow-lg ${
        isCooldown
          ? "bg-gray-300"
          : isRecording
            ? "bg-red-500 scale-110"
            : "bg-blue-600"
      }`}
    >
      <Ionicons
        name={isRecording ? "mic" : "chatbubble-ellipses"}
        size={24}
        color="white"
      />
    </TouchableOpacity>
  );
}
```

- [ ] **Step 3: Create mobile JoinSessionSheet and FriendsSheet**

Create `apps/mobile/components/session/JoinSessionSheet.tsx`:

```tsx
import { View, Text, TextInput, TouchableOpacity } from "react-native";
import BottomSheet, { BottomSheetView } from "@gorhom/bottom-sheet";
import { forwardRef, useCallback, useState } from "react";

interface JoinSessionSheetProps {
  onJoin: (inviteCode: string) => void;
}

export const JoinSessionSheet = forwardRef<BottomSheet, JoinSessionSheetProps>(
  ({ onJoin }, ref) => {
    const [code, setCode] = useState("");

    const handleJoin = useCallback(() => {
      if (code.trim().length >= 6) {
        onJoin(code.trim().toUpperCase());
        setCode("");
      }
    }, [code, onJoin]);

    return (
      <BottomSheet ref={ref} index={-1} snapPoints={[250]} enablePanDownToClose>
        <BottomSheetView className="px-6 py-4">
          <Text className="text-lg font-semibold mb-4">Join Session</Text>
          <TextInput
            value={code}
            onChangeText={(t) => setCode(t.toUpperCase())}
            placeholder="Enter room code (e.g. RK4729)"
            maxLength={6}
            autoCapitalize="characters"
            className="rounded-lg border border-gray-300 px-4 py-3 text-center text-lg tracking-widest mb-4"
          />
          <TouchableOpacity
            onPress={handleJoin}
            disabled={code.length < 6}
            className={`rounded-lg py-3 items-center ${code.length >= 6 ? "bg-blue-600" : "bg-gray-300"}`}
          >
            <Text className={`font-medium ${code.length >= 6 ? "text-white" : "text-gray-500"}`}>
              Join Session
            </Text>
          </TouchableOpacity>
        </BottomSheetView>
      </BottomSheet>
    );
  }
);
```

Create `apps/mobile/components/session/FriendsSheet.tsx`:

```tsx
import { View, Text, TextInput, TouchableOpacity, FlatList } from "react-native";
import BottomSheet, { BottomSheetView, BottomSheetFlatList } from "@gorhom/bottom-sheet";
import { Ionicons } from "@expo/vector-icons";
import { forwardRef, useState } from "react";
import type { FriendInfo, SessionInfo } from "@rishi/shared";

interface FriendsSheetProps {
  friends: FriendInfo[];
  activeSessions: SessionInfo[];
  onSearch: (query: string) => Promise<any[]>;
  onSendRequest: (email: string) => Promise<boolean>;
  onAccept: (requestId: string) => void;
  onRemove: (id: string) => void;
  onJoinSession: (sessionId: string) => void;
}

export const FriendsSheet = forwardRef<BottomSheet, FriendsSheetProps>(
  ({ friends, activeSessions, onSearch, onSendRequest, onAccept, onRemove, onJoinSession }, ref) => {
    const [tab, setTab] = useState<"friends" | "search">("friends");
    const [searchQuery, setSearchQuery] = useState("");
    const [searchResults, setSearchResults] = useState<any[]>([]);

    const handleSearch = async (q: string) => {
      setSearchQuery(q);
      if (q.length >= 3) {
        const results = await onSearch(q);
        setSearchResults(results);
      } else {
        setSearchResults([]);
      }
    };

    const accepted = friends.filter((f) => f.status === "accepted");
    const pending = friends.filter((f) => f.status === "pending");

    return (
      <BottomSheet ref={ref} index={-1} snapPoints={["50%", "90%"]} enablePanDownToClose>
        <BottomSheetView className="px-4 pt-2">
          <Text className="text-lg font-semibold mb-3">Friends</Text>

          <View className="flex-row gap-2 mb-4">
            <TouchableOpacity
              onPress={() => setTab("friends")}
              className={`flex-1 rounded-lg py-2 items-center ${tab === "friends" ? "bg-blue-600" : "bg-gray-100"}`}
            >
              <Text className={tab === "friends" ? "text-white font-medium" : "text-gray-600"}>
                Friends {pending.length > 0 ? `(${pending.length})` : ""}
              </Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() => setTab("search")}
              className={`flex-1 rounded-lg py-2 items-center ${tab === "search" ? "bg-blue-600" : "bg-gray-100"}`}
            >
              <Text className={tab === "search" ? "text-white font-medium" : "text-gray-600"}>Search</Text>
            </TouchableOpacity>
          </View>

          {tab === "search" && (
            <TextInput
              value={searchQuery}
              onChangeText={handleSearch}
              placeholder="Search by name or email..."
              className="rounded-lg border border-gray-300 px-4 py-2 mb-3"
            />
          )}
        </BottomSheetView>

        <BottomSheetFlatList
          data={tab === "friends" ? [...activeSessions.map((s) => ({ ...s, _type: "session" as const })), ...pending.map((f) => ({ ...f, _type: "pending" as const })), ...accepted.map((f) => ({ ...f, _type: "friend" as const }))] : searchResults.map((u) => ({ ...u, _type: "search" as const }))}
          keyExtractor={(item: any) => item.id}
          contentContainerStyle={{ paddingHorizontal: 16 }}
          renderItem={({ item }: any) => {
            if (item._type === "session") {
              return (
                <View className="flex-row items-center justify-between rounded-lg border border-gray-200 p-3 mb-2">
                  <View>
                    <Text className="text-sm font-medium">{item.bookTitle}</Text>
                    <Text className="text-xs text-gray-500">{item.participantCount}/3</Text>
                  </View>
                  <TouchableOpacity onPress={() => onJoinSession(item.id)} className="bg-blue-600 rounded-lg px-3 py-1">
                    <Text className="text-xs text-white font-medium">Join</Text>
                  </TouchableOpacity>
                </View>
              );
            }
            if (item._type === "pending") {
              return (
                <View className="flex-row items-center justify-between rounded-lg border border-gray-200 p-3 mb-2">
                  <Text className="text-sm">{item.displayName}</Text>
                  <TouchableOpacity onPress={() => onAccept(item.id)} className="bg-blue-600 rounded-full p-1.5">
                    <Ionicons name="checkmark" size={16} color="white" />
                  </TouchableOpacity>
                </View>
              );
            }
            if (item._type === "friend") {
              return (
                <View className="flex-row items-center justify-between rounded-lg border border-gray-200 p-3 mb-2">
                  <Text className="text-sm">{item.displayName}</Text>
                  <TouchableOpacity onPress={() => onRemove(item.id)}>
                    <Ionicons name="close" size={16} color="#999" />
                  </TouchableOpacity>
                </View>
              );
            }
            // search result
            return (
              <View className="flex-row items-center justify-between rounded-lg border border-gray-200 p-3 mb-2">
                <View>
                  <Text className="text-sm font-medium">{item.displayName}</Text>
                  <Text className="text-xs text-gray-500">{item.email}</Text>
                </View>
                <TouchableOpacity onPress={() => onSendRequest(item.email)} className="bg-blue-600 rounded-full p-1.5">
                  <Ionicons name="person-add" size={16} color="white" />
                </TouchableOpacity>
              </View>
            );
          }}
        />
      </BottomSheet>
    );
  }
);
```

- [ ] **Step 4: Commit**

```bash
git add apps/mobile/components/session/
git commit -m "feat: add mobile session UI components (toolbar, overlay, participant view, AI button, sheets)"
```

---

## Task 15: Mobile — Integrate Session into Readers

**Files:**
- Modify: `apps/mobile/app/reader/[id].tsx`
- Modify: `apps/mobile/app/reader/pdf/[id].tsx`

- [ ] **Step 1: Integrate session into EPUB reader**

In `apps/mobile/app/reader/[id].tsx`, add session hooks and components. The EPUB reader uses `@epubjs-react-native/core` which provides a `Reader` component. Add page content extraction via the Reader's `injectJavascript` method to extract the current visible HTML:

```typescript
// Add to the reader component:
import { SessionToolbar } from "../../components/session/SessionToolbar";
import { SessionOverlay } from "../../components/session/SessionOverlay";
import { AskAIButton } from "../../components/session/AskAIButton";
import { ParticipantView } from "../../components/session/ParticipantView";
import { useSessionHost } from "../../hooks/useSessionHost";
import { useSessionParticipant } from "../../hooks/useSessionParticipant";

// Inside the component, add session state and conditional rendering:
// If user is participant, show ParticipantView instead of the Reader
// If user is host, show normal Reader + SessionToolbar + AskAIButton
```

- [ ] **Step 2: Integrate session into PDF reader**

Same pattern for `apps/mobile/app/reader/pdf/[id].tsx` — add session toolbar and conditionally show ParticipantView for non-host users.

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/app/reader/[id].tsx apps/mobile/app/reader/pdf/[id].tsx
git commit -m "feat: integrate reading sessions into mobile EPUB and PDF readers"
```

---

## Task 16: Deep Link Handling for Session Invites

**Files:**
- Modify: `apps/mobile/app.json` (or `app.config.ts`)
- Modify: `apps/main/src-tauri/tauri.conf.json`

- [ ] **Step 1: Configure mobile universal links**

In the Expo app config, ensure the `scheme` and `intentFilters` / `associatedDomains` include the session join path. The app should handle `https://rishi.fidexa.org/join/*` URLs:

```json
{
  "expo": {
    "scheme": "rishi",
    "ios": {
      "associatedDomains": ["applinks:rishi.fidexa.org"]
    },
    "android": {
      "intentFilters": [
        {
          "action": "VIEW",
          "autoVerify": true,
          "data": [{ "scheme": "https", "host": "rishi.fidexa.org", "pathPrefix": "/join" }],
          "category": ["BROWSABLE", "DEFAULT"]
        }
      ]
    }
  }
}
```

- [ ] **Step 2: Handle the deep link in mobile navigation**

In the mobile app's root layout or navigation, listen for incoming URLs and route `/join/:code` to the join session flow:

```typescript
import * as Linking from "expo-linking";

// In root layout useEffect:
const handleUrl = (event: { url: string }) => {
  const parsed = Linking.parse(event.url);
  if (parsed.path?.startsWith("join/")) {
    const inviteCode = parsed.path.replace("join/", "");
    // Navigate to join flow or open JoinSessionSheet with pre-filled code
    router.push(`/join-session?code=${inviteCode}`);
  }
};

Linking.addEventListener("url", handleUrl);
```

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/app.json apps/mobile/app/
git commit -m "feat: add deep link handling for session invite URLs on mobile"
```

---

## Task 17: Deploy & Test

- [ ] **Step 1: Deploy the Worker with Durable Object**

```bash
cd workers/worker && npx wrangler deploy
```

Expected: Deployment succeeds with SessionRoom DO class registered.

- [ ] **Step 2: Verify D1 migration**

```bash
cd workers/worker && npx wrangler d1 execute rishi-db --command "SELECT name FROM sqlite_master WHERE type='table'" --remote
```

Expected: Output includes `friends`, `reading_sessions`, `session_participants`.

- [ ] **Step 3: Test friend request flow**

Using curl or the app, verify:
1. Search returns Clerk users
2. Send friend request creates pending row
3. Accept updates status to accepted
4. List returns accepted friends

- [ ] **Step 4: Test session creation and WebSocket connection**

1. Create a session via POST `/api/sessions/create`
2. Connect WebSocket to `/api/sessions/ws/:sessionId`
3. Verify WebSocket opens and receives messages

- [ ] **Step 5: Test cross-platform session**

1. Host creates session on desktop
2. Participant joins on mobile via invite code
3. Verify: audio flows bidirectionally, page content streams, cursor visible

- [ ] **Step 6: Test AI ask flow**

1. During active session, participant presses Ask AI
2. Verify: question is transcribed, AI response generated, TTS audio plays for all

- [ ] **Step 7: Commit any test fixes**

```bash
git add -A && git commit -m "fix: address issues found during integration testing"
```
