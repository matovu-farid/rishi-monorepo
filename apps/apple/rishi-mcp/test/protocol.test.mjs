import test from "node:test";
import assert from "node:assert/strict";
import { SERVER_INFO, TOOLS, validateArgs } from "../src/protocol.mjs";

test("publishes the semantic Apple testing tools", () => {
  assert.equal(SERVER_INFO.name, "rishi-apple-mcp");
  assert.ok(TOOLS.some((tool) => tool.name === "inspect_app_state"));
  assert.ok(TOOLS.some((tool) => tool.name === "create_reading_session"));
});

test("rejects missing and unknown tool arguments before acting", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "start_app");
  assert.throws(() => validateArgs(tool, {}), /missing required argument/);
  assert.throws(() => validateArgs(tool, { app: "catalyst", extra: true }), /unknown argument/);
});
