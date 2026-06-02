import { describe, expect, it } from "vitest";
import { BookContext, ClientMsg, CreateSessionBody, ServerMsg } from "../src/schemas";

const VALID_HASH = "a".repeat(64);

describe("ClientMsg schema", () => {
  it("accepts a valid hello", () => {
    const parsed = ClientMsg.safeParse({ v: 1, t: "hello", hasBookFile: true });
    expect(parsed.success).toBe(true);
  });
  it("rejects unknown t", () => {
    const parsed = ClientMsg.safeParse({ v: 1, t: "weird" });
    expect(parsed.success).toBe(false);
  });
  it("rejects mismatched v", () => {
    const parsed = ClientMsg.safeParse({ v: 2, t: "hello", hasBookFile: true });
    expect(parsed.success).toBe(false);
  });
  it("accepts sdp.offer with to/sdp", () => {
    const parsed = ClientMsg.safeParse({ v: 1, t: "sdp.offer", to: "u_1", sdp: "v=0..." });
    expect(parsed.success).toBe(true);
  });
});

describe("ServerMsg schema", () => {
  it("accepts welcome", () => {
    const parsed = ServerMsg.safeParse({
      v: 1, t: "welcome", you: "u_1", role: "host",
      sharerId: "u_1", reconnectToken: "rt", reservedUntil: 1234,
    });
    expect(parsed.success).toBe(true);
  });
});

describe("BookContext.contentHash (finding 253-005)", () => {
  const validBookContext = { bookId: "b", contentHash: VALID_HASH, format: "epub" as const };

  it("accepts a valid 64-char lowercase hex contentHash", () => {
    expect(BookContext.safeParse(validBookContext).success).toBe(true);
  });

  it("rejects empty contentHash", () => {
    expect(
      BookContext.safeParse({ ...validBookContext, contentHash: "" }).success
    ).toBe(false);
  });

  it("rejects non-hex contentHash (path-traversal attempt)", () => {
    expect(
      BookContext.safeParse({ ...validBookContext, contentHash: "../../../etc/passwd" }).success
    ).toBe(false);
  });

  it("rejects too-short hex (63 chars)", () => {
    expect(
      BookContext.safeParse({ ...validBookContext, contentHash: "a".repeat(63) }).success
    ).toBe(false);
  });

  it("rejects too-long hex (65 chars)", () => {
    expect(
      BookContext.safeParse({ ...validBookContext, contentHash: "a".repeat(65) }).success
    ).toBe(false);
  });

  it("rejects uppercase hex (lowercase only, strict superset of IPC)", () => {
    expect(
      BookContext.safeParse({ ...validBookContext, contentHash: "A".repeat(64) }).success
    ).toBe(false);
  });

  it("pins the wire-level regex source so a grep finds both BookContext and IPC hex64", () => {
    // Pinning the literal pattern keeps `packages/sharing-protocol/src/schemas.ts`
    // and `apps/rishi-electron/src/main/sharing/sharing.schemas.ts` greppable as
    // one pair via `grep -r '\[0-9a-f\]\{64\}'`. The IPC side uses the same
    // [0-9a-f]{64} class (with `/i` for case-insensitive); the wire side is
    // strictly tighter (lowercase only) — a strict superset of IPC's expectation.
    // why: zod v4's runtime check metadata lives on `_zod.def.checks[i]._zod.def`
    // (see zod 4.x internals; the public `.def` snapshot does not expose the
    // RegExp instance).
    const contentHash = BookContext.shape.contentHash as unknown as {
      _zod: { def: { checks: Array<{ _zod: { def: { check: string; format?: string; pattern?: RegExp } } }> } };
    };
    const checks = contentHash._zod.def.checks;
    const regexCheck = checks.find(
      (c) => c._zod.def.check === "string_format" && c._zod.def.format === "regex"
    );
    expect(regexCheck).toBeDefined();
    expect(regexCheck!._zod.def.pattern!.source).toBe("^[0-9a-f]{64}$");
  });
});

describe("CreateSessionBody.bookContext.contentHash (finding 253-005)", () => {
  it("accepts a valid bookContext", () => {
    const parsed = CreateSessionBody.safeParse({
      bookContext: { bookId: "b", contentHash: VALID_HASH, format: "epub" },
      requiresApproval: false,
    });
    expect(parsed.success).toBe(true);
  });

  it("rejects a bookContext with non-hex contentHash", () => {
    const parsed = CreateSessionBody.safeParse({
      bookContext: { bookId: "b", contentHash: "h", format: "epub" },
      requiresApproval: false,
    });
    expect(parsed.success).toBe(false);
  });
});

describe("ServerMsg.roster embeds the tightened BookContext (finding 253-005)", () => {
  const baseRoster = {
    v: 1,
    t: "roster" as const,
    participants: [],
    requiresApproval: false,
    status: "live" as const,
  };

  it("accepts roster with valid bookContext", () => {
    const parsed = ServerMsg.safeParse({
      ...baseRoster,
      bookContext: { bookId: "b", contentHash: VALID_HASH, format: "epub" },
    });
    expect(parsed.success).toBe(true);
  });

  it("rejects roster with malformed bookContext.contentHash", () => {
    const parsed = ServerMsg.safeParse({
      ...baseRoster,
      bookContext: { bookId: "b", contentHash: "h", format: "epub" },
    });
    expect(parsed.success).toBe(false);
  });
});
