import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

describe("voice audit scheduling contract", () => {
  it("schedules audit mirrors after the authoritative write and alarm", () => {
    const source = readFileSync(join(here, "ledger.ts"), "utf8");
    const createStart = source.indexOf("async createVoiceSession()");
    const registerStart = source.indexOf("async registerCallId(");
    expect(createStart).toBeGreaterThanOrEqual(0);
    expect(registerStart).toBeGreaterThan(createStart);

    const createBody = source.slice(createStart, registerStart);
    expect(createBody.indexOf("await insertVoiceSession")).toBeLessThan(
      createBody.indexOf("await this.ensureAlarmAtOrBefore"),
    );
    expect(createBody.indexOf("await this.ensureAlarmAtOrBefore")).toBeLessThan(
      createBody.indexOf('this.ctx.waitUntil(\n      this.appendAuditLog(userId, "voice_session.created"'),
    );

    const registerEnd = source.indexOf("\n  /**", registerStart + 20);
    const registerBody = source.slice(registerStart, registerEnd);
    expect(registerBody.indexOf("await markNonceUsedAndRegisterCall")).toBeLessThan(
      registerBody.indexOf("await this.ensureAlarmAtOrBefore"),
    );
    expect(registerBody.indexOf("await this.ensureAlarmAtOrBefore")).toBeLessThan(
      registerBody.indexOf('this.ctx.waitUntil(\n      this.appendAuditLog(userId, "voice_session.call_registered"'),
    );
  });
});
