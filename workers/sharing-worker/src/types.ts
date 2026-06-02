import type { Participant, BookContext } from "./schemas";
import type { z } from "zod";

export type ParticipantInfo = z.infer<typeof Participant>;
export type BookContextT = z.infer<typeof BookContext>;

export interface SessionState {
  sessionId: string;
  hostUserId: string;
  sharerUserId: string;
  bookContext: BookContextT;
  requiresApproval: boolean;
  status: "live" | "host-suspended" | "ended";
  createdAt: number;
  hostSuspendedUntil?: number;
  participants: Record<string, ParticipantInfo & { reservedUntil?: number }>;
  pendingJoiners: Record<string, { profile: { displayName: string; avatarUrl?: string }; requestedAt: number; hasBookFile?: boolean }>;
  joinTokens: Record<string, { issuedAt: number; expiresAt: number; uses: number }>;
  sdpRelayCount?: number;
}
