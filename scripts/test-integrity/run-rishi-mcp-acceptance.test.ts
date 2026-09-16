import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decodeMCPResponseLine, MCPRequestError, runAcceptance, type JsonObject, type MCPResponse, type MCPTransport } from "./run-rishi-mcp-acceptance";
import { verifyRelease, type ReleaseManifest } from "./verify-shared-reading-release";

const sha = "a".repeat(40);
const temporaryDirectories: string[] = [];
const tools = ["list_app_instances", "memory_snapshot", "start_app", "stop_app", "inspect_app_state", "select_book", "send_reader_action", "create_reading_session", "join_reading_session", "wait_for_participant", "click_text", "capture_screenshot"];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

function response(value: unknown): MCPResponse { return { jsonrpc: "2.0", id: 1, result: { structuredContent: value } }; }
function memory(availableMemoryBytes = 8_589_934_592) {
  return {
    host: {
      pageSize: 4096,
      pages: { pages_free: 1000, pages_inactive: 1000, pages_speculative: 1000 },
      processRssKb: 10,
      availableMemoryBytes,
      configuredMinimumMemoryBytes: 1_073_741_824,
    },
    matchingProcesses: [],
  };
}
function instance(id: string) { return { id, app: id, displayName: "Rishi", isRunning: true, windows: [{ id: 1 }], owned: true, memory: memory() }; }

class FakeTransport implements MCPTransport {
  readonly calls: Array<{ method: string; params: JsonObject }> = [];
  running = new Set<string>();
  screen = "Library";
  page = 1;
  ended = false;
  rejoinCode = "SESSION_ENDED";
  malformedMemory = false;
  malformedMemoryShape = false;
  nonfiniteMemory = false;
  lowMemoryReserve = false;
  emptyMemory = false;
  malformedInstances = false;
  missingInstances = false;
  thirdInstance = false;
  malformedAfterStops = false;
  stopFailure = false;
  protocolFailure = false;
  finalListCalls = 0;
  finalMemoryCalls = 0;

  async request(method: string, params: JsonObject = {}): Promise<MCPResponse> {
    this.calls.push({ method, params });
    if (method === "initialize") return this.protocolFailure ? { result: {} } : { result: { protocolVersion: "2024-11-05" } };
    if (method === "tools/list") return { result: { tools: tools.map((name) => ({ name })) } };
    const name = params.name as string;
    const args = params.arguments as JsonObject;
    if (name === "list_app_instances") {
      if (this.running.size === 0) this.finalListCalls += 1;
      if (this.missingInstances || (this.malformedAfterStops && this.finalListCalls > 1)) return response({ status: "unknown" });
      if (this.malformedInstances) return response({ instances: [{ malformed: true }] });
      const values = [...this.running].map(instance);
      if (this.thirdInstance && values.length === 2) values.push(instance("third"));
      return response(values);
    }
    if (name === "memory_snapshot") {
      this.finalMemoryCalls += Number(this.running.size === 0);
      if (this.emptyMemory) return response({});
      if (this.malformedMemoryShape) return response({ host: { availableMemoryBytes: "8589934592", configuredMinimumMemoryBytes: 1_073_741_824 } });
      if (this.nonfiniteMemory) return response(memory(Number.NaN));
      if (this.malformedMemory) return response({ host: { availableMemoryGiB: 8, configuredMinimumMemoryGiB: 1 } });
      return response(memory(this.lowMemoryReserve ? 536_870_912 : undefined));
    }
    if (name === "start_app") { this.running.add(args.app as string); return response({ app: args.app, owned: true, memory: memory() }); }
    if (name === "stop_app") { if (this.stopFailure) throw Object.assign(new Error("stop failed"), { code: "STOP_FAILED" }); this.running.delete(args.app as string); return response({ app: args.app, stopped: true, memory: memory() }); }
    if (name === "select_book") { this.screen = args.action === "open" ? "Reader Page 1" : "Share selection"; return response({ ok: true }); }
    if (name === "send_reader_action") { if (args.action === "close") this.screen = "Library"; if (args.action === "next_page") this.page = 2; return response({ ok: true }); }
    if (name === "inspect_app_state") {
      const semanticState = {
        reader: {
          chapter: "Chapter 1",
          page: { current: this.page, total: 20 },
          progress: 0.25,
        },
      };
      return response({
        activeSession: !this.ended,
        state: {
          tree: this.ended ? "Library no active session" : this.screen,
          semantic: semanticState,
        },
        semanticState,
      });
    }
    if (name === "create_reading_session") { this.screen = "Shared reading session"; return response({ inviteToken: "secret-token", sessionId: "session-123" }); }
    if (name === "join_reading_session") {
      if (this.ended) {
        const message = this.rejoinCode === "SESSION_ENDED" ? "the shared reading session has ended" : "network operation failed";
        decodeMCPResponseLine(JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          error: { code: -32000, message, data: { code: this.rejoinCode } },
        }), 1);
        throw new Error("expected the simulated JSON-RPC error to be thrown");
      }
      return response({ participantText: "Participant Alice", sessionText: "Session session-123" });
    }
    if (name === "wait_for_participant") return response({ matched: true });
    if (name === "click_text") { if (args.text === "Leave and end for everyone") this.ended = true; return response({ ok: true }); }
    if (name === "capture_screenshot") return response({ screenshots: ["/private/tmp/screenshot.png"] });
    throw new Error(`unexpected tool ${name}`);
  }

  async notify(): Promise<void> {}
  async close(): Promise<void> {}
}

async function run(fake = new FakeTransport()) {
  const evidenceRoot = await mkdtemp(join(tmpdir(), "mcp-acceptance-test-"));
  temporaryDirectories.push(evidenceRoot);
  const result = runAcceptance({ binary: "/not-executed", owner: "catalyst", participant: "iphone17", syncTimeoutMs: 1_000, sha, evidenceRoot, bookIdentifier: "private-book-id" }, { transport: fake, sleep: async () => {} });
  return { result, evidenceRoot, fake };
}

describe("rishi MCP acceptance client", () => {
  test("preserves JSON-RPC error messages and structured tool codes", () => {
    const line = JSON.stringify({
      jsonrpc: "2.0",
      id: 7,
      error: {
        code: -32000,
        message: "the shared reading session has ended",
        data: { code: "SESSION_ENDED" },
      },
    });

    let thrown: unknown;
    try { decodeMCPResponseLine(line, 7); } catch (error) { thrown = error; }
    expect(thrown).toBeInstanceOf(MCPRequestError);
    expect(thrown).toMatchObject({
      rpcCode: -32000,
      toolCode: "SESSION_ENDED",
      message: "SESSION_ENDED: the shared reading session has ended",
    });
  });

  test("completes the protocol while recording only stable redacted evidence", async () => {
    const { result, evidenceRoot } = await run();
    await expect(result).resolves.toBeDefined();
    const evidence = await readFile(join(evidenceRoot, "shared-reading-mcp-evidence.json"), "utf8");
    for (const sensitive of ["secret-token", "Participant Alice", "session-123", "private-book-id"]) expect(evidence).not.toContain(sensitive);
    expect(evidence).toContain("<redacted>");
  });

  test("rejects malformed initialize, memory, instance, and third-instance responses", async () => {
    for (const option of ["protocolFailure", "malformedMemory", "emptyMemory", "malformedMemoryShape", "nonfiniteMemory", "missingInstances", "malformedInstances", "thirdInstance"] as const) {
      const fake = new FakeTransport(); fake[option] = true;
      const { result } = await run(fake);
      await expect(result).rejects.toThrow(/initialize|memory|instance|third/i);
    }
  });

  test("rejects memory below the Swift-configured byte floor", async () => {
    const fake = new FakeTransport(); fake.lowMemoryReserve = true;
    const { result } = await run(fake);
    await expect(result).rejects.toThrow(/memory reserve fell below the configured floor/);
  });

  test("emits the exact verifier-compatible producer schema", async () => {
    const { result, evidenceRoot } = await run();
    await expect(result).resolves.toBeDefined();
    const mcp = JSON.parse(await readFile(join(evidenceRoot, "shared-reading-mcp-evidence.json")));
    const e2e = JSON.parse(await readFile(join(evidenceRoot, "shared-reading-apple-e2e-evidence.json")));
    expect(mcp.redaction).toEqual({ version: 1, arbitraryTextStored: false });
    expect(mcp.calls[0]).toHaveProperty("label");
    expect(mcp.calls[0]).not.toHaveProperty("assertion");
    expect(mcp.contentHash).toMatch(/^[a-f0-9]{64}$/);
    expect(e2e).not.toHaveProperty("calls");
    expect(e2e.contentHash).toMatch(/^[a-f0-9]{64}$/);
  });

  test("records only redacted instance counts for labeled lifecycle checks", async () => {
    const { result, evidenceRoot } = await run();
    await expect(result).resolves.toBeDefined();
    const mcp = JSON.parse(await readFile(join(evidenceRoot, "shared-reading-mcp-evidence.json")));
    const lifecycleCalls = mcp.calls.filter((call: JsonObject) => call.tool === "list_app_instances");

    expect(lifecycleCalls.map((call: JsonObject) => [call.label, call.observedInstanceCount])).toEqual([
      ["initial-instances", 0],
      ["running-instances", 2],
      ["final-instances", 0],
    ]);
    expect(lifecycleCalls).toHaveLength(3);
    expect(lifecycleCalls.every((call: JsonObject) => call.success === true)).toBe(true);
    expect(mcp.calls.filter((call: JsonObject) => call.tool !== "list_app_instances")
      .every((call: JsonObject) => !Object.hasOwn(call, "observedInstanceCount"))).toBe(true);
    expect(lifecycleCalls.every((call: JsonObject) => !Object.hasOwn(call, "result") && !Object.hasOwn(call, "instances"))).toBe(true);
  });

  test("requires SESSION_ENDED or an explicit ended/invalid rejoin rejection", async () => {
    const fake = new FakeTransport(); fake.rejoinCode = "NETWORK_ERROR";
    const { result } = await run(fake);
    await expect(result).rejects.toThrow(/SESSION_ENDED|ended|invalid/);
  });

  test("verifies cleanup instances and memory after a scenario failure", async () => {
    const fake = new FakeTransport(); fake.rejoinCode = "NETWORK_ERROR";
    const { result } = await run(fake);
    await expect(result).rejects.toThrow();
    expect(fake.running.size).toBe(0);
    expect(fake.finalListCalls).toBeGreaterThanOrEqual(2);
    expect(fake.finalMemoryCalls).toBeGreaterThanOrEqual(2);
  });

  test("rechecks zero instances and memory when failure occurs after targets were stopped", async () => {
    const fake = new FakeTransport(); fake.malformedAfterStops = true;
    const { result } = await run(fake);
    await expect(result).rejects.toThrow(/instance|cleanup/i);
    expect(fake.finalListCalls).toBeGreaterThanOrEqual(2);
    expect(fake.finalMemoryCalls).toBeGreaterThanOrEqual(1);
  });

  test("surfaces stop failures instead of swallowing cleanup errors", async () => {
    const fake = new FakeTransport(); fake.rejoinCode = "NETWORK_ERROR"; fake.stopFailure = true;
    const { result } = await run(fake);
    await expect(result).rejects.toThrow(/cleanup|stop/i);
  });
});
