import { describe, expect, it } from "vitest";
import { appleFenceMatches, buildAppleRosterMessage } from "../src/appleTopology";

const state = {
  sessionId: "session-1",
  roomEpoch: 7,
  controllerGeneration: 3,
  controllerUserId: "u_host",
  maxParticipants: 5,
  participants: {
    u_host: {
      userId: "u_host",
      profile: { displayName: "Host" },
      joinedAt: 1,
      bookReady: true,
      connectionGeneration: 4,
      connectionState: "connected" as const,
    },
    u_viewer: {
      userId: "u_viewer",
      profile: { displayName: "Viewer" },
      joinedAt: 2,
      bookReady: true,
      connectionGeneration: 1,
      connectionState: "reconnecting" as const,
    },
  },
};

describe("Apple room topology", () => {
  it("publishes a bounded versioned roster containing only connected participants", () => {
    const message = buildAppleRosterMessage({ ...state, rosterGeneration: 12 });

    expect(message).toEqual({
      t: "participant.roster",
      v: 1,
      sessionId: "session-1",
      roomEpoch: 7,
      controllerGeneration: 3,
      connectionGeneration: 0,
      rosterGeneration: 12,
      participants: [{
        userId: "u_host",
        profile: { displayName: "Host" },
        joinedAt: 1,
        bookReady: true,
        connectionState: "connected",
        isController: true,
      }],
    });
  });

  it("caps the roster even when the room state contains more participants", () => {
    const participants = Object.fromEntries(Array.from({ length: 6 }, (_, index) => {
      const userId = `u_${index}`;
      return [userId, {
        userId,
        profile: { displayName: userId },
        joinedAt: index,
        bookReady: true,
        connectionGeneration: 1,
        connectionState: "connected" as const,
      }];
    }));

    const message = buildAppleRosterMessage({
      ...state,
      maxParticipants: 99,
      participants,
      rosterGeneration: 13,
    });

    expect(message.participants).toHaveLength(5);
    expect((message.participants as Array<{ userId: string }>).map(({ userId }) => userId)).toEqual([
      "u_0", "u_1", "u_2", "u_3", "u_4",
    ]);
  });

  it("rejects stale socket generations and room/controller fences", () => {
    const current = { roomEpoch: 7, controllerGeneration: 3, connectionGeneration: 4 };

    expect(appleFenceMatches(state, 4, current)).toBe(true);
    expect(appleFenceMatches(state, 4, { ...current, connectionGeneration: 3 })).toBe(false);
    expect(appleFenceMatches(state, 4, { ...current, roomEpoch: 6 })).toBe(false);
    expect(appleFenceMatches(state, 4, { ...current, controllerGeneration: 2 })).toBe(false);
    expect(appleFenceMatches(state, 4, { roomEpoch: 7, controllerGeneration: 3 })).toBe(false);
  });
});
