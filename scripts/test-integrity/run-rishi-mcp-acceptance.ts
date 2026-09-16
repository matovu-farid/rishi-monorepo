#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

export type JsonObject = Record<string, unknown>;
export type MCPResponse = JsonObject;
export type MCPTransport = { request: (method: string, params?: JsonObject) => Promise<MCPResponse>; notify: (method: string, params?: JsonObject) => Promise<void>; close: () => Promise<void> };
export type AcceptanceOptions = { binary: string; owner: "catalyst"; participant: "iphone17"; syncTimeoutMs: number; sha: string; evidenceRoot: string; bookIdentifier: string };
export type AcceptanceDependencies = { now?: () => Date; transport?: MCPTransport; sleep?: (milliseconds: number) => Promise<void> };

const ALLOWED_TARGETS = new Set(["catalyst", "iphone17"]);
const ALLOWED_TOOLS = new Set([
  "list_app_instances", "memory_snapshot", "start_app", "stop_app", "inspect_app_state", "select_book", "send_reader_action",
  "create_reading_session", "join_reading_session", "wait_for_participant", "click_text", "capture_screenshot",
]);
const E2E_ASSERTIONS = ["owner-create-share", "participant-join", "progress-sync", "owner-end", "rejoin-invalidation", "library-interaction"] as const;
const STABLE_EVIDENCE_STRINGS = new Set(["host", "catalyst", "iphone17", "open", "select_to_share", "close", "next_page", "Leave session", "Leave and end for everyone", "Cancel", "<redacted>", "stable"]);

type CallRecord = { timestamp: string; target: string; tool: string; arguments: JsonObject; success: boolean; label: string; observedInstanceCount?: number };
type MCPReport = { version: 1; sha: string; startedAt: string; finishedAt: string; targets: string[]; peakInstances: number; calls: CallRecord[]; cleanup: { zeroInstances: boolean; memoryChecked: boolean }; redaction: { version: 1; arbitraryTextStored: false } };
type E2EReport = { version: 1; sha: string; startedAt: string; finishedAt: string; targets: string[]; failed: number; assertions: Array<{ id: string; passed: boolean }> };

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function isRecord(value: unknown): value is JsonObject { return Boolean(value && typeof value === "object" && !Array.isArray(value)); }
function errorMessage(error: unknown): string { return error instanceof Error ? error.message : "MCP acceptance failed"; }

function redact(value: unknown, secrets: readonly string[] = []): unknown {
  if (Array.isArray(value)) return value.map((item) => redact(item, secrets));
  if (isRecord(value)) {
    const result: JsonObject = {};
    for (const [key, item] of Object.entries(value)) {
      if (/(token|secret|password|authorization|bearer|credential|invite)/i.test(key)) result[key] = "<redacted>";
      else result[key] = redact(item, secrets);
    }
    return result;
  }
  if (typeof value === "string") {
    const redacted = secrets.filter(Boolean).reduce((text, secret) => text.split(secret).join("<redacted>"), value);
    return STABLE_EVIDENCE_STRINGS.has(redacted) ? redacted : "<redacted>";
  }
  return value;
}

function redactArguments(value: JsonObject, secrets: readonly string[]): JsonObject { return redact(value, secrets) as JsonObject; }

async function writeAtomic(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${path.split("/").at(-1)}.${crypto.randomUUID()}.tmp`);
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

function findStructured(response: MCPResponse): unknown {
  const result = response.result;
  if (!isRecord(result)) throw new Error("MCP response has no result");
  if (result.structuredContent !== undefined) return result.structuredContent;
  const content = result.content;
  if (Array.isArray(content)) {
    const text = content.find((item) => isRecord(item) && item.type === "text" && typeof item.text === "string") as JsonObject | undefined;
    if (text) { try { return JSON.parse(text.text as string); } catch { return text.text; } }
  }
  return result;
}

function throwIfToolError(response: MCPResponse): void {
  if (isRecord(response.result) && response.result.isError === true) throw new Error("MCP tool returned an error result");
}

function walkStrings(value: unknown, output: string[] = []): string[] {
  if (typeof value === "string") output.push(value);
  else if (Array.isArray(value)) for (const item of value) walkStrings(item, output);
  else if (isRecord(value)) for (const item of Object.values(value)) walkStrings(item, output);
  return output;
}

function visibleText(value: unknown): string { return walkStrings(value).filter((item) => item.length > 0).join(" "); }

function findStringByKey(value: unknown, pattern: RegExp): string | undefined {
  if (Array.isArray(value)) { for (const item of value) { const found = findStringByKey(item, pattern); if (found) return found; } return undefined; }
  if (!isRecord(value)) return undefined;
  for (const [key, item] of Object.entries(value)) {
    if (pattern.test(key) && typeof item === "string" && item.length > 0) return item;
    const found = findStringByKey(item, pattern);
    if (found) return found;
  }
  return undefined;
}

function instanceList(value: unknown): unknown[] {
  let instances: unknown[] | undefined;
  if (Array.isArray(value)) instances = value;
  if (isRecord(value)) {
    for (const key of ["instances", "apps", "runningInstances"]) if (Array.isArray(value[key])) instances = value[key] as unknown[];
  }
  if (!instances) throw new Error("malformed app instance response");
  for (const instance of instances) if (!isRecord(instance) || !instanceTarget(instance)) throw new Error("malformed app instance entry");
  return instances;
}

function instanceTarget(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined;
  for (const key of ["app", "target", "name"]) if (typeof value[key] === "string" && ALLOWED_TARGETS.has(value[key] as string)) return value[key] as string;
  return undefined;
}

function progressFingerprint(value: unknown): string {
  const object = isRecord(value) ? value : {};
  const semantic = isRecord(object.semanticState) ? object.semanticState
    : isRecord(object.state) && isRecord(object.state.semantic) ? object.state.semantic
    : undefined;
  const reader = semantic && isRecord(semantic.reader) ? semantic.reader : undefined;
  if (!reader) throw new Error("structured reader progress is missing");
  const page = isRecord(reader.page) ? reader.page : undefined;
  const current = page?.current;
  const total = page?.total;
  if (!Number.isSafeInteger(current) || !Number.isSafeInteger(total) || (current as number) < 0 || (total as number) <= 0) throw new Error("structured reader page is malformed");
  if (typeof reader.progress !== "number" || !Number.isFinite(reader.progress)) throw new Error("structured reader progress is malformed");
  return stableJson({ chapter: typeof reader.chapter === "string" ? reader.chapter : "", page: { current, total }, progress: reader.progress });
}

function hasActiveSession(value: unknown): boolean {
  if (isRecord(value)) {
    if (value.activeSession === true || value.sessionActive === true) return true;
    if (value.activeSession === false || value.sessionActive === false) return false;
  }
  const text = visibleText(value);
  return /leave session|end for everyone|shared reading session|participant/i.test(text) && !/no active session|library/i.test(text);
}

function assertMemory(value: unknown): void {
  if (!isRecord(value) || !isRecord(value.host)) throw new Error("malformed memory snapshot");
  const available = value.host.availableMemoryBytes;
  const minimum = value.host.configuredMinimumMemoryBytes;
  if (!Number.isSafeInteger(available) || !Number.isSafeInteger(minimum) || (available as number) < 0 || (minimum as number) <= 0) throw new Error("malformed memory snapshot");
  if ((available as number) < (minimum as number)) throw new Error("memory reserve fell below the configured floor");
}

export class MCPRequestError extends Error {
  constructor(public readonly rpcCode: number | string, public readonly toolCode: string | undefined, message: string) { super(toolCode ? `${toolCode}: ${message}` : message); }
}

export function decodeMCPResponseLine(line: string, expectedID: number): MCPResponse | undefined {
  let response: unknown;
  try { response = JSON.parse(line); } catch { throw new Error("malformed MCP JSON-RPC response"); }
  if (!isRecord(response) || response.id !== expectedID) return undefined;
  if (response.error) {
    if (!isRecord(response.error)) throw new Error("malformed MCP JSON-RPC error");
    const data = isRecord(response.error.data) ? response.error.data : undefined;
    const message = typeof response.error.message === "string" ? response.error.message : "MCP request failed";
    const rpcCode = typeof response.error.code === "number" || typeof response.error.code === "string" ? response.error.code : "error";
    const toolCode = typeof data?.code === "string" ? data.code : undefined;
    throw new MCPRequestError(rpcCode, toolCode, message);
  }
  return response;
}

function ensureNoMoreThanTwo(value: unknown): number {
  const count = instanceList(value).length;
  if (count > 2) throw new Error("MCP acceptance detected a third app instance");
  return count;
}

class StdioMCPClient implements MCPTransport {
  private id = 0;
  private buffer = "";
  private readonly reader: ReadableStreamDefaultReader<Uint8Array>;
  private readonly child: ReturnType<typeof Bun.spawn>;

  constructor(binary: string) {
    this.child = Bun.spawn([binary], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    this.reader = (this.child.stdout as ReadableStream<Uint8Array>).getReader();
    void this.drainStderr();
  }

  private async drainStderr(): Promise<void> {
    const reader = (this.child.stderr as ReadableStream<Uint8Array>).getReader();
    try { while (!(await reader.read()).done) { /* discard diagnostics; never expose secrets */ } } finally { reader.releaseLock(); }
  }

  private async line(): Promise<string> {
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline >= 0) { const result = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1); return result; }
      const chunk = await this.reader.read();
      if (chunk.done) throw new Error("MCP server closed stdout before its response");
      this.buffer += new TextDecoder().decode(chunk.value, { stream: true });
      if (this.buffer.length > 8 * 1024 * 1024) throw new Error("MCP response exceeded the bounded size");
    }
  }

  async request(method: string, params: JsonObject = {}): Promise<MCPResponse> {
    const id = ++this.id;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    this.child.stdin.write(`${payload}\n`);
    await this.child.stdin.flush();
    for (;;) {
      const response = decodeMCPResponseLine(await this.line(), id);
      if (!response) continue;
      return response;
    }
  }

  async notify(method: string, params: JsonObject = {}): Promise<void> {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
    await this.child.stdin.flush();
  }

  async close(): Promise<void> {
    try { this.child.stdin.end(); } catch { /* already closed */ }
    await this.child.exited;
    this.reader.releaseLock();
  }
}

async function ensureTools(client: MCPTransport): Promise<void> {
  const response = await client.request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "rishi-shared-reading-acceptance", version: "1" } });
  if (!isRecord(response.result) || typeof response.result.protocolVersion !== "string") throw new Error("MCP initialize response is incomplete");
  await client.notify("notifications/initialized");
  const listed = findStructured(await client.request("tools/list"));
  if (!isRecord(listed) || !Array.isArray(listed.tools)) throw new Error("MCP tools/list response is malformed");
  const names = new Set(listed.tools.filter(isRecord).map((tool) => tool.name).filter((name): name is string => typeof name === "string"));
  for (const tool of ALLOWED_TOOLS) if (!names.has(tool)) throw new Error(`MCP server does not expose required tool: ${tool}`);
}

export async function runAcceptance(options: AcceptanceOptions, dependencies: AcceptanceDependencies = {}): Promise<{ mcp: MCPReport; e2e: E2EReport }> {
  if (options.owner !== "catalyst" || options.participant !== "iphone17") throw new Error("acceptance requires exactly the catalyst and iphone17 targets");
  if (!ALLOWED_TARGETS.has(options.owner) || !ALLOWED_TARGETS.has(options.participant)) throw new Error("acceptance target is not declared");
  if (!/^[a-f0-9]{40}$/.test(options.sha)) throw new Error("acceptance requires a full commit SHA");
  if (!Number.isInteger(options.syncTimeoutMs) || options.syncTimeoutMs < 100 || options.syncTimeoutMs > 120_000) throw new Error("sync timeout is outside the declared bounds");
  if (!options.bookIdentifier) throw new Error("acceptance requires a book identifier");
  const now = dependencies.now ?? (() => new Date());
  const sleep = dependencies.sleep ?? ((milliseconds: number) => Bun.sleep(milliseconds));
  const client = dependencies.transport ?? new StdioMCPClient(options.binary);
  const startedAt = now().toISOString();
  const calls: CallRecord[] = [];
  const secrets: string[] = [];
  const startedTargets = new Set<string>();
  let peakInstances = 0;
  const record = (target: string, tool: string, args: JsonObject, success: boolean, assertionId: string, observedInstanceCount?: number) => {
    calls.push({ timestamp: now().toISOString(), target: target || "host", tool, arguments: redactArguments(args, secrets), success, label: assertionId, ...(observedInstanceCount === undefined ? {} : { observedInstanceCount }) });
  };
  const call = async (target: string, tool: string, args: JsonObject, assertionId: string): Promise<unknown> => {
    if (!ALLOWED_TOOLS.has(tool)) throw new Error(`undeclared MCP tool: ${tool}`);
    if (target && !ALLOWED_TARGETS.has(target)) throw new Error(`undeclared MCP target: ${target}`);
    try {
      const response = await client.request("tools/call", { name: tool, arguments: args });
      throwIfToolError(response);
      const value = findStructured(response);
      const observedInstanceCount = tool === "list_app_instances" ? ensureNoMoreThanTwo(value) : undefined;
      if (observedInstanceCount !== undefined) peakInstances = Math.max(peakInstances, observedInstanceCount);
      if (tool === "memory_snapshot") assertMemory(value);
      record(target, tool, args, true, assertionId, observedInstanceCount);
      return value;
    } catch (error) {
      record(target, tool, args, false, assertionId);
      throw error;
    }
  };
  const expectedFailure = async (target: string, tool: string, args: JsonObject, assertionId: string): Promise<void> => {
    try {
      const response = await client.request("tools/call", { name: tool, arguments: args });
      throwIfToolError(response);
    }
    catch (error) {
      const message = errorMessage(error);
      if (!/SESSION_ENDED|ended|invalid/i.test(message)) {
        record(target, tool, args, false, assertionId);
        throw new Error(`invalid rejoin rejection: ${message}`);
      }
      record(target, tool, args, true, assertionId);
      return;
    }
    record(target, tool, args, false, assertionId);
    throw new Error("ended session was accepted");
  };
  const inspect = async (target: string, assertionId: string): Promise<unknown> => call(target, "inspect_app_state", { app: target }, assertionId);
  const reports = (finishedAt: string, cleanup: { zeroInstances: boolean; memoryChecked: boolean }): { mcp: MCPReport; e2e: E2EReport } => {
    const assertions = E2E_ASSERTIONS.map((id) => ({ id, passed: calls.filter((call_) => call_.label === id).every((call_) => call_.success) && calls.some((call_) => call_.label === id) }));
    const mcp: MCPReport = { version: 1, sha: options.sha, startedAt, finishedAt, targets: [options.owner, options.participant], peakInstances, calls: calls.map((call_) => ({ ...call_, arguments: redactArguments(call_.arguments, secrets) })), cleanup, redaction: { version: 1, arbitraryTextStored: false } };
    const e2e: E2EReport = { version: 1, sha: options.sha, startedAt, finishedAt, targets: [options.owner, options.participant], failed: assertions.filter((assertion) => !assertion.passed).length, assertions };
    return { mcp, e2e };
  };

  try {
    await ensureTools(client);
    const initialInstances = await call("", "list_app_instances", {}, "initial-instances");
    if (instanceList(initialInstances).length !== 0) throw new Error("acceptance requires no pre-existing app instances");
    const initialMemory = await call("", "memory_snapshot", {}, "library-interaction");
    assertMemory(initialMemory);
    await call(options.owner, "start_app", { app: options.owner }, "owner-create-share"); startedTargets.add(options.owner);
    await call(options.participant, "start_app", { app: options.participant }, "participant-join"); startedTargets.add(options.participant);
    await call("", "memory_snapshot", {}, "participant-join");
    const running = await call("", "list_app_instances", {}, "running-instances");
    if (instanceList(running).length !== 2 || new Set(instanceList(running).map(instanceTarget).filter(Boolean)).size !== 2) throw new Error("acceptance did not reach exactly two declared targets");
    const ownerInitial = await inspect(options.owner, "owner-create-share");
    await inspect(options.participant, "participant-join");
    const ownerBook = { app: options.owner, identifier: options.bookIdentifier, action: "open" };
    await call(options.owner, "select_book", ownerBook, "library-interaction");
    const readerState = await inspect(options.owner, "library-interaction");
    if (!/reader|close|page|chapter/i.test(visibleText(readerState))) throw new Error("owner reader was not visibly opened");
    await call(options.owner, "send_reader_action", { app: options.owner, action: "close" }, "library-interaction");
    const libraryState = await inspect(options.owner, "library-interaction");
    if (/reader|close|chapter|page/i.test(visibleText(libraryState)) && !/library/i.test(visibleText(libraryState))) throw new Error("owner library was not visible after close");
    await call(options.owner, "select_book", { ...ownerBook, action: "select_to_share" }, "owner-create-share");
    const shareState = await inspect(options.owner, "owner-create-share");
    if (!/share|select|start reading|reading/i.test(visibleText(shareState))) throw new Error("selection/share UI was not visible");
    await call(options.owner, "click_text", { app: options.owner, text: "Cancel" }, "owner-create-share");
    const created = await call(options.owner, "create_reading_session", { app: options.owner, bookIdentifier: options.bookIdentifier }, "owner-create-share");
    const token = findStringByKey(created, /^(inviteToken|token)$/i) ?? visibleText(created).match(/(?:token["=: ]+|token=)([A-Za-z0-9._~%+-]+)/i)?.[1];
    if (!token) throw new Error("create_reading_session did not return an invite token");
    secrets.push(token);
    const joined = await call(options.participant, "join_reading_session", { app: options.participant, token }, "participant-join");
    const participantText = visibleText(joined).replace(token, "").trim() || visibleText(await inspect(options.participant, "participant-join"));
    if (!participantText) throw new Error("join did not expose participant/session text");
    await call(options.owner, "wait_for_participant", { app: options.owner, text: participantText, timeoutMs: options.syncTimeoutMs }, "participant-join");
    await call(options.participant, "wait_for_participant", { app: options.participant, text: participantText, timeoutMs: options.syncTimeoutMs }, "participant-join");
    await call("", "memory_snapshot", {}, "participant-join");
    const beforeOwner = await inspect(options.owner, "progress-sync");
    const beforeParticipant = await inspect(options.participant, "progress-sync");
    const beforeProgress = progressFingerprint(beforeOwner);
    await call(options.owner, "send_reader_action", { app: options.owner, action: "next_page" }, "progress-sync");
    const deadline = Date.now() + options.syncTimeoutMs;
    let afterOwner: unknown = beforeOwner;
    let afterParticipant: unknown = beforeParticipant;
    while (Date.now() <= deadline) {
      afterOwner = await inspect(options.owner, "progress-sync");
      afterParticipant = await inspect(options.participant, "progress-sync");
      if (progressFingerprint(afterOwner) !== beforeProgress && progressFingerprint(afterOwner) === progressFingerprint(afterParticipant)) break;
      await sleep(250);
    }
    if (progressFingerprint(afterOwner) === beforeProgress || progressFingerprint(afterOwner) !== progressFingerprint(afterParticipant)) throw new Error("visible reader progress did not synchronize");
    await call("", "memory_snapshot", {}, "progress-sync");
    await call(options.owner, "click_text", { app: options.owner, text: "Leave session" }, "owner-end");
    await call(options.owner, "click_text", { app: options.owner, text: "Leave and end for everyone" }, "owner-end");
    const endDeadline = Date.now() + options.syncTimeoutMs;
    while (Date.now() <= endDeadline) {
      const ownerEnd = await inspect(options.owner, "owner-end");
      const participantEnd = await inspect(options.participant, "owner-end");
      if (!hasActiveSession(ownerEnd) && !hasActiveSession(participantEnd)) break;
      await sleep(250);
    }
    if (hasActiveSession(await inspect(options.owner, "owner-end")) || hasActiveSession(await inspect(options.participant, "owner-end"))) throw new Error("active session remained after owner end");
    await call("", "memory_snapshot", {}, "owner-end");
    await expectedFailure(options.participant, "join_reading_session", { app: options.participant, token }, "rejoin-invalidation");
    await call(options.owner, "capture_screenshot", { app: options.owner }, "library-interaction");
    await call(options.owner, "stop_app", { app: options.owner }, "owner-end"); startedTargets.delete(options.owner);
    await call(options.participant, "stop_app", { app: options.participant }, "owner-end"); startedTargets.delete(options.participant);
    const finalInstances = await call("", "list_app_instances", {}, "final-instances");
    const finalMemory = await call("", "memory_snapshot", {}, "owner-end");
    if (instanceList(finalInstances).length !== 0) throw new Error("server-owned app instances remained after cleanup");
    assertMemory(finalMemory);
    const { mcp, e2e } = reports(now().toISOString(), { zeroInstances: true, memoryChecked: true });
    if (e2e.failed !== 0) throw new Error("MCP acceptance assertions failed");
    await writeAtomic(resolve(options.evidenceRoot, "shared-reading-mcp-evidence.json"), { ...mcp, contentHash: createHash("sha256").update(stableJson(mcp)).digest("hex") });
    await writeAtomic(resolve(options.evidenceRoot, "shared-reading-apple-e2e-evidence.json"), { ...e2e, contentHash: createHash("sha256").update(stableJson(e2e)).digest("hex") });
    return { mcp, e2e };
  } catch (error) {
    const cleanupErrors: string[] = [];
    for (const target of [...startedTargets].reverse()) {
      try { await call(target, "stop_app", { app: target }, "owner-end"); }
      catch (cleanupError) { cleanupErrors.push(errorMessage(cleanupError)); }
    }
    try {
      const finalInstances = await call("", "list_app_instances", {}, "final-instances");
      if (instanceList(finalInstances).length !== 0) throw new Error("cleanup left app instances running");
      const finalMemory = await call("", "memory_snapshot", {}, "owner-end");
      assertMemory(finalMemory);
    } catch (cleanupError) { cleanupErrors.push(errorMessage(cleanupError)); }
    if (cleanupErrors.length) throw new Error(`${errorMessage(error)}; cleanup failed: ${cleanupErrors.join("; ")}`);
    throw error;
  } finally { await client.close(); }
}

function parseCli(arguments_: string[]): AcceptanceOptions {
  const values = new Map<string, string>();
  for (let index = 0; index < arguments_.length; index += 1) {
    const flag = arguments_[index];
    const value = arguments_[++index];
    if (!flag?.startsWith("--") || !value || value.startsWith("--")) throw new Error("usage: run-rishi-mcp-acceptance.ts --mcp-binary PATH --owner catalyst --participant iphone17 --sync-timeout-ms N --sha SHA --evidence-root PATH --book-identifier ID");
    values.set(flag.slice(2), value);
  }
  return { binary: values.get("mcp-binary") ?? "", owner: values.get("owner") as "catalyst", participant: values.get("participant") as "iphone17", syncTimeoutMs: Number(values.get("sync-timeout-ms") ?? ""), sha: values.get("sha") ?? "", evidenceRoot: values.get("evidence-root") ?? "", bookIdentifier: values.get("book-identifier") ?? process.env.RISHI_E2E_BOOK_IDENTIFIER ?? "fixture" };
}

if (import.meta.main) {
  try { const options = parseCli(process.argv.slice(2)); await runAcceptance(options); console.log("shared-reading MCP acceptance passed"); }
  catch (error) { console.error(errorMessage(error)); process.exitCode = 1; }
}
