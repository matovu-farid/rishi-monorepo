import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { VoiceSessionTerminalReason } from "./messages";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Contract locks for create-after-inactivity idempotency.
 *
 * After `terminateSession(..., "inactivity_timeout")`:
 * - null callId → hangupStatus=succeeded immediately
 * - create's assertNoBlockingLiveSession sees no blocking live row
 *
 * Abandoned pending_registration orphans (null callId) are still
 * force-ended on create via forceEndSession(..., "client_ended") + hangup
 * succeeded.
 *
 * Realtime with pending hangup may need one reconcileTerminalHangup on
 * create (existing behavior in assertNoBlockingLiveSession) before a new
 * session can start.
 */
describe("create idempotency after inactivity / null-callId orphan", () => {
  const inactivityReason: VoiceSessionTerminalReason = "inactivity_timeout";

  it("inactivity_timeout is a valid terminal reason", () => {
    expect(inactivityReason).toBe("inactivity_timeout");
  });

  it("terminateSession resolves hangup immediately when callId is null", () => {
    const ledgerSrc = readFileSync(join(here, "../user-usage-ledger/ledger.ts"), "utf8");
    const termStart = ledgerSrc.indexOf("private async terminateSession(");
    expect(termStart).toBeGreaterThanOrEqual(0);
    const next = ledgerSrc.indexOf("\n  private async attemptHangup(", termStart);
    const body = ledgerSrc.slice(termStart, next);
    // Pattern: if (!row.callId) { ... setHangupStatus(..., "succeeded", ...) }
    expect(body).toMatch(/if\s*\(\s*!row\.callId\s*\)/);
    expect(body).toMatch(/setHangupStatus\([\s\S]*?"succeeded"/);
  });

  it("assertNoBlockingLiveSession force-ends null-callId orphans", () => {
    const ledgerSrc = readFileSync(join(here, "../user-usage-ledger/ledger.ts"), "utf8");
    const assertStart = ledgerSrc.indexOf("private async assertNoBlockingLiveSession(");
    expect(assertStart).toBeGreaterThanOrEqual(0);
    const next = ledgerSrc.indexOf("\n  async endVoiceSession(", assertStart);
    const body = ledgerSrc.slice(assertStart, next);

    expect(body).toMatch(/!live\.callId/);
    expect(body).toMatch(/forceEndSession\(live,\s*"client_ended"\)/);
    expect(body).toMatch(/reconcileTerminalHangup/);
  });

  it("forceEndSession marks hangup succeeded for null callId (create unblocked)", () => {
    const ledgerSrc = readFileSync(join(here, "../user-usage-ledger/ledger.ts"), "utf8");
    const forceStart = ledgerSrc.indexOf("private async forceEndSession(");
    expect(forceStart).toBeGreaterThanOrEqual(0);
    const next = ledgerSrc.indexOf("\n  async registerCallId(", forceStart);
    const body = ledgerSrc.slice(
      forceStart,
      next > forceStart ? next : forceStart + 1200,
    );
    expect(body).toMatch(/if\s*\(\s*!row\.callId\s*\)/);
    expect(body).toMatch(/setHangupStatus\([\s\S]*?"succeeded"/);
  });

  /**
   * Documented contract: terminal inactivity_timeout + hangup succeeded does
   * not match findLiveVoiceSession's blocking predicate (live statuses OR
   * terminal with hangup not_started/pending). Therefore create proceeds.
   */
  it("terminal + hangup succeeded is not a blocking live session", () => {
    const sqlSrc = readFileSync(join(here, "sql.ts"), "utf8");
    const findStart = sqlSrc.indexOf("export async function findLiveVoiceSession");
    const findEnd = sqlSrc.indexOf("export async function findVoiceSessionById", findStart);
    const body = sqlSrc.slice(findStart, findEnd);
    expect(body).toMatch(/pending_registration',\s*'active'/);
    expect(body).toMatch(/hangupStatus.*not_started.*pending|not_started',\s*'pending'/);
    // Succeeded hangup is intentionally absent from the blocking set.
    expect(body).not.toMatch(/'succeeded'/);
  });
});
