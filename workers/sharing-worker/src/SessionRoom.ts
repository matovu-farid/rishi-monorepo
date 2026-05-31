import { DurableObject } from "cloudflare:workers";
import { ClientMsg } from "./schemas";
import type { SessionState, BookContextT } from "./types";
import { parseSubprotocols } from "./wsCreds";
import { issueReconnectToken, verifyReconnectToken } from "./tokens";
import { CONFIG } from "./config";
import { RateBucket } from "./rateLimit";

interface Env {
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
}

const KEY = "state";

type StoredState = SessionState & { hostProfileFallback: { displayName: string; avatarUrl?: string } };

interface AttachedMeta {
  userId: string;
  displayName: string;
  avatarUrl?: string;
}

export class SessionRoom extends DurableObject<Env> {
  private lastRequestSharer = new Map<string, number>();
  private pendingSockets = new Map<string, { ws: WebSocket; hasBookFile: boolean }>();
  private frameBuckets = new Map<string, RateBucket>();

  private log(event: string, fields: Record<string, unknown> = {}) {
    console.log(JSON.stringify({ event, ts: Date.now(), ...fields }));
  }

  private bucketFor(userId: string): RateBucket {
    let b = this.frameBuckets.get(userId);
    if (!b) {
      b = new RateBucket({
        capacity: CONFIG.RATE_LIMITS.framesPerSocketPerSec * 2,
        refillPerSec: CONFIG.RATE_LIMITS.framesPerSocketPerSec,
      });
      this.frameBuckets.set(userId, b);
    }
    return b;
  }

  // ---------- HTTP RPC ----------
  async createSession(input: {
    sessionId: string;
    hostUserId: string;
    hostProfile: { displayName: string; avatarUrl?: string };
    bookContext: BookContextT;
    requiresApproval: boolean;
  }): Promise<void> {
    if (await this.ctx.storage.get(KEY)) throw new Error("already initialized");
    const state: StoredState = {
      sessionId: input.sessionId,
      hostUserId: input.hostUserId,
      sharerUserId: input.hostUserId,
      bookContext: input.bookContext,
      requiresApproval: input.requiresApproval,
      status: "live",
      createdAt: Date.now(),
      participants: {},
      pendingJoiners: {},
      joinTokens: {},
      hostProfileFallback: input.hostProfile,
    };
    await this.ctx.storage.put(KEY, state);
    this.log("session.created", { sessionId: input.sessionId, host: input.hostUserId });
  }

  async getState(): Promise<StoredState | null> {
    return (await this.ctx.storage.get<StoredState>(KEY)) ?? null;
  }

  async getInfoForRedeem() {
    const s = await this.ctx.storage.get<StoredState>(KEY);
    if (!s) return null;
    return {
      sessionId: s.sessionId,
      bookContext: s.bookContext,
      requiresApproval: s.requiresApproval,
      hostProfile: s.participants[s.hostUserId]?.profile ?? s.hostProfileFallback,
      status: s.status,
    };
  }

  // ---------- WS upgrade ----------
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade") !== "websocket") return new Response("Expected websocket", { status: 426 });
    const creds = parseSubprotocols(request.headers.get("sec-websocket-protocol"));
    if (!creds.valid) return new Response(creds.reason, { status: 400 });

    let meta: AttachedMeta;
    const testJwtMatch = creds.jwt.match(/^([^\s-]+(?:-[^\s-]+)*)--(.+)$/);
    if (testJwtMatch) {
      // Test shortcut: jwt of the form "userId--DisplayName" (with "_" for spaces
      // in the display name) — attach without remote auth. The double-dash and
      // underscore-for-space encoding keeps the bearer valid as an RFC 6455
      // WebSocket subprotocol token (no ":" or spaces allowed).
      meta = {
        userId: testJwtMatch[1],
        displayName: testJwtMatch[2].replace(/_/g, " "),
      };
    } else {
      const testAuth = (globalThis as any).__TEST_AUTH__;
      if (testAuth) {
        meta = { userId: testAuth.userId, displayName: testAuth.displayName, avatarUrl: testAuth.avatarUrl };
      } else {
        // Production path: verify with Better Auth.
        try {
          const { verifyAuthToken } = await import("./auth");
          const u = await verifyAuthToken(creds.jwt, this.env);
          meta = { userId: u.userId, displayName: u.displayName, avatarUrl: u.avatarUrl };
        } catch (e) {
          return new Response((e as Error).message, { status: 401 });
        }
      }
    }

    let isReconnect = false;
    if (creds.reconnectToken) {
      try {
        const v = await verifyReconnectToken(creds.reconnectToken, this.env.WORKER_HMAC_SECRET);
        if (v.userId === meta.userId) isReconnect = true;
      } catch { /* invalid token → treat as fresh */ }
    }

    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernation API: tag encodes per-socket metadata so it survives hibernation.
    // Keep tag well under 256-char cap: avoid storing the raw JWT.
    this.ctx.acceptWebSocket(server, [JSON.stringify({ meta, isReconnect })]);
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---------- Hibernation handlers ----------
  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
    let parsed;
    try { parsed = ClientMsg.safeParse(JSON.parse(text)); }
    catch { this.sendError(ws, "bad_json", "could not parse"); return; }
    if (!parsed.success) { this.sendError(ws, "bad_msg", parsed.error.message); return; }
    const msg = parsed.data;
    const meta = this.metaFor(ws);
    if (!meta) { this.sendError(ws, "no_meta", "ws not initialized"); return; }

    if (!this.bucketFor(meta.userId).tryConsume()) {
      this.sendError(ws, "rate_limited", "too many messages");
      return;
    }

    switch (msg.t) {
      case "hello": await this.handleHello(ws, meta, msg.hasBookFile); break;
      case "ping":  this.sendTo(ws, { t: "pong" }); break;
      case "leave": await this.removeParticipant(meta.userId, "left"); ws.close(1000, "left"); break;
      case "sdp.offer":
      case "sdp.answer":
      case "ice": {
        const target = this.findSocketByUserId(msg.to);
        if (!target) { this.sendError(ws, "no_such_peer", `peer ${msg.to} not connected`); break; }
        if (msg.t !== "ice") {
          const state = await this.loadState();
          if (state) {
            state.sdpRelayCount = (state.sdpRelayCount ?? 0) + 1;
            if (state.sdpRelayCount > CONFIG.RATE_LIMITS.sdpRelaysPerSession) {
              this.sendError(ws, "rate_limited", "sdp relay budget exhausted"); break;
            }
            await this.saveState(state);
          }
        }
        this.sendTo(target, msg.t === "ice"
          ? { t: "ice", from: meta.userId, candidate: msg.candidate }
          : { t: msg.t, from: meta.userId, sdp: msg.sdp });
        break;
      }
      case "pass.sharer": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "only host can pass"); break; }
        const target = state.participants[msg.to];
        if (!target) { this.sendError(ws, "no_such_peer", `${msg.to} not in session`); break; }
        if (!target.hasBookFile) { this.sendError(ws, "target_lacks_book", "target has no book file"); break; }
        state.sharerUserId = msg.to;
        await this.saveState(state);
        for (const s of this.sockets()) this.sendTo(s, { t: "role.transferred", newSharerId: msg.to });
        this.log("role.transferred", { sessionId: state.sessionId, from: meta.userId, to: msg.to });
        break;
      }
      case "request.sharer": {
        const last = this.lastRequestSharer.get(meta.userId) ?? 0;
        if (Date.now() - last < CONFIG.RATE_LIMITS.requestSharerCooldownMs) {
          this.sendError(ws, "rate_limited", "wait before requesting again"); break;
        }
        this.lastRequestSharer.set(meta.userId, Date.now());
        const state = await this.loadState();
        if (!state) break;
        const hostWs = this.findSocketByUserId(state.hostUserId);
        if (hostWs) this.sendTo(hostWs, { t: "peer.updated", userId: meta.userId, patch: { requestingSharer: true } });
        break;
      }
      case "has.book": {
        const state = await this.loadState();
        if (!state || !state.participants[meta.userId]) break;
        state.participants[meta.userId].hasBookFile = msg.value;
        await this.saveState(state);
        for (const s of this.sockets()) this.sendTo(s, { t: "peer.updated", userId: meta.userId, patch: { hasBookFile: msg.value } });
        break;
      }
      case "mic.state": {
        const state = await this.loadState();
        if (!state || !state.participants[meta.userId]) break;
        // Host-mute stays sticky; self changes can't override host mute.
        if (state.participants[meta.userId].micState !== "host-muted") {
          state.participants[meta.userId].micState = msg.value;
          await this.saveState(state);
          for (const s of this.sockets()) this.sendTo(s, { t: "peer.updated", userId: meta.userId, patch: { micState: msg.value } });
        }
        break;
      }
      case "mute.peer": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        if (!state.participants[msg.userId]) { this.sendError(ws, "no_such_peer", msg.userId); break; }
        state.participants[msg.userId].micState = msg.muted ? "host-muted" : "unmuted";
        await this.saveState(state);
        for (const s of this.sockets()) this.sendTo(s, { t: "peer.updated", userId: msg.userId, patch: { micState: state.participants[msg.userId].micState } });
        break;
      }
      case "kick.peer": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        if (msg.userId === meta.userId) { this.sendError(ws, "forbidden", "cannot kick self"); break; }
        const target = this.findSocketByUserId(msg.userId);
        if (target) {
          this.sendTo(target, { t: "kicked", reason: "removed by host" });
          target.close(1000, "kicked");
        }
        await this.removeParticipant(msg.userId, "kicked");
        break;
      }
      case "approve.join": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        const pending = this.pendingSockets.get(msg.userId);
        delete state.pendingJoiners[msg.userId];
        await this.saveState(state);
        if (!pending) break;
        this.pendingSockets.delete(msg.userId);
        this.sendTo(pending.ws, { t: "approval.result", approved: true });
        const pendingMeta = this.metaFor(pending.ws);
        if (pendingMeta) await this.admitParticipant(pending.ws, pendingMeta, pending.hasBookFile, state);
        break;
      }
      case "reject.join": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        delete state.pendingJoiners[msg.userId];
        await this.saveState(state);
        const pending = this.pendingSockets.get(msg.userId);
        if (pending) {
          this.pendingSockets.delete(msg.userId);
          this.sendTo(pending.ws, { t: "approval.result", approved: false, reason: "rejected by host" });
          pending.ws.close(1000, "rejected");
        }
        break;
      }
      // Other handlers added in later tasks.
      default: this.sendError(ws, "unknown", `no handler for ${(msg as any).t}`);
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const meta = this.metaFor(ws);
    if (!meta) return;
    const state = await this.loadState();
    if (!state || !state.participants[meta.userId]) return;
    // Explicit `leave` (code 1000 from our own close call) already removed the participant.
    if (code === 1000 && !state.participants[meta.userId]) return;
    if (meta.userId === state.hostUserId) {
      state.status = "host-suspended";
      state.hostSuspendedUntil = Date.now() + CONFIG.HOST_GRACE_MS;
      await this.saveState(state);
      for (const s of this.sockets()) if (s !== ws) this.sendTo(s, {
        t: "host.suspended", until: state.hostSuspendedUntil,
      });
      await this.scheduleNextAlarm();
      return;
    }
    const reservedUntil = Date.now() + CONFIG.VIEWER_SLOT_GRACE_MS;
    state.participants[meta.userId].connectionState = "reconnecting";
    state.participants[meta.userId].reservedUntil = reservedUntil;
    await this.saveState(state);
    for (const s of this.sockets()) this.sendTo(s, {
      t: "peer.updated", userId: meta.userId, patch: { connectionState: "reconnecting" },
    });
    await this.scheduleNextAlarm();
  }

  async alarm(): Promise<void> {
    const state = await this.loadState();
    if (!state) return;
    // Post-end purge: drop the session state once status is ended.
    if (state.status === "ended") {
      await this.ctx.storage.delete(KEY);
      await this.ctx.storage.deleteAlarm();
      return;
    }
    const now = Date.now();
    // Host-grace expiry: end the session.
    if (state.status === "host-suspended" && state.hostSuspendedUntil && state.hostSuspendedUntil <= now) {
      state.status = "ended";
      await this.saveState(state);
      for (const s of this.sockets()) {
        this.sendTo(s, { t: "session.ended", reason: "host_grace_expired" });
        s.close(1000, "ended");
      }
      this.log("session.ended", { sessionId: state.sessionId, reason: "host_grace_expired" });
      await this.ctx.storage.setAlarm(Date.now() + CONFIG.STORAGE_PURGE_AFTER_END_MS);
      return;
    }
    // Approval timeouts
    for (const [userId, v] of Object.entries(state.pendingJoiners)) {
      if (v.requestedAt + CONFIG.APPROVAL_TIMEOUT_MS <= now) {
        delete state.pendingJoiners[userId];
        const pending = this.pendingSockets.get(userId);
        if (pending) {
          this.pendingSockets.delete(userId);
          this.sendTo(pending.ws, { t: "approval.result", approved: false, reason: "approval timeout" });
          pending.ws.close(1000, "timeout");
        }
      }
    }
    // Reconnect-slot reservation expiry: evict viewers whose reserved window passed.
    let sharerChanged = false;
    for (const [userId, p] of Object.entries(state.participants)) {
      if (p.reservedUntil && p.reservedUntil <= now) {
        delete state.participants[userId];
        if (state.sharerUserId === userId && userId !== state.hostUserId) {
          state.sharerUserId = state.hostUserId;
          sharerChanged = true;
        }
        const left = { t: "peer.left", userId, reason: "dropped" } as const;
        for (const ws of this.sockets()) {
          const m = this.metaFor(ws);
          if (m?.userId !== userId) this.sendTo(ws, left);
        }
      }
    }
    if (sharerChanged) {
      for (const ws of this.sockets()) this.sendTo(ws, { t: "role.transferred", newSharerId: state.sharerUserId });
    }
    // Future alarm branches (host grace) added in later tasks.
    await this.saveState(state);
    await this.scheduleNextAlarm();
  }

  // ---------- Hello ----------
  private async handleHello(ws: WebSocket, meta: AttachedMeta, hasBookFile: boolean) {
    const state = await this.loadState();
    if (!state) { this.sendError(ws, "no_session", "session not found"); ws.close(1011, "no session"); return; }
    if (state.status === "ended") { this.sendError(ws, "session_ended", "session is over"); ws.close(1000, "ended"); return; }

    // Reconnect path: existing participant + reconnect-flag → resume in their reserved slot.
    const existing = state.participants[meta.userId];
    const tagJson = this.ctx.getTags(ws)[0];
    const isReconnect = tagJson ? !!JSON.parse(tagJson).isReconnect : false;
    if (existing && isReconnect) {
      existing.connectionState = "connected";
      existing.hasBookFile = hasBookFile;
      delete existing.reservedUntil;
      // Host reconnect resumes the session (sharer role stays where it was).
      if (meta.userId === state.hostUserId && state.status === "host-suspended") {
        state.status = "live";
        state.hostSuspendedUntil = undefined;
        for (const s of this.sockets()) if (s !== ws) this.sendTo(s, { t: "host.resumed" });
      }
      await this.saveState(state);
      const newReservedUntil = Date.now() + CONFIG.HOST_GRACE_MS;
      const newRt = await issueReconnectToken(
        { sessionId: state.sessionId, userId: meta.userId, reservedUntil: newReservedUntil },
        this.env.WORKER_HMAC_SECRET,
      );
      const role: "host" | "viewer" = meta.userId === state.hostUserId ? "host" : "viewer";
      this.sendTo(ws, {
        t: "welcome", you: meta.userId, role,
        sharerId: state.sharerUserId, reconnectToken: newRt, reservedUntil: newReservedUntil,
      });
      for (const s of this.sockets()) if (s !== ws) this.sendTo(s, {
        t: "peer.updated", userId: meta.userId, patch: { connectionState: "connected", hasBookFile },
      });
      await this.broadcastRoster(state);
      return;
    }

    if (Object.keys(state.participants).length >= CONFIG.MAX_PARTICIPANTS && !state.participants[meta.userId]) {
      this.sendError(ws, "cap_reached", "session is full"); ws.close(1000, "full"); return;
    }
    if (state.status === "host-suspended" && meta.userId !== state.hostUserId) {
      this.sendError(ws, "host_suspended", "host disconnected"); ws.close(1000, "host suspended"); return;
    }

    // Approval gate: non-host joiners that aren't already participants get queued.
    if (state.requiresApproval && meta.userId !== state.hostUserId && !state.participants[meta.userId]) {
      state.pendingJoiners[meta.userId] = {
        profile: { displayName: meta.displayName, avatarUrl: meta.avatarUrl },
        requestedAt: Date.now(),
      };
      await this.saveState(state);
      this.pendingSockets.set(meta.userId, { ws, hasBookFile });
      const hostWs = this.findSocketByUserId(state.hostUserId);
      if (hostWs) this.sendTo(hostWs, {
        t: "join.requested",
        userId: meta.userId,
        profile: state.pendingJoiners[meta.userId].profile,
      });
      this.log("peer.queued", { sessionId: state.sessionId, userId: meta.userId });
      await this.scheduleNextAlarm();
      return;
    }

    await this.admitParticipant(ws, meta, hasBookFile, state);
  }

  private async admitParticipant(ws: WebSocket, meta: AttachedMeta, hasBookFile: boolean, state: StoredState) {
    const reservedUntil = Date.now() + CONFIG.HOST_GRACE_MS;
    state.participants[meta.userId] = {
      userId: meta.userId,
      profile: { displayName: meta.displayName, avatarUrl: meta.avatarUrl },
      joinedAt: Date.now(),
      hasBookFile,
      micState: "unmuted",
      connectionState: "connected",
    };
    await this.saveState(state);

    const reconnectToken = await issueReconnectToken(
      { sessionId: state.sessionId, userId: meta.userId, reservedUntil },
      this.env.WORKER_HMAC_SECRET,
    );
    const role: "host" | "viewer" = meta.userId === state.hostUserId ? "host" : "viewer";
    this.sendTo(ws, {
      t: "welcome",
      you: meta.userId,
      role,
      sharerId: state.sharerUserId,
      reconnectToken,
      reservedUntil,
    });

    // Broadcast peer.joined to others (skip self).
    for (const otherWs of this.sockets()) {
      if (otherWs === ws) continue;
      this.sendTo(otherWs, {
        t: "peer.joined",
        userId: meta.userId,
        profile: state.participants[meta.userId].profile,
        hasBookFile,
      });
    }

    await this.broadcastRoster(state);
    this.log("peer.admitted", { sessionId: state.sessionId, userId: meta.userId, role });
  }

  // ---------- Helpers ----------
  private metaFor(ws: WebSocket): AttachedMeta | null {
    const tags = this.ctx.getTags(ws);
    if (!tags[0]) return null;
    try { return JSON.parse(tags[0]).meta as AttachedMeta; } catch { return null; }
  }
  private sockets(): WebSocket[] { return this.ctx.getWebSockets(); }
  private sendTo(ws: WebSocket, msg: Record<string, unknown>) {
    ws.send(JSON.stringify({ v: 1, ...msg }));
  }
  private sendError(ws: WebSocket, code: string, message: string) {
    this.sendTo(ws, { t: "error", code, message });
  }
  private findSocketByUserId(userId: string): WebSocket | null {
    for (const ws of this.sockets()) {
      const m = this.metaFor(ws);
      if (m?.userId === userId) return ws;
    }
    return null;
  }
  private async loadState() {
    return (await this.ctx.storage.get<StoredState>(KEY)) ?? null;
  }
  private async saveState(s: StoredState) { await this.ctx.storage.put(KEY, s); }
  private async broadcastRoster(state: StoredState) {
    const msg = {
      t: "roster",
      participants: Object.values(state.participants),
      pendingJoiners: Object.entries(state.pendingJoiners).map(([userId, v]) => ({ userId, ...v })),
      requiresApproval: state.requiresApproval,
      bookContext: state.bookContext,
      status: state.status,
      hostSuspendedUntil: state.hostSuspendedUntil,
    };
    for (const ws of this.sockets()) this.sendTo(ws, msg);
  }
  private async removeParticipant(userId: string, reason: "left" | "kicked" | "dropped") {
    const state = await this.loadState();
    if (!state) return;
    if (!state.participants[userId]) return;
    delete state.participants[userId];
    let sharerChanged = false;
    if (state.sharerUserId === userId && userId !== state.hostUserId) {
      state.sharerUserId = state.hostUserId;
      sharerChanged = true;
    }
    await this.saveState(state);
    const left = { t: "peer.left", userId, reason };
    for (const ws of this.sockets()) {
      const m = this.metaFor(ws);
      if (m?.userId !== userId) this.sendTo(ws, left);
    }
    if (sharerChanged) {
      for (const ws of this.sockets()) this.sendTo(ws, { t: "role.transferred", newSharerId: state.sharerUserId });
    }
  }

  private async scheduleNextAlarm() {
    const state = await this.loadState();
    if (!state) return;
    const candidates: number[] = [];
    const now = Date.now();
    for (const v of Object.values(state.pendingJoiners)) candidates.push(v.requestedAt + CONFIG.APPROVAL_TIMEOUT_MS);
    for (const p of Object.values(state.participants)) {
      if (p.reservedUntil) candidates.push(p.reservedUntil);
    }
    if (state.hostSuspendedUntil) candidates.push(state.hostSuspendedUntil);
    if (candidates.length === 0) { await this.ctx.storage.deleteAlarm(); return; }
    const next = Math.max(now + 100, Math.min(...candidates));
    await this.ctx.storage.setAlarm(next);
  }
}
