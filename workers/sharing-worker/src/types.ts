import type { Participant, BookContext } from "./schemas";
import type { z } from "zod";

export type ParticipantInfo = z.infer<typeof Participant>;
export type BookContextT = z.infer<typeof BookContext>;

export type SessionKind = "legacy" | "apple";
export type AdmissionPolicy = "legacy-bearer" | "invite-ticket";
export type AppleSessionStatus = "waiting" | "active" | "ended";
export type LegacySessionStatus = "live" | "host-suspended" | "ended";

export interface AdmissionRecord {
  inviteId: string;
  contentHash: string;
  bookReady: boolean;
  status: "ready" | "admitted" | "left" | "removed" | "expired";
  admissionConnectionGeneration: number;
  lastAdmissionTicketId?: string;
  profile?: { displayName: string; avatarUrl?: string };
  updatedAt: number;
}

export interface SeatReservation {
  userId: string;
  reservedUntil: number;
  connectionGeneration: number;
  reason: "unexpected-disconnect";
}

export interface SpeakerFloor {
  userId: string;
  requestId: string;
  grantedAt: number;
}

export type StoredParticipant = ParticipantInfo & {
  /** True only after the primary Worker has verified the local book hash. */
  bookReady?: boolean;
  inviteId?: string;
  contentHash?: string;
  admissionConnectionGeneration?: number;
  /** Generation of the socket currently allowed to mutate this record. */
  connectionGeneration?: number;
  connectionId?: string;
  pendingAdmissionTicketId?: string;
  /** Persistent byte budget window for Apple signaling. */
  signalingWindowStartedAt?: number;
  signalingBytes?: number;
  /** Legacy reconnect state remains on the participant for compatibility. */
  reservedUntil?: number;
};

export interface SessionState {
  sessionId: string;
  /** Original creator identity is retained for audit and legacy compatibility. */
  creatorUserId?: string;
  hostUserId: string;
  sharerUserId: string;
  sessionKind?: SessionKind;
  admissionPolicy?: AdmissionPolicy;
  initialSharerUserId?: string;
  controllerUserId?: string;
  controllerGeneration?: number;
  roomEpoch?: number;
  lastEmptyAt?: number;
  controllerReturnUntil?: number;
  controllerReturnUserId?: string;
  bookContext: BookContextT;
  requiresApproval: boolean;
  status: LegacySessionStatus | AppleSessionStatus;
  createdAt: number;
  hostSuspendedUntil?: number;
  maxParticipants?: number;
  participants: Record<string, StoredParticipant>;
  seatReservations?: Record<string, SeatReservation>;
  removedUserIds?: string[];
  speakerFloor?: SpeakerFloor | null;
  admissionRecords?: Record<string, AdmissionRecord>;
  /** Single-use admission tickets. Values are expiry timestamps for cleanup. */
  consumedAdmissionTicketIds?: Record<string, number>;
  inviteId?: string;
  pendingJoiners: Record<string, { profile: { displayName: string; avatarUrl?: string }; requestedAt: number; hasBookFile?: boolean }>;
  joinTokens: Record<string, { issuedAt: number; expiresAt: number; uses: number }>;
  sdpRelayCount?: number;
}
