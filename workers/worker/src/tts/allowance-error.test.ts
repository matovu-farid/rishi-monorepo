import { describe, expect, it } from "vitest";
import { getInsufficientAllowancePayload } from "./allowance-error";

describe("getInsufficientAllowancePayload", () => {
  it("recognizes a trial exhaustion error serialized across the Durable Object RPC boundary", () => {
    const payload = getInsufficientAllowancePayload({
      name: "Error",
      message: "Trial credits are exhausted",
    });

    expect(payload).toEqual({
      error: "Trial credits are exhausted",
      code: "INSUFFICIENT_ALLOWANCE",
      allowance_kind: "trial",
    });
  });

  it("preserves the narration allowance kind from the serialized message", () => {
    expect(
      getInsufficientAllowancePayload({
        name: "Error",
        message: "Narration allowance is exhausted for the current billing period",
      }),
    ).toEqual({
      error: "Narration allowance is exhausted for the current billing period",
      code: "INSUFFICIENT_ALLOWANCE",
      allowance_kind: "narration",
    });
  });

  it("does not classify unrelated serialized errors as allowance exhaustion", () => {
    expect(
      getInsufficientAllowancePayload({
        name: "Error",
        message: "Upstream provider unavailable",
      }),
    ).toBeNull();
  });

  it("does not classify available credits as exhausted", () => {
    expect(
      getInsufficientAllowancePayload({
        name: "Error",
        message: "Trial credits remain available",
      }),
    ).toBeNull();
  });
});
