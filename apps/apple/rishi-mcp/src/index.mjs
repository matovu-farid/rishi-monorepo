import readline from "node:readline";
import { memorySnapshot } from "./memory.mjs";
import { createToolHandlers } from "./app-tools.mjs";
import { InstanceRegistry } from "./instance-registry.mjs";
import { XCTestDriver } from "./xctest-driver.mjs";
import { SERVER_INFO, TOOLS, jsonRpcError, textResult, validateArgs } from "./protocol.mjs";

const driver = process.env.RISHI_MCP_FAKE === "1" ? { listApps: async () => [], launch: async () => {}, terminate: async () => {} } : new XCTestDriver();
const registry = new InstanceRegistry(driver, memorySnapshot);
const handlers = createToolHandlers({ driver, registry, memory: memorySnapshot });

async function request(message) {
  const notification = !Object.hasOwn(message, "id");
  const id = notification ? null : message.id;
  const respond = (value) => notification ? null : value;
  if (message.jsonrpc !== "2.0" || typeof message.method !== "string") return jsonRpcError(id, -32600, "invalid JSON-RPC request");
  if (message.method === "initialize") return respond({ jsonrpc: "2.0", id, result: { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: SERVER_INFO } });
  if (message.method === "notifications/initialized") return null;
  if (message.method === "ping") return respond({ jsonrpc: "2.0", id, result: {} });
  if (message.method === "tools/list") return respond({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
  if (message.method !== "tools/call") return notification ? null : jsonRpcError(id, -32601, `method not found: ${message.method}`);
  const tool = TOOLS.find((candidate) => candidate.name === message.params?.name);
  if (!tool) return notification ? null : jsonRpcError(id, -32602, `unknown tool: ${message.params?.name}`);
  try {
    validateArgs(tool, message.params?.arguments ?? {});
    return respond({ jsonrpc: "2.0", id, result: textResult(await handlers[tool.name](message.params.arguments ?? {})) });
  } catch (error) {
    return notification ? null : jsonRpcError(id, -32000, error.message, { code: error.code ?? "TOOL_FAILED", ...(error.data ?? {}) });
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const pending = new Set();
let shuttingDown = false;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await Promise.race([Promise.allSettled([...pending]), sleep(5000)]);
  await registry.cleanup();
}
input.on("line", async (line) => {
  if (!line.trim()) return;
  const task = (async () => {
    let response;
    try { response = await request(JSON.parse(line)); } catch (error) { response = jsonRpcError(null, -32700, error.message); }
    if (response) process.stdout.write(`${JSON.stringify(response)}\n`);
  })();
  pending.add(task);
  await task.finally(() => pending.delete(task));
});
input.on("close", () => { void shutdown().finally(() => process.exit(0)); });
process.on("SIGTERM", async () => { await shutdown(); process.exit(0); });
process.on("SIGINT", async () => { await shutdown(); process.exit(0); });
