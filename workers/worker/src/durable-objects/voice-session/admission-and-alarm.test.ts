import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const here = dirname(fileURLToPath(import.meta.url));

describe("voice session admission and cleanup alarm contract", () => {
  it("does not treat terminal provider cleanup as an active-session admission block", () => {
    const source = readFileSync(join(here, "sql.ts"), "utf8");
    const start = source.indexOf("export async function findLiveVoiceSession");
    const end = source.indexOf("export async function findVoiceSessionById", start);
    const body = source.slice(start, end);

    expect(body).toMatch(/status.*IN\s*\('pending_registration',\s*'active'\)/s);
    expect(body).not.toMatch(/status.*terminal.*hangupStatus/s);
  });

  it("keeps terminal provider cleanup visible to the Durable Object alarm", () => {
    const sqlSource = readFileSync(join(here, "sql.ts"), "utf8");
    const ledgerSource = readFileSync(
      join(here, "../user-usage-ledger/ledger.ts"),
      "utf8",
    );

    expect(sqlSource).toContain("findRowsNeedingAlarm");
    expect(ledgerSource).toContain("findRowsNeedingAlarm");
    expect(ledgerSource).not.toContain("const row = await findRowNeedingAlarm(this.db)");
  });

  it("serializes create and registration admission decisions", () => {
    const ledgerSource = readFileSync(
      join(here, "../user-usage-ledger/ledger.ts"),
      "utf8",
    );
    const sqlSource = readFileSync(join(here, "sql.ts"), "utf8");

    expect(ledgerSource.slice(ledgerSource.indexOf("async createVoiceSession"), ledgerSource.indexOf("private async assertNoBlockingLiveSession")))
      .toContain("this.ctx.blockConcurrencyWhile");
    expect(ledgerSource.slice(ledgerSource.indexOf("async registerCallId"), ledgerSource.indexOf("/**\n   * The single alarm")))
      .toContain("this.ctx.blockConcurrencyWhile");
    expect(sqlSource).toContain("status} = 'pending_registration'");
    expect(sqlSource).toContain("nonceUsed} = false");
  });

  it("does not start a second immediate hangup alongside the retry alarm", () => {
    const ledgerSource = readFileSync(
      join(here, "../user-usage-ledger/ledger.ts"),
      "utf8",
    );
    const forceEndStart = ledgerSource.indexOf("private async forceEndSession");
    const registerStart = ledgerSource.indexOf("async registerCallId", forceEndStart);
    const body = ledgerSource.slice(forceEndStart, registerStart);

    expect(body).toContain("ensureAlarmAtOrBefore(nextAttemptAt)");
    expect(body).not.toContain("waitUntil(\n        this.reconcileTerminalHangup");
    expect(ledgerSource).toContain("nextHangupAttemptAt");
    expect(ledgerSource).toContain("candidate.nextHangupAttemptAt <= now");
    expect(ledgerSource).toContain("const remainingRows = terminal ? await findRowsNeedingAlarm(this.db) : rows");
  });
});
