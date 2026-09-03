import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(dirname(fileURLToPath(import.meta.url)));

function callServer(messages) {
  const child = spawn(process.execPath, [join(root, "src/index.mjs")], { cwd: root, env: { ...process.env, RISHI_MCP_FAKE: "1" }, stdio: ["pipe", "pipe", "pipe"] });
  const lines = [];
  child.stdout.on("data", (chunk) => lines.push(...chunk.toString().trim().split("\n").filter(Boolean).map((line) => JSON.parse(line))));
  for (const message of messages) child.stdin.write(`${JSON.stringify(message)}\n`);
  child.stdin.end();
  return once(child, "close").then(() => lines);
}

test("speaks MCP initialize, tools/list, and tools/call over stdio", async () => {
  const responses = await callServer([
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
    { jsonrpc: "2.0", method: "notifications/initialized", params: {} },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_app_instances", arguments: {} } },
  ]);
  assert.equal(responses[0].result.serverInfo.name, "rishi-apple-mcp");
  assert.ok(responses[1].result.tools.some((tool) => tool.name === "memory_snapshot"));
  assert.deepEqual(JSON.parse(responses[2].result.content[0].text), []);
});
