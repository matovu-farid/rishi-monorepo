export const APPLE_ROSTER_VERSION = 1 as const;
export const APPLE_ROSTER_MAX_PARTICIPANTS = 5;

type AppleRosterParticipant = {
  userId: string;
  profile: { displayName: string; avatarUrl?: string };
  joinedAt: number;
  bookReady: boolean;
  connectionGeneration: number;
  connectionState: "connected" | "reconnecting";
};

type AppleRosterState = {
  sessionId: string;
  roomEpoch: number;
  controllerGeneration: number;
  controllerUserId: string;
  rosterGeneration: number;
  maxParticipants: number;
  participants: Record<string, AppleRosterParticipant>;
};

export function buildAppleRosterMessage(state: AppleRosterState): Record<string, unknown> {
  const limit = Math.min(
    APPLE_ROSTER_MAX_PARTICIPANTS,
    Math.max(0, Math.floor(state.maxParticipants)),
  );
  const participants = Object.values(state.participants)
    .filter((participant) => participant.connectionState === "connected")
    .filter((participant) => withinBytes(participant.userId, 64))
    .filter((participant) => withinBytes(participant.profile.displayName, 100))
    .filter((participant) => participant.profile.avatarUrl === undefined || withinBytes(participant.profile.avatarUrl, 2_048))
    .sort((a, b) => a.joinedAt - b.joinedAt || a.userId.localeCompare(b.userId))
    .slice(0, limit)
    .map((participant) => ({
      userId: participant.userId,
      profile: participant.profile,
      joinedAt: participant.joinedAt,
      bookReady: participant.bookReady,
      connectionState: participant.connectionState,
      isController: participant.userId === state.controllerUserId,
    }));

  return {
    t: "participant.roster",
    v: APPLE_ROSTER_VERSION,
    sessionId: state.sessionId,
    roomEpoch: state.roomEpoch,
    controllerGeneration: state.controllerGeneration,
    connectionGeneration: 0,
    rosterGeneration: state.rosterGeneration,
    participants,
  };
}

function withinBytes(value: string, maxBytes: number): boolean {
  return new TextEncoder().encode(value).byteLength <= maxBytes;
}

export function appleFenceMatches(
  state: Pick<AppleRosterState, "roomEpoch" | "controllerGeneration">,
  expectedConnectionGeneration: number,
  value: { roomEpoch?: unknown; controllerGeneration?: unknown; connectionGeneration?: unknown } | null | undefined,
): boolean {
  return Number.isSafeInteger(value?.roomEpoch)
    && Number.isSafeInteger(value?.controllerGeneration)
    && Number.isSafeInteger(value?.connectionGeneration)
    && value?.roomEpoch === state.roomEpoch
    && value?.controllerGeneration === state.controllerGeneration
    && value?.connectionGeneration === expectedConnectionGeneration;
}

export function appleRoomFenceMatches(
  state: Pick<AppleRosterState, "roomEpoch" | "controllerGeneration">,
  value: { roomEpoch?: unknown; controllerGeneration?: unknown } | null | undefined,
): boolean {
  return Number.isSafeInteger(value?.roomEpoch)
    && Number.isSafeInteger(value?.controllerGeneration)
    && value?.roomEpoch === state.roomEpoch
    && value?.controllerGeneration === state.controllerGeneration;
}
