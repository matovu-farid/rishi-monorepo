import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

import {
  INACTIVITY_TIMEOUT_MS,
  idleAgeMs,
  shouldTerminateForInactivity,
} from "./timing";

const here = dirname(fileURLToPath(import.meta.url));

/** Mirrors ledger ClientControlMessageSchema for unit coverage. */
const ClientControlMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("client_ack") }),
  z.object({ type: z.literal("client_activity") }),
]);

describe("voice session inactivity timeout", () => {
  it("INACTIVITY_TIMEOUT_MS is exactly 5 minutes", () => {
    expect(INACTIVITY_TIMEOUT_MS).toBe(300_000);
    expect(INACTIVITY_TIMEOUT_MS).toBe(5 * 60_000);
  });

  it("idleAgeMs returns null when lastActivityAt is null (treat as idle)", () => {
    expect(idleAgeMs(null, 1_000_000)).toBeNull();
    expect(idleAgeMs(undefined, 1_000_000)).toBeNull();
  });

  it("idleAgeMs is now - last when set", () => {
    expect(idleAgeMs(1000, 1500)).toBe(500);
  });

  describe("shouldTerminateForInactivity", () => {
    const t0 = 1_000_000;

    it("null lastActivityAt terminates immediately (no updatedAt immortalize)", () => {
      expect(shouldTerminateForInactivity(null, t0)).toBe(true);
      expect(shouldTerminateForInactivity(null, t0, "realtime")).toBe(true);
      expect(shouldTerminateForInactivity(null, t0 + 1)).toBe(true);
    });

    it("boundary: idle age === timeout terminates", () => {
      const last = t0;
      expect(shouldTerminateForInactivity(last, last + INACTIVITY_TIMEOUT_MS)).toBe(true);
      expect(shouldTerminateForInactivity(last, last + INACTIVITY_TIMEOUT_MS, "realtime")).toBe(
        true,
      );
    });

    it("boundary: idle age === timeout - 1 ms does not terminate", () => {
      const last = t0;
      expect(shouldTerminateForInactivity(last, last + INACTIVITY_TIMEOUT_MS - 1)).toBe(false);
      expect(
        shouldTerminateForInactivity(last, last + INACTIVITY_TIMEOUT_MS - 1, "realtime"),
      ).toBe(false);
    });

    it("boundary: idle age === timeout + 1 ms terminates", () => {
      const last = t0;
      expect(shouldTerminateForInactivity(last, last + INACTIVITY_TIMEOUT_MS + 1)).toBe(true);
      expect(
        shouldTerminateForInactivity(last, last + INACTIVITY_TIMEOUT_MS + 1, "realtime"),
      ).toBe(true);
    });
  });

  it("ClientControlMessageSchema accepts client_ack and client_activity", () => {
    expect(ClientControlMessageSchema.safeParse({ type: "client_ack" }).success).toBe(true);
    expect(ClientControlMessageSchema.safeParse({ type: "client_activity" }).success).toBe(true);
    expect(ClientControlMessageSchema.safeParse({ type: "other" }).success).toBe(false);
  });

  it("tickActiveSession idle check is not sessionKind-gated", () => {
    const ledgerSrc = readFileSync(join(here, "../user-usage-ledger/ledger.ts"), "utf8");
    const tickStart = ledgerSrc.indexOf("private async tickActiveSession(");
    expect(tickStart).toBeGreaterThanOrEqual(0);
    const nextMethod = ledgerSrc.indexOf("\n  private async terminateSession(", tickStart);
    expect(nextMethod).toBeGreaterThan(tickStart);
    const tickBody = ledgerSrc.slice(tickStart, nextMethod);

    expect(tickBody).toMatch(/inactivity_timeout/);
    expect(tickBody).not.toMatch(/sessionKind === ["']cascade["']/);
  });

  it("tickActiveSession must not assign lastActivityAt (interval ticks are not activity)", () => {
    // Source scan: the only lastActivityAt mention inside tickActiveSession
    // must be a read for the idle check, never an assignment / .set().
    const ledgerSrc = readFileSync(join(here, "../user-usage-ledger/ledger.ts"), "utf8");
    const tickStart = ledgerSrc.indexOf("private async tickActiveSession(");
    expect(tickStart).toBeGreaterThanOrEqual(0);
    const nextMethod = ledgerSrc.indexOf("\n  private async terminateSession(", tickStart);
    expect(nextMethod).toBeGreaterThan(tickStart);
    const tickBody = ledgerSrc.slice(tickStart, nextMethod);

    expect(tickBody).toMatch(/shouldTerminateForInactivity\(row\.lastActivityAt/);
    expect(tickBody).not.toMatch(/lastActivityAt\s*:/);
    expect(tickBody).not.toMatch(/last_activity_at/);
    expect(tickBody).not.toMatch(/touchLastActivityAt|touchVoiceSessionActivity/);
  });

  it("webSocketMessage touches activity only for client_activity", () => {
    const ledgerSrc = readFileSync(join(here, "../user-usage-ledger/ledger.ts"), "utf8");
    const wsStart = ledgerSrc.indexOf("async webSocketMessage(");
    expect(wsStart).toBeGreaterThanOrEqual(0);
    const nextMethod = ledgerSrc.indexOf("\n  async webSocketClose(", wsStart);
    expect(nextMethod).toBeGreaterThan(wsStart);
    const wsBody = ledgerSrc.slice(wsStart, nextMethod);

    expect(wsBody).toMatch(/client_activity/);
    expect(wsBody).toMatch(/touchVoiceSessionActivity/);
    // client_ack must remain log-only (no touch on that branch).
    const ackBranch = wsBody.slice(wsBody.indexOf("client_ack is advisory"));
    expect(ackBranch).not.toMatch(/touchVoiceSessionActivity/);
  });
});
