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
}
