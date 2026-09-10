import test from "node:test";
import assert from "node:assert/strict";
import { derivedDataPath } from "../src/xctest-driver.mjs";

test("uses target-specific derived data when both Apple targets are managed", () => {
  const environment = {
    RISHI_MCP_DERIVED_DATA: "/private/tmp/shared",
    RISHI_MCP_DERIVED_DATA_CATALYST: "/private/tmp/catalyst",
    RISHI_MCP_DERIVED_DATA_IPHONE17: "/private/tmp/iphone17",
  };

  assert.equal(derivedDataPath("catalyst", { environment, temp: "/private/tmp/session" }), "/private/tmp/catalyst");
  assert.equal(derivedDataPath("iphone17", { environment, temp: "/private/tmp/session" }), "/private/tmp/iphone17");
});

test("keeps the shared derived-data setting as a backwards-compatible fallback", () => {
  assert.equal(
    derivedDataPath("catalyst", { environment: { RISHI_MCP_DERIVED_DATA: "/private/tmp/shared" }, temp: "/private/tmp/session" }),
    "/private/tmp/shared",
  );
  assert.equal(
    derivedDataPath("iphone17", { environment: {}, temp: "/private/tmp/session" }),
    "/private/tmp/session/derived",
  );
});
