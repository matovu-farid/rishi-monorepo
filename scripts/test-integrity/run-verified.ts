#!/usr/bin/env bun
import { closeSync, constants, createReadStream, fchmodSync, fstatSync, fsyncSync, ftruncateSync, writeSync } from "node:fs";
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { dlopen, FFIType } from "bun:ffi";
import { createHash } from "node:crypto";
import { basename, dirname, join, parse, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
import { collectResourceSample, validateResourceSample, type ResourceSample } from "./resource-preflight";

type Format = "vitest-json" | "node-test" | "swift-output" | "xcresult" | "codex-jsonl" | "command";
type Evidence = { discovered?: number; passed?: number; skipped?: number; failed?: number; failedIds?: string[] };
type ProcessIdentity = { pid: number; processGroupId: number; sessionId: number; startTime: string; executable: string };
type Options = {
  format: Format;
  artifact: string;
  command: string[];
  expectedRed: boolean;
  expectedExit: number;
  failureIds: string[];
  rawOutput?: string;
  resourceArtifact?: string;
  expectedResourceTarget?: string;
  minAvailableMemoryGiB?: number;
  minFreeDiskGiB?: number;
  ownedOutputRoot?: string;
  xcresult?: string;
  resourceResample?: ResourceSample;
  allowedServers: string[];
  requiredTools: string[];
  requireRejection?: string;
  cwd: string;
};
type ProcessRecord = {
  command: string;
  args: string[];
  cwd: string;
  startedAt: string;
  finishedAt: string;
  exitCode: number;
  child: {
    pid: number;
    processGroupId: number;
    sessionId: number;
    containment: "posix-session";
    startedAt: string;
    descendantPids: number[];
    descendants: ProcessIdentity[];
    remainingDescendants: ProcessIdentity[];
    remainingAfterCleanup: ProcessIdentity[];
    cleanupSignals: Array<{ signal: NodeJS.Signals; processGroupIds: number[] }>;
    samplingIntervalMs: number;
  };
};
type Artifact = ProcessRecord & {
  version: 1;
  format: Format;
  evidence?: Evidence;
  ownedOutputRoot?: string;
  rawOutput?: string;
  xcresult?: string;
  commands: ProcessRecord[];
};

const FORMATS = new Set<Format>(["vitest-json", "node-test", "swift-output", "xcresult", "codex-jsonl", "command"]);
const FILESYSTEM_TIMESTAMP_TOLERANCE_MS = 1_000;
const DESCENDANT_SAMPLE_INTERVAL_MS = 100;
const PROCESS_IDENTITY_COUNT_LIMIT = 10_000;
const PROCESS_IDENTITY_BYTE_LIMIT = 4 * 1024 * 1024;
const PROCESS_GROUP_TERM_GRACE_MS = 500;
const PROCESS_GROUP_KILL_GRACE_MS = 2_000;
const PROCESS_GROUP_POLL_INTERVAL_MS = 25;
const PROCESS_SNAPSHOT_RETRY_LIMIT = 3;
const OUTPUT_STREAM_LIMIT_BYTES = 32 * 1024 * 1024;
const OUTPUT_SHUTDOWN_GRACE_MS = 500;
const XCRESULT_FILE_LIMIT_BYTES = 128 * 1024 * 1024;
const XCRESULT_TREE_LIMIT_BYTES = 1024 * 1024 * 1024;
const XCRESULT_ENTRY_LIMIT = 100_000;

export function resolveOutputStreamLimit(raw = process.env.RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES): number {
  if (raw === undefined) return OUTPUT_STREAM_LIMIT_BYTES;
  if (!/^[1-9][0-9]*$/.test(raw)) throw new Error("RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES must be a strict positive integer");
  const requested = Number(raw);
  if (!Number.isSafeInteger(requested)) throw new Error("RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES must be a strict positive integer");
  return Math.min(requested, OUTPUT_STREAM_LIMIT_BYTES);
}

function usage(): never {
  throw new Error("usage: run-verified.ts [FORMAT | --format FORMAT] --expect pass|fail --artifact PATH [--cwd PATH] [options] -- COMMAND [ARGS...]");
}

function takeValue(arguments_: string[], index: number, flag: string): string {
  const value = arguments_[index + 1];
  if (value === undefined || value === "--") throw new Error(`${flag} requires a value`);
  return value;
}

function parseOptions(arguments_: string[]): Options {
  const separator = arguments_.indexOf("--");
  if (separator < 0 || separator === arguments_.length - 1) usage();
  const positionalFormat = FORMATS.has(arguments_[0] as Format) ? arguments_[0] as Format : undefined;
  const values = arguments_.slice(positionalFormat ? 1 : 0, separator);
  let format = positionalFormat;
  let artifact: string | undefined;
  let rawOutput: string | undefined;
  let resourceArtifact: string | undefined;
  let ownedOutputRoot: string | undefined;
  let xcresult: string | undefined;
  let expectedResourceTarget: string | undefined;
  let minAvailableMemoryGiB: number | undefined;
  let minFreeDiskGiB: number | undefined;
  let expectedRed = false;
  let expectedExit = 0;
  let requireRejection: string | undefined;
  let cwd = process.cwd();
  let expectedOutcome: "pass" | "fail" | undefined;
  const failureIds: string[] = [];
  const allowedServers: string[] = [];
  const requiredTools: string[] = [];
  for (let index = 0; index < values.length; index += 1) {
    const flag = values[index];
    switch (flag) {
      case "--format": {
        const value = takeValue(values, index++, flag) as Format;
        if (!FORMATS.has(value) || format) throw new Error("--format must name exactly one supported format");
        format = value;
        break;
      }
      case "--expect": {
        const value = takeValue(values, index++, flag);
        if (value !== "pass" && value !== "fail") throw new Error("--expect must be pass or fail");
        expectedOutcome = value;
        break;
      }
      case "--cwd": cwd = resolve(takeValue(values, index++, flag)); break;
      case "--artifact": artifact = takeValue(values, index++, flag); break;
      case "--raw-output": rawOutput = takeValue(values, index++, flag); break;
      case "--resource-artifact": resourceArtifact = takeValue(values, index++, flag); break;
      case "--expected-resource-target": expectedResourceTarget = takeValue(values, index++, flag); break;
      case "--min-available-memory-gib": minAvailableMemoryGiB = Number(takeValue(values, index++, flag)); break;
      case "--min-free-disk-gib": minFreeDiskGiB = Number(takeValue(values, index++, flag)); break;
      case "--owned-output-root": ownedOutputRoot = takeValue(values, index++, flag); break;
      case "--xcresult": xcresult = takeValue(values, index++, flag); break;
      case "--require-failure-id": failureIds.push(takeValue(values, index++, flag)); break;
      case "--allow-server": allowedServers.push(takeValue(values, index++, flag)); break;
      case "--require-tool": requiredTools.push(takeValue(values, index++, flag)); break;
      case "--expected-exit": {
        const value = Number(takeValue(values, index++, flag));
        if (!Number.isInteger(value) || value < 0 || value > 255) throw new Error("--expected-exit must be an exit code");
        expectedExit = value;
        break;
      }
      case "--expected-red": expectedRed = true; break;
      case "--require-rejection": requireRejection = takeValue(values, index++, flag); break;
      default: throw new Error(`unknown option: ${flag}`);
    }
  }
  if (!format) usage();
  if (!positionalFormat && !expectedOutcome) throw new Error("--format requires --expect pass or fail");
  if (expectedOutcome && expectedRed) throw new Error("use either --expect fail or --expected-red, not both");
  if (expectedOutcome === "fail") expectedRed = true;
  if (!artifact) usage();
  if (format === "codex-jsonl" && !rawOutput) throw new Error("codex-jsonl requires --raw-output");
  if (format !== "codex-jsonl" && (rawOutput || allowedServers.length || requiredTools.length || requireRejection)) throw new Error("Codex options require codex-jsonl");
  if (format === "xcresult" && !xcresult) throw new Error("xcresult requires --xcresult PATH");
  if (format !== "xcresult" && xcresult) throw new Error("--xcresult requires xcresult format");
  if (format === "command" && failureIds.length) throw new Error("command format cannot verify failure IDs");
  if (resourceArtifact) {
    if (!expectedResourceTarget || !Number.isFinite(minAvailableMemoryGiB) || minAvailableMemoryGiB < 0 || !Number.isFinite(minFreeDiskGiB) || minFreeDiskGiB < 0) throw new Error("--resource-artifact requires --expected-resource-target, --min-available-memory-gib, and --min-free-disk-gib");
  } else if (expectedResourceTarget || minAvailableMemoryGiB !== undefined || minFreeDiskGiB !== undefined) throw new Error("resource expectations require --resource-artifact");
  return { format, artifact, command: arguments_.slice(separator + 1), expectedRed, expectedExit, failureIds, rawOutput, resourceArtifact, expectedResourceTarget, minAvailableMemoryGiB, minFreeDiskGiB, ownedOutputRoot, xcresult, allowedServers, requiredTools, requireRejection, cwd };
}

function parseJson(text: string, label: string): unknown {
  try { return JSON.parse(text); } catch { throw new Error(`malformed ${label}`); }
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function asCount(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
}

export function validateEvidence(evidence: Evidence, expectedRed: boolean, failureIds: string[]): void {
  const { discovered, passed, skipped, failed } = evidence;
  if (![discovered, passed, skipped, failed].every((count) => Number.isSafeInteger(count) && count! >= 0)) throw new Error("malformed test evidence counts");
  if (discovered === 0) throw new Error("evidence discovered=0 or missing");
  if (skipped !== 0) throw new Error("evidence contains skipped tests");
  if (passed + failed + skipped !== discovered) throw new Error("malformed test evidence counts");
  if (expectedRed) {
    if (failed === 0) throw new Error("expected-red requires a failed assertion");
    const ids = new Set(evidence.failedIds ?? []);
    for (const id of failureIds) if (!ids.has(id)) throw new Error(`required failing test ID not found: ${id}`);
  } else if (failed !== 0) throw new Error("test evidence reports failures");
}

function extractAssertions(value: unknown): Array<Record<string, unknown>> {
  if (!value || typeof value !== "object") return [];
  const object = value as Record<string, unknown>;
  const result: Array<Record<string, unknown>> = [];
  if (Array.isArray(object.assertionResults)) for (const assertion of object.assertionResults) if (assertion && typeof assertion === "object") result.push(assertion as Record<string, unknown>);
  for (const child of Object.values(object)) if (Array.isArray(child)) for (const item of child) result.push(...extractAssertions(item));
  return result;
}

export function parseVitestJson(text: string): Evidence {
  const report = parseJson(text, "Vitest JSON") as Record<string, unknown>;
  const discovered = asCount(report.numTotalTests);
  const passed = asCount(report.numPassedTests);
  const pending = asCount(report.numPendingTests);
  const todo = asCount(report.numTodoTests) ?? 0;
  const skipped = pending === undefined ? undefined : pending + todo;
  const failed = asCount(report.numFailedTests);
  if ([discovered, passed, skipped, failed].some((count) => count === undefined)) throw new Error("malformed Vitest JSON counts");
  const failedIds = extractAssertions(report).filter((assertion) => assertion.status === "failed").map((assertion) => String(assertion.fullName ?? assertion.title ?? "")).filter(Boolean);
  return { discovered, passed, skipped, failed, failedIds };
}

export function parseNodeTap(text: string): Evidence {
  const discovered = Number(text.match(/^# tests\s+(\d+)\s*$/m)?.[1]);
  const passed = Number(text.match(/^# pass\s+(\d+)\s*$/m)?.[1]);
  const skipped = Number(text.match(/^# skipped\s+(\d+)\s*$/m)?.[1] ?? "0");
  const failed = Number(text.match(/^# fail\s+(\d+)\s*$/m)?.[1]);
  if (![discovered, passed, skipped, failed].every(Number.isInteger) || !/^1\.\.\d+\s*$/m.test(text)) throw new Error("malformed Node TAP output");
  const failedIds = [...text.matchAll(/^not ok\s+\d+\s+-\s+(.+)$/gm)].map((match) => match[1].replace(/\s+#.*$/, "").trim());
  return { discovered, passed, skipped, failed, failedIds };
}

export function parseSwiftOutput(text: string): Evidence {
  const summary = text.match(/Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?/i) ?? text.match(/Test run with\s+(\d+)\s+tests?\s+passed/i);
  if (!summary) throw new Error("malformed Swift test output");
  const discovered = Number(summary[1]);
  const failed = summary.length > 2 && summary[2] !== undefined ? Number(summary[2]) : 0;
  const skippedMatches = text.match(/(\d+)\s+tests?\s+skipped/i);
  const skipped = skippedMatches ? Number(skippedMatches[1]) : /\bskipped\b/i.test(text) ? 1 : 0;
  if (!Number.isInteger(discovered) || !Number.isInteger(failed) || !Number.isInteger(skipped)) throw new Error("malformed Swift test summary");
  const passed = discovered - failed - skipped;
  if (passed < 0) throw new Error("malformed Swift test summary");
  const failedIds = [
    ...text.matchAll(/Test Case ['“]?-?\[?([^'”\]\n]+)\]?['”]? failed/gi),
    ...text.matchAll(/[✘✗]\s+Test\s+([^\n]+)/g),
  ].map((match) => match[1].trim());
  if (/\b(error:|linker command failed|BUILD FAILED|compile command failed)\b/i.test(text)) throw new Error("compile/link/build failure is not test evidence");
  return { discovered, passed, skipped, failed, failedIds };
}

export function parseXcresultSummary(text: string): Evidence {
  const json = parseJson(text, "xcresult summary");
  if (!json || typeof json !== "object" || Array.isArray(json)) throw new Error("malformed xcresult test summary");
  const report = json as Record<string, unknown>;
  const requireString = (value: unknown): value is string => typeof value === "string";
  const requireCount = (value: unknown): value is number => asCount(value) !== undefined;
  const requireObject = (value: unknown): value is Record<string, unknown> => Boolean(value && typeof value === "object" && !Array.isArray(value));
  if (!requireString(report.title) || !requireString(report.environmentDescription)
    || !["Passed", "Failed", "Skipped", "Expected Failure", "unknown"].includes(String(report.result))) throw new Error("malformed xcresult test summary");
  if (!Array.isArray(report.topInsights) || report.topInsights.some((value) => !requireObject(value) || !requireString(value.impact) || !requireString(value.category) || !requireString(value.text))) throw new Error("malformed xcresult insights");
  if (!Array.isArray(report.statistics) || report.statistics.some((value) => !requireObject(value) || !requireString(value.title) || !requireString(value.subtitle))) throw new Error("malformed xcresult statistics");
  const devicesAndConfigurations = report.devicesAndConfigurations;
  if (!requireObject(devicesAndConfigurations) || !requireObject(devicesAndConfigurations.device) || !requireObject(devicesAndConfigurations.testPlanConfiguration)
    || ![devicesAndConfigurations.passedTests, devicesAndConfigurations.failedTests, devicesAndConfigurations.skippedTests, devicesAndConfigurations.expectedFailures].every(requireCount)
    || ![devicesAndConfigurations.device.deviceId, devicesAndConfigurations.device.deviceName, devicesAndConfigurations.device.architecture, devicesAndConfigurations.device.modelName, devicesAndConfigurations.device.osVersion].every(requireString)
    || ![devicesAndConfigurations.testPlanConfiguration.configurationId, devicesAndConfigurations.testPlanConfiguration.configurationName].every(requireString)) {
    throw new Error("malformed xcresult devices and configurations");
  }
  if (!Array.isArray(report.runtimeWarnings) || report.runtimeWarnings.some((value) => !requireObject(value) || !requireString(value.issueType) || !requireString(value.message))) throw new Error("malformed xcresult runtime warnings");
  if (!requireCount(report.expectedFailures)) throw new Error("malformed xcresult expected failures");
  const discovered = asCount(report.totalTestCount);
  const passed = asCount(report.passedTests);
  const failed = asCount(report.failedTests);
  const skipped = asCount(report.skippedTests);
  if ([discovered, passed, failed].some((count) => count === undefined)) throw new Error("malformed xcresult test summary");
  if (skipped === undefined) throw new Error("malformed xcresult test summary");
  if (!Array.isArray(report.testFailures)) throw new Error("malformed xcresult test failures");
  const failedIds = report.testFailures.map((failure) => {
    if (!failure || typeof failure !== "object" || Array.isArray(failure)) throw new Error("malformed xcresult test failure");
    const record = failure as Record<string, unknown>;
    const identifier = record.testIdentifierString;
    if (!requireString(record.testName) || !requireString(record.targetName) || !requireString(record.failureText)
      || !Number.isSafeInteger(record.testIdentifier) || typeof identifier !== "string" || !identifier) throw new Error("malformed xcresult test failure identifier");
    return identifier;
  });
  if (failedIds.length !== failed) throw new Error("xcresult failure identifiers do not match failed count");
  return { discovered, passed, skipped, failed, failedIds };
}

function eventString(event: Record<string, unknown>, names: string[]): string | undefined {
  for (const name of names) if (typeof event[name] === "string") return event[name] as string;
  return undefined;
}

export function validateCodexJsonl(raw: Uint8Array, options: Pick<Options, "allowedServers" | "requiredTools" | "requireRejection">): Evidence {
  if (raw.length === 0 || raw[raw.length - 1] !== 10) throw new Error("malformed or truncated Codex JSONL");
  const lines = new TextDecoder().decode(raw).split("\n");
  lines.pop();
  if (lines.length === 0 || lines.some((line) => !line.trim())) throw new Error("malformed Codex JSONL");
  const events = lines.map((line) => parseJson(line, "Codex JSONL event")).map((event) => {
    if (!event || typeof event !== "object" || Array.isArray(event)) throw new Error("malformed Codex JSONL event");
    return event as Record<string, unknown>;
  });
  if (events[0]?.type !== "thread.started" || !eventString(events[0], ["thread_id"])) throw new Error("Codex JSONL must start with one thread.started identifier");
  if (events[1]?.type !== "turn.started" || events.at(-1)?.type !== "turn.completed") throw new Error("Codex JSONL requires an ordered turn lifecycle with terminal turn.completed");
  if (events.filter((event) => event.type === "thread.started").length !== 1 || events.filter((event) => event.type === "turn.started").length !== 1 || events.filter((event) => event.type === "turn.completed").length !== 1) throw new Error("Codex JSONL requires unique thread and turn lifecycle events");
  const startedCalls = new Map<string, { server: string; tool: string; arguments: string }>();
  const completedCalls = new Map<string, Record<string, unknown>>();
  const prohibitedItems = new Set(["command_execution", "file_change", "web_search", "image_generation", "computer_use", "dynamic_tool_call"]);
  const passiveItems = new Set(["agent_message", "reasoning", "error"]);
  const todoStates = new Map<string, "started" | "completed">();
  const validTodo = (record: Record<string, unknown>) => typeof record.id === "string" && record.id.length > 0 && Array.isArray(record.items)
    && record.items.every((item) => item && typeof item === "object" && !Array.isArray(item) && typeof (item as Record<string, unknown>).text === "string" && typeof (item as Record<string, unknown>).completed === "boolean");
  const validResult = (value: unknown): boolean => {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const result = value as Record<string, unknown>;
    const validContentBlock = (block: unknown): boolean => {
      if (!block || typeof block !== "object" || Array.isArray(block)) return false;
      const content = block as Record<string, unknown>;
      if (content.type === "text") return typeof content.text === "string";
      if (content.type === "image" || content.type === "audio") return typeof content.data === "string" && typeof content.mimeType === "string";
      if (content.type === "resource") return Boolean(content.resource && typeof content.resource === "object" && !Array.isArray(content.resource));
      if (content.type === "resource_link") return typeof content.name === "string" && typeof content.uri === "string";
      return false;
    };
    return Object.hasOwn(result, "content") && Array.isArray(result.content)
      && result.content.every(validContentBlock)
      && Object.hasOwn(result, "structured_content")
      && (!Object.hasOwn(result, "_meta") || result._meta !== undefined);
  };
  for (const event of events) {
    if (!["thread.started", "turn.started", "item.started", "item.updated", "item.completed", "turn.completed"].includes(String(event.type))) throw new Error(`unsupported Codex JSONL event: ${String(event.type)}`);
    if (event.type !== "item.started" && event.type !== "item.updated" && event.type !== "item.completed") continue;
    const item = event.item;
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error("malformed Codex item event");
    const record = item as Record<string, unknown>;
    const itemType = eventString(record, ["type"]);
    if (!itemType) throw new Error("malformed Codex item type");
    if (prohibitedItems.has(itemType)) throw new Error(`disallowed Codex capability item: ${itemType}`);
    if (itemType === "todo_list") {
      if (!validTodo(record)) throw new Error("malformed Codex todo-list item");
      const id = record.id as string;
      const state = todoStates.get(id);
      if (event.type === "item.started" && state) throw new Error("duplicate Codex todo-list start");
      if (event.type === "item.updated" && state !== "started") throw new Error("Codex todo-list update is out of order");
      if (event.type === "item.completed" && state !== "started") throw new Error("Codex todo-list completion is out of order");
      todoStates.set(id, event.type === "item.completed" ? "completed" : "started");
      continue;
    }
    if (itemType !== "mcp_tool_call") {
      if (!passiveItems.has(itemType)) throw new Error(`unsupported Codex item type: ${itemType}`);
      if (typeof record.id !== "string" || !record.id || (itemType === "agent_message" || itemType === "reasoning") && typeof record.text !== "string" || itemType === "error" && typeof record.message !== "string") throw new Error("malformed passive Codex item");
      continue;
    }
    const id = eventString(record, ["id"]);
    const server = eventString(record, ["server"]);
    const tool = eventString(record, ["tool"]);
    if (!id || !server || !tool || !Object.hasOwn(record, "arguments")) throw new Error("malformed Codex MCP tool-call item");
    if (!options.allowedServers.includes(server)) throw new Error(`non-allowed MCP server: ${server}`);
    if ((event.type === "item.started" || event.type === "item.updated") && (record.status !== "in_progress" || record.result !== null || record.error !== null)) throw new Error("malformed in-progress Codex MCP tool-call item");
    if (event.type === "item.started") {
      if (startedCalls.has(id)) throw new Error("duplicate Codex MCP tool-call start");
      startedCalls.set(id, { server, tool, arguments: stableJson(record.arguments) });
    } else if (event.type === "item.completed") {
      if (completedCalls.has(id)) throw new Error("duplicate Codex MCP tool-call completion");
      completedCalls.set(id, record);
    } else if (!startedCalls.has(id) || completedCalls.has(id)) throw new Error("Codex MCP tool-call update is out of order");
    const started = startedCalls.get(id);
    if (started && (started.server !== server || started.tool !== tool || started.arguments !== stableJson(record.arguments))) throw new Error("Codex MCP tool-call identity changed");
  }
  const rejectionSeparator = options.requireRejection?.indexOf("=") ?? -1;
  const rejectionTool = rejectionSeparator >= 0 ? options.requireRejection!.slice(0, rejectionSeparator) : options.requiredTools.length === 1 ? options.requiredTools[0] : undefined;
  const rejectionMessage = rejectionSeparator >= 0 ? options.requireRejection!.slice(rejectionSeparator + 1) : options.requireRejection;
  if (options.requireRejection && (!rejectionTool || !rejectionMessage)) throw new Error("--require-rejection must identify exactly one required tool and exact error message");
  const isExpectedRejection = (call: Record<string, unknown>): boolean => {
    const error = call.error;
    return Boolean(rejectionMessage && call.tool === rejectionTool && call.status === "failed" && error && typeof error === "object" && !Array.isArray(error)
      && (error as Record<string, unknown>).message === rejectionMessage);
  };
  for (const tool of options.requiredTools) {
    const callIds = [...startedCalls].filter(([, call]) => call.tool === tool).map(([id]) => id);
    if (callIds.length === 0) throw new Error(`required Codex tool call missing: ${tool}`);
    if (!callIds.some((id) => {
      const completed = completedCalls.get(id);
      return Boolean(completed && ((completed.status === "completed" && validResult(completed.result) && (completed.error === null || completed.error === undefined)) || isExpectedRejection(completed)));
    })) throw new Error(`required Codex tool result missing: ${tool}`);
  }
  for (const [id, call] of startedCalls) if (!completedCalls.has(id)) throw new Error(`Codex MCP tool call has no completion: ${call.server}/${call.tool}`);
  for (const id of completedCalls.keys()) if (!startedCalls.has(id)) throw new Error("Codex MCP completion has no matching start");
  for (const call of completedCalls.values()) {
    if (call.status === "failed" && !isExpectedRejection(call)) throw new Error("unexpected Codex MCP tool-call failure");
    if (call.status !== "completed" && call.status !== "failed") throw new Error("malformed Codex MCP completion status");
    if (call.status === "completed" && (!validResult(call.result) || (call.error !== null && call.error !== undefined))) throw new Error("malformed successful Codex MCP result");
    if (call.status === "failed" && call.result !== null && call.result !== undefined) throw new Error("failed Codex MCP call must not contain a result");
  }
  if ([...todoStates.values()].some((state) => state !== "completed")) throw new Error("Codex todo-list has no completion");
  if (options.requireRejection) {
    const rejected = [...completedCalls.values()].some(isExpectedRejection);
    if (!rejected) throw new Error(`required Codex rejection missing: ${rejectionTool}=${rejectionMessage}`);
  }
  return { discovered: events.length, passed: events.length, skipped: 0, failed: 0 };
}

type ProcessSnapshot = { exitCode: number; stdout: string; stderr: string };

function parseDescendantPids(parentPid: number, output: string): number[] {
  const lines = output.split("\n").filter(Boolean);
  if (lines.length === 0) throw new Error("malformed process snapshot");
  const rows = lines.map((line) => {
    const match = line.trim().match(/^([1-9]\d*)\s+(\d+)$/);
    if (!match) throw new Error("malformed process snapshot");
    return [Number(match[1]), Number(match[2])] as const;
  });
  const descendants = new Set<number>();
  let frontier = [parentPid];
  while (frontier.length) {
    const next = rows.filter(([, ppid]) => frontier.includes(ppid)).map(([pid]) => pid).filter((pid) => !descendants.has(pid));
    next.forEach((pid) => descendants.add(pid));
    frontier = next;
  }
  return [...descendants].sort((left, right) => left - right);
}

export async function collectDescendantPids(
  parentPid: number,
  snapshot: () => Promise<ProcessSnapshot> = async () => {
    const process_ = Bun.spawn(["ps", "-axo", "pid=,ppid="], { stdout: "pipe", stderr: "pipe" });
    return { exitCode: await process_.exited, stdout: await new Response(process_.stdout).text(), stderr: await new Response(process_.stderr).text() };
  },
): Promise<number[]> {
  const result = await snapshot();
  if (result.exitCode !== 0) throw new Error(`process snapshot failed with exit ${result.exitCode}`);
  return parseDescendantPids(parentPid, result.stdout);
}

export async function sampleDescendantsWhileRunning(
  parentPid: number,
  completion: Promise<unknown>,
  lookup: (pid: number) => Promise<number[]> = collectDescendantPids,
  intervalMs = 100,
): Promise<number[]> {
  const descendants = new Set<number>();
  let completed = false;
  void completion.finally(() => { completed = true; });
  while (!completed) {
    for (const pid of await lookup(parentPid)) descendants.add(pid);
    if (!completed) await new Promise<void>((resolveDelay) => setTimeout(resolveDelay, intervalMs));
  }
  for (const pid of await lookup(parentPid)) descendants.add(pid);
  return [...descendants].sort((left, right) => left - right);
}

type ProcessRow = Omit<ProcessIdentity, "sessionId"> & { parentPid: number; state: string };

function processIdentityKey(identity: ProcessIdentity): string {
  return `${identity.pid}\0${identity.processGroupId}\0${identity.sessionId}\0${identity.startTime}\0${identity.executable}`;
}

function processIdentityBytes(identity: ProcessIdentity): number {
  return new TextEncoder().encode(processIdentityKey(identity)).length;
}

export function mergeBoundedProcessIdentities(
  observed: Map<string, ProcessIdentity>,
  additions: ProcessIdentity[],
  countLimit = PROCESS_IDENTITY_COUNT_LIMIT,
  byteLimit = PROCESS_IDENTITY_BYTE_LIMIT,
): void {
  let serializedBytes = [...observed.values()].reduce((total, identity) => total + processIdentityBytes(identity), 0);
  for (const identity of additions) {
    const key = processIdentityKey(identity);
    if (observed.has(key)) continue;
    if (observed.size + 1 > countLimit) throw new Error(`observed process identity count safety limit exceeded: ${countLimit}`);
    serializedBytes += processIdentityBytes(identity);
    if (serializedBytes > byteLimit) throw new Error(`observed process identity byte safety limit exceeded: ${byteLimit}`);
    observed.set(key, identity);
  }
}

export function parseProcessIdentityTable(output: string): ProcessRow[] {
  const rows = output.split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
    const match = line.match(/^([1-9]\d*)\s+(\d+)\s+([1-9]\d*)\s+(\S+)\s+((?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)$/);
    if (!match) throw new Error("malformed process identity snapshot");
    return { pid: Number(match[1]), parentPid: Number(match[2]), processGroupId: Number(match[3]), state: match[4], startTime: match[5], executable: match[6] };
  });
  if (rows.length === 0) throw new Error("malformed process identity snapshot");
  return rows;
}

async function processIdentityTable(): Promise<ProcessRow[]> {
  const child = Bun.spawn(["ps", "-axo", "pid=,ppid=,pgid=,state=,lstart=,comm="], { stdout: "pipe", stderr: "pipe" });
  const [exitCode, stdout] = await Promise.all([child.exited, readBounded(child.stdout, 8 * 1024 * 1024, "process snapshot")]);
  if (exitCode !== 0) throw new Error(`process identity snapshot failed with exit ${exitCode}`);
  return parseProcessIdentityTable(new TextDecoder().decode(stdout));
}

type NativeProcessOps = {
  getsid: (pid: number) => number;
  getpgid: (pid: number) => number;
  getpgrp: () => number;
  setsid: () => number;
};
let nativeProcessOps: NativeProcessOps | undefined;

function processOps(): NativeProcessOps {
  if (nativeProcessOps) return nativeProcessOps;
  const library = process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : process.platform === "linux" ? "libc.so.6" : undefined;
  if (!library) throw new Error("verified process containment requires POSIX session semantics");
  nativeProcessOps = dlopen(library, {
    getsid: { args: [FFIType.i32], returns: FFIType.i32 },
    getpgid: { args: [FFIType.i32], returns: FFIType.i32 },
    getpgrp: { args: [], returns: FFIType.i32 },
    setsid: { args: [], returns: FFIType.i32 },
  }).symbols as NativeProcessOps;
  return nativeProcessOps;
}

function posixSessionId(pid: number): number {
  return processOps().getsid(pid);
}

type SessionMembershipDependencies = {
  sessionIdFor?: (pid: number) => number;
  isAlive?: (pid: number) => boolean;
  resnapshot?: () => Promise<ProcessRow[]>;
};

export async function sessionMemberIdentities(
  sessionId: number,
  leaderPid: number,
  rows: ProcessRow[],
  known: Map<string, ProcessIdentity>,
  dependencies: SessionMembershipDependencies = {},
): Promise<ProcessIdentity[]> {
  const identities: ProcessIdentity[] = [];
  const sessionIdFor = dependencies.sessionIdFor ?? posixSessionId;
  const isAlive = dependencies.isAlive ?? ((pid: number) => {
    try { process.kill(pid, 0); return true; }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
      throw error;
    }
  });
  const resnapshot = dependencies.resnapshot ?? processIdentityTable;
  for (const { pid, processGroupId, state, startTime, executable } of rows) {
    if (pid === leaderPid) continue;
    const identity = { pid, processGroupId, sessionId, startTime, executable };
    const currentSessionId = sessionIdFor(pid);
    if (currentSessionId < 0) {
      if (/^Z/.test(state)) continue;
      else {
        if (!isAlive(pid)) continue;
        const sameProcess = (row: ProcessRow | undefined): row is ProcessRow => Boolean(row
          && row.processGroupId === processGroupId
          && row.startTime === startTime
          && row.executable === executable);
        const refreshed = (await resnapshot()).find((row) => row.pid === pid);
        if (!sameProcess(refreshed) || /^Z/.test(refreshed.state)) continue;
        const refreshedSessionId = sessionIdFor(pid);
        if (refreshedSessionId >= 0) {
          if (refreshedSessionId === sessionId) identities.push(identity);
          continue;
        }
        // A process can become a zombie after the refresh but before getsid.
        // Require a second identity check to prove that race; an unchanged,
        // non-zombie row remains a fail-closed unverifiable live process.
        const confirmation = (await resnapshot()).find((row) => row.pid === pid);
        if (!sameProcess(confirmation) || /^Z/.test(confirmation.state)) continue;
        throw new Error(`unable to verify the POSIX session for live process ${pid} (${confirmation.state})`);
      }
    } else if (currentSessionId === sessionId) {
      identities.push(identity);
    }
  }
  return identities.sort((left, right) => left.pid - right.pid);
}

export async function sampleSessionIdentities(
  sessionId: number,
  launcherPid: number,
  completion: Promise<unknown>,
  observed = new Map<string, ProcessIdentity>(),
  signal?: AbortSignal,
  snapshotMembers: () => Promise<ProcessIdentity[]> = async () => sessionMemberIdentities(sessionId, launcherPid, await processIdentityTable(), observed),
  wait: (milliseconds: number) => Promise<void> = (milliseconds) => new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds)),
): Promise<Map<string, ProcessIdentity>> {
  let completed = false;
  void completion.then(() => { completed = true; }, () => { completed = true; });
  while (!completed && !signal?.aborted) {
    mergeBoundedProcessIdentities(observed, await snapshotMembers());
    if (!completed && !signal?.aborted) await wait(DESCENDANT_SAMPLE_INTERVAL_MS);
  }
  return observed;
}

function signalProcessGroups(processGroupIds: number[], signal: NodeJS.Signals): void {
  for (const processGroupId of [...new Set(processGroupIds)].sort((left, right) => left - right)) {
    try {
      process.kill(-processGroupId, signal);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
    }
  }
}

type ProcessGroupCleanup = {
  detected: ProcessIdentity[];
  remaining: ProcessIdentity[];
  signals: Array<{ signal: NodeJS.Signals; processGroupIds: number[]; processIds: number[] }>;
};

type ProcessGroupCleanupDependencies = {
  snapshotMembers?: () => Promise<ProcessIdentity[]>;
  validateSignalMembers?: (members: ProcessIdentity[]) => Promise<ProcessIdentity[]>;
  signalGroups?: (processGroupIds: number[], signal: NodeJS.Signals) => void;
  signalPids?: (processIds: number[], signal: NodeJS.Signals) => void;
  wait?: (milliseconds: number) => Promise<void>;
};

type SignalValidationDependencies = SessionMembershipDependencies & {
  processTable?: () => Promise<ProcessRow[]>;
};

export async function validateSessionSignalMembers(
  sessionId: number,
  launcherPid: number,
  members: ProcessIdentity[],
  dependencies: SignalValidationDependencies = {},
): Promise<ProcessIdentity[]> {
  const current = await sessionMemberIdentities(
    sessionId,
    launcherPid,
    await (dependencies.processTable ?? processIdentityTable)(),
    new Map(),
    dependencies,
  );
  const currentKeys = new Set(current.map(processIdentityKey));
  return members.filter((member) => currentKeys.has(processIdentityKey(member)));
}

export function validateObservedProcessIdentities(
  observed: Map<string, ProcessIdentity>,
  rows: ProcessRow[],
  sessionIdFor: (pid: number) => number,
): ProcessIdentity[] {
  const rowsByPid = new Map(rows.map((row) => [row.pid, row]));
  const live: ProcessIdentity[] = [];
  for (const identity of observed.values()) {
    const row = rowsByPid.get(identity.pid);
    if (!row || /^Z/.test(row.state) || row.processGroupId !== identity.processGroupId
      || row.startTime !== identity.startTime || row.executable !== identity.executable) continue;
    const currentSessionId = sessionIdFor(identity.pid);
    if (currentSessionId < 0) throw new Error(`unable to verify the POSIX session for observed live process ${identity.pid}`);
    live.push({ ...identity, sessionId: currentSessionId });
  }
  return live.sort((left, right) => left.pid - right.pid);
}

type ProcessIdentityLimits = { countLimit: number; byteLimit: number };

export async function terminateProcessGroupMembers(
  sessionId: number,
  launcherPid: number,
  observed: Map<string, ProcessIdentity>,
  dependencies: ProcessGroupCleanupDependencies = {},
  limits: ProcessIdentityLimits = { countLimit: PROCESS_IDENTITY_COUNT_LIMIT, byteLimit: PROCESS_IDENTITY_BYTE_LIMIT },
): Promise<ProcessGroupCleanup> {
  const detected = new Map<string, ProcessIdentity>();
  const signals: Array<{ signal: NodeJS.Signals; processGroupIds: number[]; processIds: number[] }> = [];
  let evidenceError: Error | undefined;
  const snapshotMembers = dependencies.snapshotMembers ?? (async () => {
    const rows = await processIdentityTable();
    const sessionMembers = await sessionMemberIdentities(sessionId, launcherPid, rows, observed);
    const previouslyObserved = validateObservedProcessIdentities(observed, rows, posixSessionId);
    const combined = new Map<string, ProcessIdentity>();
    for (const identity of [...sessionMembers, ...previouslyObserved]) combined.set(`${identity.pid}\0${identity.startTime}\0${identity.executable}`, identity);
    return [...combined.values()].filter(({ pid }) => pid !== launcherPid).sort((left, right) => left.pid - right.pid);
  });
  const validateSignalMembers = dependencies.validateSignalMembers
    ?? (async (members: ProcessIdentity[]) => {
      const rows = await processIdentityTable();
      const candidates = new Map(members.map((member) => [processIdentityKey(member), member]));
      return validateObservedProcessIdentities(candidates, rows, posixSessionId);
    });
  const signalGroups = dependencies.signalGroups ?? signalProcessGroups;
  const signalPids = dependencies.signalPids ?? ((processIds: number[], signal: NodeJS.Signals) => {
    for (const pid of [...new Set(processIds)].sort((left, right) => left - right)) {
      try { process.kill(pid, signal); } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
      }
    }
  });
  const wait = dependencies.wait ?? ((milliseconds: number) => new Promise<void>((resolveDelay) => setTimeout(resolveDelay, milliseconds)));
  const snapshot = async (): Promise<ProcessIdentity[]> => {
    let members: ProcessIdentity[] | undefined;
    let snapshotError: Error | undefined;
    for (let attempt = 0; attempt < PROCESS_SNAPSHOT_RETRY_LIMIT; attempt += 1) {
      try { members = await snapshotMembers(); break; }
      catch (error) {
        snapshotError = error as Error;
        if (attempt + 1 < PROCESS_SNAPSHOT_RETRY_LIMIT) await wait(PROCESS_GROUP_POLL_INTERVAL_MS);
      }
    }
    if (!members) throw snapshotError!;
    try {
      mergeBoundedProcessIdentities(observed, members, limits.countLimit, limits.byteLimit);
      mergeBoundedProcessIdentities(detected, members, limits.countLimit, limits.byteLimit);
    } catch (error) {
      evidenceError ??= error as Error;
    }
    return members;
  };
  const signal = async (members: ProcessIdentity[], value: NodeJS.Signals): Promise<void> => {
    const validated = await validateSignalMembers(members);
    const processIds = validated.filter((member) => member.sessionId !== sessionId || member.processGroupId === launcherPid).map((member) => member.pid);
    const processGroupIds = [...new Set(validated.filter((member) => member.sessionId === sessionId && member.processGroupId !== launcherPid).map((member) => member.processGroupId))].sort((left, right) => left - right);
    if (processIds.length > 0) signalPids(processIds, value);
    if (processGroupIds.length > 0) signalGroups(processGroupIds, value);
    if (processIds.length > 0 || processGroupIds.length > 0) signals.push({ signal: value, processGroupIds, processIds });
  };
  const waitForEmpty = async (timeoutMs: number): Promise<ProcessIdentity[]> => {
    const deadline = Date.now() + timeoutMs;
    let members = await snapshot();
    while (members.length > 0 && Date.now() < deadline) {
      await wait(PROCESS_GROUP_POLL_INTERVAL_MS);
      members = await snapshot();
    }
    return members;
  };

  let remaining: ProcessIdentity[];
  try {
    remaining = await snapshot();
    if (remaining.length > 0) {
      await signal(remaining, "SIGTERM");
      remaining = await waitForEmpty(PROCESS_GROUP_TERM_GRACE_MS);
    }
    if (remaining.length > 0 || evidenceError) {
      const current = remaining.length > 0 ? remaining : await snapshot();
      await signal(current, "SIGKILL");
      remaining = await waitForEmpty(PROCESS_GROUP_KILL_GRACE_MS);
    }
  } catch (error) {
    throw error;
  }
  if (remaining.length > 0) throw new Error(`unable to terminate verified command session members: ${remaining.map(({ pid }) => pid).join(",")}`);
  if (evidenceError) throw evidenceError;
  return {
    detected: [...detected.values()].sort((left, right) => left.pid - right.pid),
    remaining,
    signals,
  };
}

function joinBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
  const output = new Uint8Array(first.length + second.length);
  output.set(first);
  output.set(second, first.length);
  return output;
}

export async function readBounded(stream: ReadableStream<Uint8Array>, limit: number, label: string): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > limit) throw new Error(`${label} exceeded ${limit} byte safety limit`);
    chunks.push(chunk);
  }
  const output = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.length; }
  return output;
}

class SessionCleanupUnprovenError extends Error {}
class ParentSignalError extends Error {
  constructor(readonly signal: "SIGINT" | "SIGTERM") { super(`verification cancelled by ${signal}`); }
}

async function execute(command: string[], environment?: Record<string, string | undefined>, cwd = process.cwd()): Promise<{ record: ProcessRecord; stdout: Uint8Array; stderr: Uint8Array }> {
  if (process.platform !== "darwin" && process.platform !== "linux") throw new Error("verified process containment requires POSIX session semantics");
  processOps();
  const outputLimit = resolveOutputStreamLimit();
  const startedAt = new Date().toISOString();
  let ready: { pid: number; sessionId: number; processGroupId: number } | undefined;
  let targetExit: number | undefined;
  let resolveReady!: () => void;
  let rejectReady!: (error: Error) => void;
  let resolveTargetExit!: () => void;
  const readyMessage = new Promise<void>((resolveReady_, rejectReady_) => { resolveReady = resolveReady_; rejectReady = rejectReady_; });
  const targetExitMessage = new Promise<void>((resolve) => { resolveTargetExit = resolve; });
  const child = Bun.spawn([process.execPath, import.meta.path, "__session-launcher", ...command], {
    cwd, stdout: "pipe", stderr: "pipe", ...(environment ? { env: environment } : {}),
    ipc(message) {
      if (!message || typeof message !== "object") return;
      const value = message as Record<string, unknown>;
      if (value.type === "READY" && [value.pid, value.sessionId, value.processGroupId].every((item) => typeof item === "number" && Number.isInteger(item) && item > 0)) {
        ready = { pid: value.pid as number, sessionId: value.sessionId as number, processGroupId: value.processGroupId as number };
        resolveReady();
      } else if (value.type === "EXIT" && typeof value.exitCode === "number" && Number.isInteger(value.exitCode)) {
        targetExit = value.exitCode;
        resolveTargetExit();
      }
    },
  });
  const launcherExit = child.exited;
  type Capture = { value?: Uint8Array; error?: Error };
  let reportCaptureFailure!: (error: Error) => void;
  const captureFailure = new Promise<Error>((resolve) => { reportCaptureFailure = resolve; });
  const capture = (stream: ReadableStream<Uint8Array>, label: string): { promise: Promise<Capture>; cancel: () => void } => {
    const reader = stream.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    const promise = (async (): Promise<Capture> => {
      let failure: Error | undefined;
      try {
        while (true) {
          const { done, value: chunk } = await reader.read();
          if (done) break;
        if (failure) continue;
        size += chunk.length;
        if (size > outputLimit) {
          failure = new Error(`${label} exceeded ${outputLimit} byte safety limit`);
          chunks.length = 0;
          reportCaptureFailure(failure);
        } else chunks.push(chunk);
        }
      } catch (error) {
        failure ??= error as Error;
        reportCaptureFailure(failure);
      } finally { reader.releaseLock(); }
      if (failure) return { error: failure };
      const value = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { value.set(chunk, offset); offset += chunk.length; }
      return { value };
    })();
    return { promise, cancel: () => { void reader.cancel().catch(() => undefined); } };
  };
  const stdoutCapture = capture(child.stdout, "command stdout");
  const stderrCapture = capture(child.stderr, "command stderr");
  const captureResults = () => Promise.all([stdoutCapture.promise, stderrCapture.promise]);
  const boundedCaptureShutdown = async (): Promise<[Capture, Capture]> => {
    const pending = captureResults();
    const timeout = new Promise<"timeout">((resolveTimeout) => setTimeout(() => resolveTimeout("timeout"), OUTPUT_SHUTDOWN_GRACE_MS));
    if (await Promise.race([pending.then(() => "done" as const), timeout]) === "timeout") {
      stdoutCapture.cancel(); stderrCapture.cancel();
      void pending.catch(() => undefined);
      const error = new Error("command output pipes did not close after bounded cleanup");
      return [{ error }, { error }];
    }
    return await pending;
  };
  void launcherExit.then(() => { if (!ready) rejectReady(new Error("session launcher exited before READY")); });
  const sessionId = child.pid;
  const processGroupId = child.pid;
  const observed = new Map<string, ProcessIdentity>();
  let started = false;
  let sampler: Promise<Map<string, ProcessIdentity>> | undefined;
  const samplerAbort = new AbortController();
  let cancelExecution!: (error: ParentSignalError) => void;
  const cancellation = new Promise<ParentSignalError>((resolveCancellation) => { cancelExecution = resolveCancellation; });
  const onSigint = () => cancelExecution(new ParentSignalError("SIGINT"));
  const onSigterm = () => cancelExecution(new ParentSignalError("SIGTERM"));
  process.once("SIGINT", onSigint);
  process.once("SIGTERM", onSigterm);
  const removeSignalHandlers = () => { process.off("SIGINT", onSigint); process.off("SIGTERM", onSigterm); };
  const release = async (): Promise<void> => {
    if (child.exitCode === null) child.send({ type: "RELEASE" });
    await launcherExit;
  };
  try {
    await readyMessage;
    if (!ready || ready.pid !== child.pid || ready.sessionId !== child.pid || ready.processGroupId !== child.pid
      || posixSessionId(child.pid) !== child.pid || processOps().getpgid(child.pid) !== child.pid) {
      throw new Error("session launcher did not establish a dedicated POSIX session");
    }
    // The first session sample is deliberately taken before START; the launcher
    // cannot spawn the target until the parent has begun tracking this session.
    mergeBoundedProcessIdentities(observed, await sessionMemberIdentities(sessionId, child.pid, await processIdentityTable(), observed));
    child.send({ type: "START" });
    started = true;
    sampler = sampleSessionIdentities(sessionId, child.pid, targetExitMessage, observed, samplerAbort.signal);
    await Promise.race([
      targetExitMessage,
      launcherExit.then(() => { throw new Error("session launcher exited before reporting target exit"); }),
      captureFailure.then((error) => { throw error; }),
      sampler.then(() => undefined),
      cancellation.then((error) => { throw error; }),
    ]);
    await sampler;
    const cleanup = await terminateProcessGroupMembers(sessionId, child.pid, observed);
    await release();
    samplerAbort.abort();
    removeSignalHandlers();
    const [stdoutResult, stderrResult] = await captureResults();
    if (stdoutResult.error) throw stdoutResult.error;
    if (stderrResult.error) throw stderrResult.error;
    const descendants = [...observed.values()].sort((left, right) => left.pid - right.pid);
    return {
      stdout: stdoutResult.value!,
      stderr: stderrResult.value!,
      record: {
        command: command[0], args: command.slice(1), cwd, startedAt, finishedAt: new Date().toISOString(), exitCode: targetExit!,
        child: {
          pid: child.pid,
          processGroupId,
          sessionId,
          containment: "posix-session",
          startedAt,
          descendantPids: descendants.map(({ pid }) => pid),
          descendants,
          remainingDescendants: cleanup.detected,
          remainingAfterCleanup: cleanup.remaining,
          cleanupSignals: cleanup.signals,
          samplingIntervalMs: DESCENDANT_SAMPLE_INTERVAL_MS,
        },
      },
    };
  } catch (error) {
    samplerAbort.abort();
    removeSignalHandlers();
    await sampler?.catch(() => undefined);
    let cleanupError: Error | undefined;
    if (started) {
      const cleanupDependencies = process.env.RUN_VERIFIED_TEST_FAIL_CLEANUP_SNAPSHOTS === "always"
        ? { snapshotMembers: async (): Promise<ProcessIdentity[]> => { throw new Error("forced cleanup snapshot failure"); } }
        : {};
      try { await terminateProcessGroupMembers(sessionId, child.pid, observed, cleanupDependencies); } catch (caught) { cleanupError = caught as Error; }
      if (cleanupError && child.exitCode === null) {
        try { child.send({ type: "ABORT" }); } catch {}
        await Promise.race([targetExitMessage, new Promise<void>((resolve) => setTimeout(resolve, PROCESS_GROUP_KILL_GRACE_MS))]);
        try { await terminateProcessGroupMembers(sessionId, child.pid, observed, cleanupDependencies); cleanupError = undefined; } catch (caught) { cleanupError = caught as Error; }
      }
    }
    if (!started || cleanupError) {
      try { child.kill("SIGKILL"); } catch {}
      await launcherExit.catch(() => undefined);
    } else await release().catch((caught) => { cleanupError = caught as Error; });
    if (cleanupError) await boundedCaptureShutdown();
    else await captureResults();
    if (cleanupError) throw new SessionCleanupUnprovenError(`${(error as Error).message}; process-group cleanup failed: ${cleanupError.message}`);
    throw error;
  }
}

type OwnedOutputRoot = { logical: string; physical: string; identity?: { dev: number; ino: number } };

async function existingOrFutureRealpath(path: string): Promise<string> {
  let current = resolve(path);
  const missing: string[] = [];
  while (true) {
    try {
      return resolve(await realpath(current), ...missing.reverse());
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      const parent = dirname(current);
      if (parent === current) throw new Error(`unable to resolve output path: ${path}`);
      missing.push(current.slice(parent.length + 1));
      current = parent;
    }
  }
}

async function createOwnedOutputRoot(path: string): Promise<OwnedOutputRoot> {
  const logical = resolve(path);
  try {
    const status = await lstat(logical);
    if (status.isSymbolicLink()) throw new Error(`owned output root must not be a symlink: ${path}`);
    if (!status.isDirectory()) throw new Error(`owned output root must be an existing real directory: ${path}`);
    if ((status.mode & 0o777) !== 0o700) throw new Error(`owned output root must have mode 0700: ${path}`);
    if (typeof process.getuid === "function" && status.uid !== process.getuid()) throw new Error(`owned output root must be owned by the current user: ${path}`);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new Error(`owned output root must already exist: ${path}`);
    throw error;
  }
  const physical = await realpath(logical);
  const status = await lstat(logical);
  return { logical, physical, identity: { dev: status.dev, ino: status.ino } };
}

async function assertInsideOwnedRoot(path: string, root: OwnedOutputRoot): Promise<string> {
  try {
    if ((await lstat(root.logical)).isSymbolicLink()) throw new Error(`owned output root must not be a symlink: ${root.logical}`);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const logicalPath = resolve(path);
  const pathRelative = relative(root.logical, logicalPath);
  if (pathRelative === "" || pathRelative === ".." || pathRelative.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) || resolve(root.logical, pathRelative) !== logicalPath) throw new Error(`output must be inside the effective owned output root: ${path}`);
  let component = root.logical;
  for (const segment of pathRelative.split(process.platform === "win32" ? "\\" : "/")) {
    component = join(component, segment);
    try {
      if ((await lstat(component)).isSymbolicLink()) throw new Error(`output path contains a symlink: ${path}`);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") break;
      throw error;
    }
  }
  const physicalPath = await existingOrFutureRealpath(logicalPath);
  const physicalRelative = relative(root.physical, physicalPath);
  if (physicalRelative === "" || physicalRelative === ".." || physicalRelative.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) || resolve(root.physical, physicalRelative) !== physicalPath) throw new Error(`output resolves outside the effective owned output root: ${path}`);
  return physicalPath;
}

async function ensureOwnedOutputRoot(root: OwnedOutputRoot): Promise<void> {
  if (await existingOrFutureRealpath(root.logical) !== root.physical) throw new Error("owned output root changed while preparing output");
  const logical = await lstat(root.logical);
  const physical = await lstat(root.physical);
  if (logical.isSymbolicLink() || !logical.isDirectory() || logical.dev !== physical.dev || logical.ino !== physical.ino) throw new Error(`owned output root must not be a symlink: ${root.logical}`);
  if ((logical.mode & 0o777) !== 0o700) throw new Error(`owned output root must have mode 0700: ${root.logical}`);
  if (typeof process.getuid === "function" && logical.uid !== process.getuid()) throw new Error(`owned output root must be owned by the current user: ${root.logical}`);
  if (root.identity && (root.identity.dev !== logical.dev || root.identity.ino !== logical.ino)) throw new Error("owned output root changed while preparing output");
  root.identity = { dev: logical.dev, ino: logical.ino };
}

type NativeDirectoryOps = {
  openat: (directory: number, path: Uint8Array, flags: number, mode: number) => number;
  mkdirat: (directory: number, path: Uint8Array, mode: number) => number;
  renameat: (oldDirectory: number, oldPath: Uint8Array, newDirectory: number, newPath: Uint8Array) => number;
  unlinkat: (directory: number, path: Uint8Array, flags: number) => number;
  flock: (file: number, operation: number) => number;
};

let nativeDirectoryOps: NativeDirectoryOps | undefined;

function directoryOps(): NativeDirectoryOps {
  if (nativeDirectoryOps) return nativeDirectoryOps;
  const library = process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : process.platform === "linux" ? "libc.so.6" : undefined;
  if (!library) throw new Error("containment-safe output writes are unsupported on this platform");
  nativeDirectoryOps = dlopen(library, {
    openat: { args: [FFIType.i32, FFIType.cstring, FFIType.i32, FFIType.i32], returns: FFIType.i32 },
    mkdirat: { args: [FFIType.i32, FFIType.cstring, FFIType.i32], returns: FFIType.i32 },
    renameat: { args: [FFIType.i32, FFIType.cstring, FFIType.i32, FFIType.cstring], returns: FFIType.i32 },
    unlinkat: { args: [FFIType.i32, FFIType.cstring, FFIType.i32], returns: FFIType.i32 },
    flock: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
  }).symbols as NativeDirectoryOps;
  return nativeDirectoryOps;
}

function inferAppleLane(command: string[]): "catalyst" | "iphone17pro" | undefined {
  const executable = basename(command[0] ?? "");
  const invokesXcodebuild = executable === "xcodebuild"
    || executable === "xcrun" && command.slice(1).some((argument) => basename(argument) === "xcodebuild");
  if (!invokesXcodebuild) return undefined;
  const destinationIndex = command.indexOf("-destination");
  const destination = destinationIndex >= 0 ? command[destinationIndex + 1] ?? "" : "";
  if (/Mac Catalyst/.test(destination)) return "catalyst";
  if (/iPhone 17 Pro/.test(destination)) return "iphone17pro";
  throw new Error("xcodebuild verification requires a supported serialized destination lane");
}

function acquireExclusiveLock(path: string, directory = atCurrentWorkingDirectory()): number {
  const descriptor = directoryOps().openat(directory, cString(path), constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
  if (descriptor < 0) throw new Error(`unable to open exclusive verification lock: ${path}`);
  fchmodSync(descriptor, 0o600);
  if (directoryOps().flock(descriptor, 2 | 4) !== 0) {
    closeSync(descriptor);
    throw new Error(`verification lane is already locked: ${path}`);
  }
  if (fstatSync(descriptor).size > 0) {
    closeSync(descriptor);
    throw new Error(`verification cleanup remains unproven for lock ${path}; clear it only after independently proving the prior session is empty`);
  }
  return descriptor;
}

export function productionLaneLockPath(lane: "catalyst" | "iphone17pro"): string {
  return `/tmp/rishi-test-integrity-${lane}.lock`;
}

function persistVerificationLockMarker(descriptor: number): void {
  writeAll(descriptor, `in-progress pid=${process.pid} started=${new Date().toISOString()}\n`);
  fsyncSync(descriptor);
}

function clearVerificationLockMarkers(descriptors: number[]): void {
  for (const descriptor of descriptors) {
    ftruncateSync(descriptor, 0);
    fsyncSync(descriptor);
  }
}

function acquireVerificationLocks(
  root: OwnedOutputRoot,
  lane: "catalyst" | "iphone17pro" | undefined,
  testLaneLockRoot?: OwnedOutputRoot,
  failMarkAt?: number,
): number[] {
  const rootDescriptor = openPinnedOutputRoot(root);
  const laneRootDescriptor = testLaneLockRoot ? openPinnedOutputRoot(testLaneLockRoot) : undefined;
  const held: number[] = [];
  try {
    held.push(acquireExclusiveLock(".run-verified.lock", rootDescriptor));
    if (lane) held.push(testLaneLockRoot
      ? acquireExclusiveLock(`rishi-test-integrity-${lane}.lock`, laneRootDescriptor)
      : acquireExclusiveLock(productionLaneLockPath(lane)));
    for (const [index, descriptor] of held.entries()) {
      if (index === failMarkAt) throw new Error("forced marker write failure");
      persistVerificationLockMarker(descriptor);
    }
    return held;
  } catch (error) {
    for (const descriptor of held.reverse()) closeSync(descriptor);
    throw error;
  } finally {
    if (laneRootDescriptor !== undefined) closeSync(laneRootDescriptor);
    closeSync(rootDescriptor);
  }
}

// Direct test boundary only: the production CLI never supplies a lane-lock
// root and therefore always uses productionLaneLockPath().
export async function exerciseVerificationLocksForTest(
  ownedRootPath: string,
  laneLockRootPath: string,
  options: { cleanupProven: boolean; failMarkAt?: number; beforeExecution?: () => Promise<void> | void },
): Promise<void> {
  const ownedRoot = await createOwnedOutputRoot(ownedRootPath);
  const laneLockRoot = await createOwnedOutputRoot(laneLockRootPath);
  await ensureOwnedOutputRoot(ownedRoot);
  await ensureOwnedOutputRoot(laneLockRoot);
  const locks = acquireVerificationLocks(ownedRoot, "iphone17pro", laneLockRoot, options.failMarkAt);
  try {
    await options.beforeExecution?.();
    if (!options.cleanupProven) throw new SessionCleanupUnprovenError("fixture cleanup remains unproven");
    clearVerificationLockMarkers(locks);
  } finally {
    for (const descriptor of locks.reverse()) closeSync(descriptor);
  }
}

function atCurrentWorkingDirectory(): number {
  return process.platform === "darwin" ? -2 : -100; // AT_FDCWD
}

function cString(value: string): Uint8Array {
  return new TextEncoder().encode(`${value}\0`);
}

function writeAll(fileDescriptor: number, content: Uint8Array | string): void {
  const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
  for (let offset = 0; offset < bytes.length;) {
    const written = writeSync(fileDescriptor, bytes, offset, bytes.length - offset);
    if (written <= 0) throw new Error("failed to write output artifact");
    offset += written;
  }
}

type PinnedOutputParent = { directory: number; leaf: string; identity: { dev: number; ino: number } };

function openPinnedOutputRoot(root: OwnedOutputRoot): number {
  const operations = directoryOps();
  const directory = operations.openat(atCurrentWorkingDirectory(), cString(root.physical), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW, 0);
  if (directory < 0) throw new Error("unable to pin owned output root");
  const pinned = fstatSync(directory);
  if (!root.identity || pinned.dev !== root.identity.dev || pinned.ino !== root.identity.ino) {
    closeSync(directory);
    throw new Error("owned output root changed before write");
  }
  return directory;
}

function openPinnedOutputParent(destination: string, root: OwnedOutputRoot, createParents = true): PinnedOutputParent {
  const pathRelative = relative(root.physical, destination);
  const components = pathRelative.split(process.platform === "win32" ? "\\" : "/").filter(Boolean);
  const leaf = components.pop();
  if (!leaf || pathRelative === ".." || pathRelative.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) throw new Error("output path is not contained by the pinned root");
  const operations = directoryOps();
  let directory = openPinnedOutputRoot(root);
  try {
    for (const component of components) {
      // mkdirat is anchored to the held descriptor. If the directory already
      // exists, openat with O_NOFOLLOW still rejects a replacement symlink.
      if (createParents) operations.mkdirat(directory, cString(component), 0o700);
      const next = operations.openat(directory, cString(component), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW, 0);
      if (next < 0) throw new Error("unable to pin output parent directory");
      closeSync(directory);
      directory = next;
    }
    const identity = fstatSync(directory);
    return { directory, leaf, identity: { dev: identity.dev, ino: identity.ino } };
  } catch (error) {
    closeSync(directory);
    throw error;
  }
}

async function assertPinnedOutputLocationCurrent(destination: string, root: OwnedOutputRoot, pinned: PinnedOutputParent): Promise<void> {
  if (!root.identity) throw new Error("owned output root identity is unavailable");
  const logicalRoot = await lstat(root.logical);
  if (logicalRoot.isSymbolicLink() || !logicalRoot.isDirectory()
    || logicalRoot.dev !== root.identity.dev || logicalRoot.ino !== root.identity.ino) {
    throw new Error("owned output root changed during write");
  }
  const current = openPinnedOutputParent(destination, root, false);
  try {
    if (current.identity.dev !== pinned.identity.dev || current.identity.ino !== pinned.identity.ino) {
      throw new Error("output parent directory changed during write");
    }
  } finally {
    closeSync(current.directory);
  }
}

type WriteBoundary = "before-pin" | "before-commit";

async function safeAtomicWrite(path: string, root: OwnedOutputRoot, content: Uint8Array | string, beforeWrite?: (boundary: WriteBoundary) => Promise<void> | void): Promise<void> {
  const destination = await assertInsideOwnedRoot(path, root);
  await ensureOwnedOutputRoot(root);
  if (await assertInsideOwnedRoot(path, root) !== destination) throw new Error("output path changed while preparing output");
  await beforeWrite?.("before-pin");

  // Recheck after the deterministic boundary used by callers/tests, then pin
  // every directory by descriptor. Later root/parent swaps cannot redirect a
  // temp create or rename through a replacement symlink.
  if (await assertInsideOwnedRoot(path, root) !== destination) throw new Error("output path changed before write");
  const pinnedRoot = openPinnedOutputRoot(root);
  let pinnedParent: PinnedOutputParent;
  try {
    pinnedParent = openPinnedOutputParent(destination, root);
  } catch (error) {
    closeSync(pinnedRoot);
    throw error;
  }
  const temporary = `.run-verified-${crypto.randomUUID()}.tmp`;
  const operations = directoryOps();
  let temporaryFileDescriptor = -1;
  let renamed = false;
  let committed = false;
  try {
    // Stage bytes directly in the exclusive owned root. A nested parent that
    // is renamed during the write cannot carry the temporary file outside.
    temporaryFileDescriptor = operations.openat(pinnedRoot, cString(temporary), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    if (temporaryFileDescriptor < 0) throw new Error("unable to create safe temporary output");
    // openat is variadic on Darwin; set the restrictive mode on the returned
    // descriptor rather than trusting a foreign-function varargs mode value.
    fchmodSync(temporaryFileDescriptor, 0o600);
    writeAll(temporaryFileDescriptor, content);
    fsyncSync(temporaryFileDescriptor);
    closeSync(temporaryFileDescriptor);
    temporaryFileDescriptor = -1;

    await beforeWrite?.("before-commit");
    await assertPinnedOutputLocationCurrent(destination, root, pinnedParent);
    // renameat operates in the pinned directory and replaces a raced symlink
    // itself, never its target.
    if (operations.renameat(pinnedRoot, cString(temporary), pinnedParent.directory, cString(pinnedParent.leaf)) !== 0) throw new Error("unable to atomically commit output");
    renamed = true;
    fsyncSync(pinnedParent.directory);
    await assertPinnedOutputLocationCurrent(destination, root, pinnedParent);
    committed = true;
  } finally {
    if (temporaryFileDescriptor >= 0) closeSync(temporaryFileDescriptor);
    if (!committed) operations.unlinkat(pinnedRoot, cString(temporary), 0);
    if (renamed && !committed) operations.unlinkat(pinnedParent.directory, cString(pinnedParent.leaf), 0);
    closeSync(pinnedRoot);
    closeSync(pinnedParent.directory);
  }
}

// Exported strictly for deterministic security regression tests. Production
// callers use the already-reconciled root owned by run().
export async function writeContainedFile(path: string, rootPath: string, content: Uint8Array | string, beforeWrite?: (boundary: WriteBoundary) => Promise<void> | void): Promise<void> {
  const root = await createOwnedOutputRoot(rootPath);
  await safeAtomicWrite(path, root, content, beforeWrite);
}

function isStrictResourceSample(value: unknown): value is ResourceSample {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const sample = value as Record<string, unknown>;
  const keys = ["version", "sampledAt", "platform", "target", "availableMemoryGiB", "freeDiskGiB", "thresholds", "processInventory", "lockInventory", "digest"];
  if (Object.keys(sample).length !== keys.length || keys.some((key) => !(key in sample))) return false;
  const thresholds = sample.thresholds;
  if (!thresholds || typeof thresholds !== "object" || Array.isArray(thresholds)) return false;
  const thresholdRecord = thresholds as Record<string, unknown>;
  if (Object.keys(thresholdRecord).length !== 2 || !["minAvailableMemoryGiB", "minFreeDiskGiB"].every((key) => key in thresholdRecord)) return false;
  return sample.version === 1
    && sample.platform === "darwin"
    && typeof sample.sampledAt === "string"
    && typeof sample.target === "string"
    && typeof sample.availableMemoryGiB === "number"
    && typeof sample.freeDiskGiB === "number"
    && typeof thresholdRecord.minAvailableMemoryGiB === "number"
    && typeof thresholdRecord.minFreeDiskGiB === "number"
    && Array.isArray(sample.processInventory)
    && Array.isArray(sample.lockInventory)
    && typeof sample.digest === "string";
}

async function validateResourceArtifact(path: string, expected: { target: string; minAvailableMemoryGiB: number; minFreeDiskGiB: number }): Promise<void> {
  const parsed = parseJson(await readFile(path, "utf8"), "resource artifact");
  if (!isStrictResourceSample(parsed)) throw new Error("malformed resource artifact schema");
  const sample = parsed as ResourceSample;
  if (sample.thresholds.minAvailableMemoryGiB < expected.minAvailableMemoryGiB || sample.thresholds.minFreeDiskGiB < expected.minFreeDiskGiB) throw new Error("resource artifact recorded thresholds are below caller expectations");
  const issues = validateResourceSample(sample, expected);
  if (issues.length) throw new Error(`resource artifact rejected: ${issues.join("; ")}`);
}

function declaredResultBundlePaths(command: string[]): string[] {
  const paths: string[] = [];
  for (let index = 0; index < command.length; index += 1) {
    if (command[index] === "-resultBundlePath") {
      if (command[index + 1]) paths.push(command[index + 1]);
      continue;
    }
    if (command[index].startsWith("-resultBundlePath=")) paths.push(command[index].slice("-resultBundlePath=".length));
  }
  return paths;
}

async function prepareFreshXcresult(options: Options): Promise<void> {
  const expected = resolve(options.xcresult!);
  const declared = declaredResultBundlePaths(options.command);
  if (declared.length !== 1 || resolve(options.cwd, declared[0]) !== expected) throw new Error("xcresult command must declare the exact --xcresult path once with -resultBundlePath");
  try {
    await lstat(expected);
    throw new Error("xcresult path must not exist before the verified invocation");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

type XcresultIdentity = { dev: number; ino: number; ctimeMs: number; mtimeMs: number };

type XcresultSnapshot = XcresultIdentity & { treeDigest: string; entries: number };

async function snapshotXcresultTree(root: string, record: ProcessRecord): Promise<{ treeDigest: string; entries: number }> {
  const rows: string[] = [];
  let totalBytes = 0;
  let entries = 0;
  const startedAt = Date.parse(record.startedAt);
  const finishedAt = Date.parse(record.finishedAt);
  const visit = async (path: string, relativePath: string): Promise<void> => {
    const status = await lstat(path);
    if (++entries > XCRESULT_ENTRY_LIMIT) throw new Error("xcresult bundle exceeded entry safety limit");
    if (status.isSymbolicLink() || (!status.isDirectory() && !status.isFile())) throw new Error("xcresult bundle contains an unsupported or symbolic-link entry");
    if (!Number.isFinite(status.ctimeMs)
      || status.ctimeMs + FILESYSTEM_TIMESTAMP_TOLERANCE_MS < startedAt
      || status.ctimeMs - FILESYSTEM_TIMESTAMP_TOLERANCE_MS > finishedAt) {
      throw new Error("xcresult bundle tree does not belong to the current invocation");
    }
    if (status.isDirectory()) {
      rows.push(`d\0${relativePath}\0${status.dev}\0${status.ino}\0${status.ctimeMs}\0${status.mtimeMs}`);
      const children = await readdir(path);
      children.sort();
      for (const child of children) await visit(join(path, child), relativePath ? `${relativePath}/${child}` : child);
    } else {
      if (status.size > XCRESULT_FILE_LIMIT_BYTES || (totalBytes += status.size) > XCRESULT_TREE_LIMIT_BYTES) throw new Error("xcresult bundle exceeded byte safety limit");
      const hash = createHash("sha256");
      let streamed = 0;
      for await (const chunk of createReadStream(path)) {
        streamed += chunk.length;
        if (streamed > XCRESULT_FILE_LIMIT_BYTES) throw new Error("xcresult file exceeded byte safety limit");
        hash.update(chunk);
      }
      if (streamed !== status.size) throw new Error("xcresult file changed while hashing");
      const contentDigest = hash.digest("hex");
      rows.push(`f\0${relativePath}\0${status.dev}\0${status.ino}\0${status.size}\0${status.ctimeMs}\0${status.mtimeMs}\0${contentDigest}`);
    }
  };
  await visit(root, "");
  return { treeDigest: createHash("sha256").update(rows.join("\n")).digest("hex"), entries: rows.length };
}

async function freshXcresultIdentity(path: string, record: ProcessRecord): Promise<XcresultSnapshot> {
  const status = await lstat(path).catch((error) => {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new Error("current invocation did not create the xcresult bundle");
    throw error;
  });
  if (status.isSymbolicLink() || !status.isDirectory()) throw new Error("current invocation produced an invalid xcresult bundle");
  const startedAt = Date.parse(record.startedAt);
  const finishedAt = Date.parse(record.finishedAt);
  if (!Number.isFinite(status.ctimeMs)
    || status.ctimeMs + FILESYSTEM_TIMESTAMP_TOLERANCE_MS < startedAt
    || status.ctimeMs - FILESYSTEM_TIMESTAMP_TOLERANCE_MS > finishedAt) {
    throw new Error("xcresult bundle does not belong to the current invocation");
  }
  return { dev: status.dev, ino: status.ino, ctimeMs: status.ctimeMs, mtimeMs: status.mtimeMs, ...await snapshotXcresultTree(path, record) };
}

async function assertXcresultIdentityUnchanged(path: string, expected: XcresultSnapshot, record: ProcessRecord): Promise<void> {
  const current = await lstat(path).catch(() => { throw new Error("xcresult bundle changed while parsing"); });
  if (current.isSymbolicLink() || !current.isDirectory()
    || current.dev !== expected.dev || current.ino !== expected.ino
    || current.ctimeMs !== expected.ctimeMs || current.mtimeMs !== expected.mtimeMs) {
    throw new Error("xcresult bundle changed while parsing");
  }
  const currentTree = await snapshotXcresultTree(path, record);
  if (currentTree.entries !== expected.entries || currentTree.treeDigest !== expected.treeDigest) throw new Error("xcresult bundle tree changed while parsing");
}

export function assertNoBuildInfrastructureDiagnostics(output: string): void {
  const diagnostics = [
    /^\*\*\s+(?:BUILD|ARCHIVE)\s+FAILED\s+\*\*$/im,
    /^The following build commands failed:/im,
    /\b(?:compiler|linker) command failed\b/i,
    /\b(?:SwiftCompile|CompileSwift|SwiftEmitModule|EmitSwiftModule|CompileC|CompileAssetCatalog|LinkAssetCatalog|Ld)\b[^\n]*(?:failed|error)/i,
    /^(?:<unknown>|[^:\n]+\.(?:swift|m|mm|c|cc|cpp|cxx|h|hpp)):\d+:\d+:\s+(?:fatal\s+)?error:/im,
    /^(?:clang|ld|swiftc):\s+(?:fatal\s+)?error:/im,
    /^xcodebuild:\s+error:/im,
    /^error:\s+(?:emit-module|linker|build|compilation|failed to build)\b/im,
  ];
  if (diagnostics.some((pattern) => pattern.test(output))) throw new Error("xcresult command reported compile/link/build infrastructure diagnostics");
}

async function run(options: Options): Promise<Artifact> {
  const workingDirectory = await lstat(options.cwd).catch(() => { throw new Error(`command cwd does not exist: ${options.cwd}`); });
  if (!workingDirectory.isDirectory() || workingDirectory.isSymbolicLink()) throw new Error(`command cwd is not a real directory: ${options.cwd}`);
  const lane = inferAppleLane(options.command);
  if (lane && !options.ownedOutputRoot) throw new Error("xcodebuild verification requires an explicit unique --owned-output-root");
  const ownedOutputRoot = await createOwnedOutputRoot(options.ownedOutputRoot ?? dirname(resolve(options.artifact)));
  await assertInsideOwnedRoot(options.artifact, ownedOutputRoot);
  if (options.rawOutput) {
    await assertInsideOwnedRoot(options.rawOutput, ownedOutputRoot);
    if (resolve(options.rawOutput) === resolve(options.artifact)) throw new Error("--raw-output must be distinct from --artifact");
  }
  if (options.resourceArtifact) {
    await assertInsideOwnedRoot(options.resourceArtifact, ownedOutputRoot);
    await validateResourceArtifact(options.resourceArtifact, {
      target: options.expectedResourceTarget!,
      minAvailableMemoryGiB: options.minAvailableMemoryGiB!,
      minFreeDiskGiB: options.minFreeDiskGiB!,
    });
  }
  if (options.xcresult) await assertInsideOwnedRoot(options.xcresult, ownedOutputRoot);
  await ensureOwnedOutputRoot(ownedOutputRoot);
  const locks = acquireVerificationLocks(ownedOutputRoot, lane);
  let markerClearAttempted = false;
  try {
  if (options.format === "xcresult") await prepareFreshXcresult(options);
  let command = options.command;
  let vitestOutputPath: string | undefined;
  if (options.format === "vitest-json") {
    vitestOutputPath = resolve(ownedOutputRoot.logical, `.run-verified-vitest-${crypto.randomUUID()}.json`);
    await assertInsideOwnedRoot(vitestOutputPath, ownedOutputRoot);
    command = [...command, "--reporter=json", `--outputFile=${vitestOutputPath}`];
  }
  let resourceResample: ResourceSample | undefined;
  if (lane && options.resourceArtifact) {
    if (options.expectedResourceTarget !== lane) throw new Error(`resource target must match inferred xcodebuild lane: ${lane}`);
    const expectations = {
      target: options.expectedResourceTarget,
      minAvailableMemoryGiB: options.minAvailableMemoryGiB!,
      minFreeDiskGiB: options.minFreeDiskGiB!,
    };
    resourceResample = await collectResourceSample(expectations);
    const issues = validateResourceSample(resourceResample, expectations, new Date(), new Set([process.pid]));
    if (issues.length) throw new Error(`live resource resample rejected: ${issues.join("; ")}`);
  }
  const { record, stdout, stderr } = await execute(command, undefined, options.cwd);
  const artifact: Artifact = { version: 1, format: options.format, ...record, commands: [record], ownedOutputRoot: ownedOutputRoot.logical, ...(resourceResample ? { resourceResample } : {}), ...(options.rawOutput ? { rawOutput: resolve(options.rawOutput) } : {}), ...(options.xcresult ? { xcresult: resolve(options.xcresult) } : {}) };
  try {
    if (record.child.remainingAfterCleanup.length > 0) throw new Error("verified command left remaining descendants running");
    if (options.rawOutput) {
      await safeAtomicWrite(options.rawOutput, ownedOutputRoot, stdout);
    }
    if (options.format === "command") {
      if (options.expectedRed) throw new Error("expected-red requires assertion evidence; command format verifies exit only");
      if (record.exitCode !== options.expectedExit) throw new Error(`exit mismatch: expected ${options.expectedExit}, got ${record.exitCode}`);
    } else {
      let evidence: Evidence;
      if (options.format === "vitest-json") {
        await assertInsideOwnedRoot(vitestOutputPath!, ownedOutputRoot);
        evidence = parseVitestJson(await readFile(vitestOutputPath!, "utf8").catch(() => { throw new Error("missing Vitest JSON reporter output"); }));
      }
      else if (options.format === "node-test") evidence = parseNodeTap(new TextDecoder().decode(stdout));
      else if (options.format === "swift-output") evidence = parseSwiftOutput(new TextDecoder().decode(joinBytes(stdout, stderr)));
      else if (options.format === "codex-jsonl") evidence = validateCodexJsonl(stdout, options);
      else {
        assertNoBuildInfrastructureDiagnostics(new TextDecoder().decode(joinBytes(stdout, stderr)));
        const xcresultIdentity = await freshXcresultIdentity(options.xcresult!, record);
        const result = await execute(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", options.xcresult!], undefined, options.cwd);
        artifact.commands.push(result.record);
        if (result.record.exitCode !== 0) throw new Error("xcresulttool summary command failed");
        await assertXcresultIdentityUnchanged(options.xcresult!, xcresultIdentity, record);
        evidence = parseXcresultSummary(new TextDecoder().decode(result.stdout));
      }
      artifact.evidence = evidence;
      if (options.expectedRed) {
        if (record.exitCode === 0) throw new Error("expected-red command exited zero");
      } else if (record.exitCode !== options.expectedExit) throw new Error(`exit mismatch: expected ${options.expectedExit}, got ${record.exitCode}`);
      validateEvidence(evidence, options.expectedRed, options.failureIds);
    }
  } finally {
    await safeAtomicWrite(options.artifact, ownedOutputRoot, `${JSON.stringify(artifact, null, 2)}\n`);
  }
  markerClearAttempted = true;
  clearVerificationLockMarkers(locks);
  return artifact;
  } catch (error) {
    if (!(error instanceof SessionCleanupUnprovenError) && !markerClearAttempted) {
      markerClearAttempted = true;
      clearVerificationLockMarkers(locks);
    }
    throw error;
  } finally {
    for (const descriptor of locks.reverse()) closeSync(descriptor);
  }
}

async function selfTest(): Promise<void> {
  const directory = await mkdtemp(resolve(tmpdir(), "run-verified-self-test-"));
  const invoke = async (arguments_: string[], environment?: Record<string, string | undefined>) => {
    const child = Bun.spawn([process.execPath, import.meta.path, ...arguments_], { stdout: "pipe", stderr: "pipe", ...(environment ? { env: environment } : {}) });
    const [exitCode] = await Promise.all([child.exited, readBounded(child.stdout, OUTPUT_STREAM_LIMIT_BYTES, "self-test stdout"), readBounded(child.stderr, OUTPUT_STREAM_LIMIT_BYTES, "self-test stderr")]);
    return { record: { exitCode } };
  };
  const fixture = (source: string, exitCode = 0) => [process.execPath, "-e", `process.stdout.write(${JSON.stringify(source)}); process.exit(${exitCode})`];
  const vitestFixture = (source: string, exitCode = 0) => [process.execPath, "-e", `const path = process.argv.find((value) => value.startsWith("--outputFile="))?.slice("--outputFile=".length); if (!path) process.exit(9); await Bun.write(path, ${JSON.stringify(source)}); process.exit(${exitCode})`, "--"];
  const xcresultFixture = (path: string, source: string, exitCode: number) => [process.execPath, "-e", `await (await import("node:fs/promises")).mkdir(${JSON.stringify(path)}, { recursive: true }); process.stderr.write(${JSON.stringify(source)}); process.exit(${exitCode})`, "--", "-resultBundlePath", path];
  const expectRejected = async (name: string, arguments_: string[]) => {
    const result = await invoke(arguments_);
    if (result.record.exitCode === 0) throw new Error(`self-test ${name} fixture unexpectedly accepted`);
  };
  const artifact = (name: string) => resolve(directory, `${name}.json`);
  const stableJson = (value: unknown): string => {
    if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
    if (value && typeof value === "object") {
      const object = value as Record<string, unknown>;
      return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
    }
    return JSON.stringify(value);
  };
  const vitestPass = JSON.stringify({ numTotalTests: 1, numPassedTests: 1, numPendingTests: 0, numTodoTests: 0, numFailedTests: 0, testResults: [] });
  const vitestFail = JSON.stringify({ numTotalTests: 1, numPassedTests: 0, numPendingTests: 0, numTodoTests: 0, numFailedTests: 1, testResults: [{ assertionResults: [{ fullName: "Suite test", status: "failed" }] }] });
  const tapPass = "TAP version 13\n1..1\nok 1 - one\n# tests 1\n# pass 1\n# fail 0\n";
  const tapSkip = "TAP version 13\n1..1\nok 1 - one # SKIP skip\n# tests 1\n# pass 0\n# skipped 1\n# fail 0\n";
  const swiftPass = "Test Suite 'All tests' passed\nExecuted 1 test, with 0 failures\n";
  const codexPass = [
    { type: "thread.started", thread_id: "self-test" },
    { type: "turn.started" },
    { type: "item.started", item: { id: "call-1", type: "mcp_tool_call", server: "self-test", tool: "safe.tool", arguments: {}, result: null, error: null, status: "in_progress" } },
    { type: "item.completed", item: { id: "call-1", type: "mcp_tool_call", server: "self-test", tool: "safe.tool", arguments: {}, result: { content: [{ type: "text", text: "ok" }], structured_content: null, _meta: null }, error: null, status: "completed" } },
    { type: "item.started", item: { id: "call-2", type: "mcp_tool_call", server: "self-test", tool: "reject.tool", arguments: {}, result: null, error: null, status: "in_progress" } },
    { type: "item.completed", item: { id: "call-2", type: "mcp_tool_call", server: "self-test", tool: "reject.tool", arguments: {}, result: null, error: { message: "INVALID_SELF_TEST" }, status: "failed" } },
    { type: "turn.completed", usage: {} },
  ].map(JSON.stringify).join("\n") + "\n";
  const passingCases: Array<[string, string[]]> = [
    ["vitest", ["vitest-json", "--artifact", artifact("vitest"), "--", ...vitestFixture(vitestPass)]],
    ["tap", ["node-test", "--artifact", artifact("tap"), "--", ...fixture(tapPass)]],
    ["swift", ["swift-output", "--artifact", artifact("swift"), "--", ...fixture(swiftPass)]],
    ["codex", ["codex-jsonl", "--artifact", artifact("codex"), "--raw-output", resolve(directory, "codex.raw.jsonl"), "--allow-server", "self-test", "--require-tool", "safe.tool", "--require-tool", "reject.tool", "--require-rejection", "reject.tool=INVALID_SELF_TEST", "--", ...fixture(codexPass)]],
    ["command", ["command", "--artifact", artifact("command"), "--expected-exit", "0", "--", ...fixture("")]],
  ];
  for (const [name, arguments_] of passingCases) {
    const result = await invoke(arguments_);
    if (result.record.exitCode !== 0) throw new Error(`self-test ${name} passing fixture rejected`);
  }
  const resourceUnsigned = {
    version: 1 as const, sampledAt: new Date().toISOString(), platform: "darwin" as const, target: "self-test",
    availableMemoryGiB: 4, freeDiskGiB: 4,
    thresholds: { minAvailableMemoryGiB: 2, minFreeDiskGiB: 2 }, processInventory: [], lockInventory: [],
  };
  const resourcePath = resolve(directory, "resource.json");
  await writeFile(resourcePath, `${JSON.stringify({ ...resourceUnsigned, digest: createHash("sha256").update(stableJson(resourceUnsigned)).digest("hex") })}\n`);
  const resourceResult = await invoke(["command", "--artifact", artifact("resource"), "--resource-artifact", resourcePath, "--expected-resource-target", "self-test", "--min-available-memory-gib", "2", "--min-free-disk-gib", "2", "--", ...fixture("")]);
  if (resourceResult.record.exitCode !== 0) throw new Error("self-test resource artifact fixture rejected");
  // This is a safe xcresulttool mock: it shadows only this child process's xcrun lookup.
  const xcrun = resolve(directory, "xcrun");
  const xcSummary = { title: "Test - rishi", environmentDescription: "self-test", topInsights: [], result: "Failed", totalTestCount: 1, passedTests: 0, failedTests: 1, skippedTests: 0, expectedFailures: 0, statistics: [], devicesAndConfigurations: { device: { deviceId: "self", deviceName: "self", architecture: "arm64", modelName: "self", osVersion: "26.0" }, testPlanConfiguration: { configurationId: "1", configurationName: "Test" }, passedTests: 0, failedTests: 1, skippedTests: 0, expectedFailures: 0 }, testFailures: [{ testName: "test", targetName: "rishiTests", failureText: "failed", testIdentifier: 1, testIdentifierString: "Module.Class/test" }], runtimeWarnings: [] };
  await writeFile(xcrun, `#!/bin/sh\nprintf '%s\\n' '${JSON.stringify(xcSummary)}'\n`);
  await chmod(xcrun, 0o700);
  const xcresultPath = resolve(directory, "mock.xcresult");
  const xcresultResult = await invoke(["xcresult", "--artifact", artifact("xcresult"), "--xcresult", xcresultPath, "--expected-red", "--require-failure-id", "Module.Class/test", "--", ...xcresultFixture(xcresultPath, "", 1)], { ...process.env, PATH: `${directory}:${process.env.PATH ?? ""}` });
  if (xcresultResult.record.exitCode !== 0) throw new Error("self-test xcresult fixture rejected");
  const redResult = await invoke(["vitest-json", "--artifact", artifact("red"), "--expected-red", "--require-failure-id", "Suite test", "--", ...vitestFixture(vitestFail, 1)]);
  if (redResult.record.exitCode !== 0) throw new Error("self-test expected-red failure fixture rejected");
  await expectRejected("expected-red-zero", ["vitest-json", "--artifact", artifact("red-zero"), "--expected-red", "--", ...vitestFixture(vitestPass)]);
  await expectRejected("skip", ["node-test", "--artifact", artifact("skip"), "--", ...fixture(tapSkip)]);
  await expectRejected("malformed", ["swift-output", "--artifact", artifact("malformed"), "--", ...fixture("nonsense")]);
  await expectRejected("wrong-failure-id", ["vitest-json", "--artifact", artifact("wrong-id"), "--expected-red", "--require-failure-id", "wrong", "--", ...vitestFixture(vitestFail, 1)]);
  await expectRejected("missing-failure-id", ["vitest-json", "--artifact", artifact("missing-id"), "--expected-red", "--require-failure-id", "missing", "--", ...vitestFixture(vitestFail, 1)]);
  await expectRejected("truncated-jsonl", ["codex-jsonl", "--artifact", artifact("truncated"), "--raw-output", resolve(directory, "truncated.raw.jsonl"), "--", ...fixture("{")]);
  await expectRejected("resource-expectations", ["command", "--artifact", artifact("resource-expectations"), "--resource-artifact", resolve(directory, "resource.json"), "--", ...fixture("")]);
  await expectRejected("exit-mismatch", ["command", "--artifact", artifact("mismatch"), "--expected-exit", "4", "--", ...fixture("")]);
  process.stdout.write("self-test: passed\n");
}

async function runSessionLauncher(command: string[]): Promise<void> {
  if (process.platform !== "darwin" && process.platform !== "linux") throw new Error("verified process containment requires POSIX session semantics");
  if (command.length === 0) throw new Error("session launcher requires a command");
  if (process.env.RUN_VERIFIED_TEST_FORCE_SESSION_FAILURE === "1") throw new Error("session launcher could not establish a dedicated POSIX session");
  const operations = processOps();
  if (operations.setsid() < 0 || operations.getsid(0) !== process.pid || operations.getpgrp() !== process.pid) {
    throw new Error("session launcher could not establish a dedicated POSIX session");
  }
  if (typeof process.send !== "function") throw new Error("session launcher control channel is unavailable");
  const nextMessage = (): Promise<Record<string, unknown>> => new Promise((resolveMessage) => {
    const onMessage = (message: unknown) => { process.off("disconnect", onDisconnect); resolveMessage(message && typeof message === "object" ? message as Record<string, unknown> : {}); };
    const onDisconnect = () => { process.off("message", onMessage); resolveMessage({ type: "DISCONNECT" }); };
    process.once("message", onMessage);
    process.once("disconnect", onDisconnect);
  });
  const startMessage = nextMessage();
  process.send({ type: "READY", pid: process.pid, sessionId: process.pid, processGroupId: process.pid });
  const start = await startMessage;
  if (start.type !== "START") throw new Error("session launcher did not receive START");
  const target = Bun.spawn(command, { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
  process.send({ type: "STARTED", pid: target.pid });
  let forcedExit: ReturnType<typeof setTimeout> | undefined;
  const stopTarget = (signal: NodeJS.Signals = "SIGTERM"): void => {
    try { target.kill(signal); } catch {}
    forcedExit ??= setTimeout(() => { try { target.kill("SIGKILL"); } catch {} }, PROCESS_GROUP_KILL_GRACE_MS);
  };
  const abortTarget = (message: unknown): void => {
    if (message && typeof message === "object" && (message as Record<string, unknown>).type === "ABORT") stopTarget("SIGKILL");
  };
  const disconnect = () => stopTarget();
  const signal = () => stopTarget();
  process.on("message", abortTarget);
  process.once("disconnect", disconnect);
  process.once("SIGINT", signal);
  process.once("SIGTERM", signal);
  const exitCode = await target.exited;
  if (forcedExit) clearTimeout(forcedExit);
  process.off("message", abortTarget);
  process.off("disconnect", disconnect);
  process.off("SIGINT", signal);
  process.off("SIGTERM", signal);
  const releaseMessage = nextMessage();
  process.send({ type: "EXIT", exitCode });
  const release = await releaseMessage;
  if (release.type !== "RELEASE") throw new Error("session launcher did not receive RELEASE");
  process.exitCode = exitCode;
}

if (import.meta.main) {
  try {
    if (process.argv[2] === "self-test") await selfTest();
    else if (process.argv[2] === "__session-launcher") await runSessionLauncher(process.argv.slice(3));
    else await run(parseOptions(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`run-verified: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = error instanceof ParentSignalError ? error.signal === "SIGINT" ? 130 : 143 : 1;
  }
}
