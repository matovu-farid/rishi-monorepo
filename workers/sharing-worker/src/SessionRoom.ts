import { DurableObject } from "cloudflare:workers";
import type { SessionState } from "./types";
import type { BookContextT } from "./types";

interface Env {
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
}

const KEY = "state";

export class SessionRoom extends DurableObject<Env> {
  async createSession(input: {
    sessionId: string;
    hostUserId: string;
    hostProfile: { displayName: string; avatarUrl?: string };
    bookContext: BookContextT;
    requiresApproval: boolean;
  }): Promise<void> {
    const existing = await this.ctx.storage.get<SessionState>(KEY);
    if (existing) throw new Error("already initialized");
    const state: SessionState = {
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
    };
    await this.ctx.storage.put(KEY, state);
  }

  async getState(): Promise<SessionState | null> {
    return (await this.ctx.storage.get<SessionState>(KEY)) ?? null;
  }
}
