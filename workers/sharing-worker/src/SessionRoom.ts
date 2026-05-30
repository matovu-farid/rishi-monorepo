import { DurableObject } from "cloudflare:workers";
import type { SessionState } from "./types";
import type { BookContextT } from "./types";

interface Env {
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
}

const KEY = "state";

type StoredState = SessionState & { hostProfileFallback: { displayName: string; avatarUrl?: string } };

export class SessionRoom extends DurableObject<Env> {
  async createSession(input: {
    sessionId: string;
    hostUserId: string;
    hostProfile: { displayName: string; avatarUrl?: string };
    bookContext: BookContextT;
    requiresApproval: boolean;
  }): Promise<void> {
    const existing = await this.ctx.storage.get<StoredState>(KEY);
    if (existing) throw new Error("already initialized");
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
  }

  async getState(): Promise<StoredState | null> {
    return (await this.ctx.storage.get<StoredState>(KEY)) ?? null;
  }

  async getInfoForRedeem(): Promise<null | {
    sessionId: string;
    bookContext: SessionState["bookContext"];
    requiresApproval: boolean;
    hostProfile: { displayName: string; avatarUrl?: string };
    status: SessionState["status"];
  }> {
    const state = await this.ctx.storage.get<StoredState>(KEY);
    if (!state) return null;
    return {
      sessionId: state.sessionId,
      bookContext: state.bookContext,
      requiresApproval: state.requiresApproval,
      hostProfile: state.participants[state.hostUserId]?.profile ?? state.hostProfileFallback,
      status: state.status,
    };
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade") !== "websocket") return new Response("Expected websocket", { status: 426 });
    const { parseSubprotocols } = await import("./wsCreds");
    const creds = parseSubprotocols(request.headers.get("sec-websocket-protocol"));
    if (!creds.valid) return new Response(creds.reason, { status: 400 });

    // Real auth happens in a later task. For now the test path is permissive.
    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernation API: accept lets the DO sleep between messages.
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }
}
