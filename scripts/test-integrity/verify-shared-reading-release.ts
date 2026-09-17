#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { lstat, readdir, readFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

export type ReleaseStep = { id: string; kind: "test" | "check"; format: "vitest-json" | "swift-output" | "xcresult" | "command"; cwd: string; command: string[]; result: string; xcresult?: string };
export type ReleaseManifestEntry = { id: string; category: string; command: string; artifact: string; testIds: string[]; steps: ReleaseStep[]; auxiliary?: string[] };
export type ReleaseManifest = { version: 1; required: ReleaseManifestEntry[] };
export type VerificationDependencies = { gitHead: () => string | Promise<string>; worktreeStatus: (repoRoot: string) => string | Promise<string> };
export type VerificationOptions = { manifest: ReleaseManifest; evidenceRoot: string; sha: string; repoRoot?: string };
export type VerificationResult = { ok: true; sha: string; artifacts: string[] };
type JsonObject = Record<string, unknown>;

const REQUIRED_CATEGORIES = ["Worker", "sharing-worker", "Swift MCP", "Apple UI acceptance"];
const REQUIRED_E2E_ASSERTIONS = ["owner-create-share", "participant-join", "progress-sync", "owner-end", "rejoin-invalidation", "library-interaction"];
const REQUIRED_MCP_TOOLS = ["list_app_instances", "memory_snapshot", "start_app", "stop_app", "inspect_app_state", "select_book", "send_reader_action", "create_reading_session", "join_reading_session", "wait_for_participant", "click_text", "capture_screenshot"];
const STABLE_EVIDENCE_STRINGS = new Set(["host", "catalyst", "iphone17", "open", "select_to_share", "close", "next_page", "Leave session", "Leave and end for everyone", "Cancel", "<redacted>", "stable"]);
const SHA256 = /^[a-f0-9]{64}$/;
const COMMIT_SHA = /^[a-f0-9]{40}$/;

async function gitOutput(command: string[], repoRoot: string): Promise<string> {
  const child = Bun.spawn(command, { cwd: repoRoot, stdout: "pipe", stderr: "pipe" });
  const output = await new Response(child.stdout).text();
  if (await child.exited !== 0) throw new Error(`git command failed: ${command.join(" ")}`);
  return output;
}

const realDependencies: VerificationDependencies = {
  gitHead: async () => (await gitOutput(["git", "rev-parse", "HEAD"], process.cwd())).trim(),
  worktreeStatus: (repoRoot) => gitOutput(["git", "status", "--porcelain=v1", "--untracked-files=all"], repoRoot),
};

function isRecord(value: unknown): value is JsonObject { return Boolean(value && typeof value === "object" && !Array.isArray(value)); }
function stableJson(value: unknown): string { if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`; if (isRecord(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(",")}}`; return JSON.stringify(value); }
function hashObject(value: JsonObject): string { const unsigned = { ...value }; delete unsigned.contentHash; return createHash("sha256").update(stableJson(unsigned)).digest("hex"); }
function fail(message: string): never { throw new Error(message); }
function count(value: unknown, label: string): number { if (!Number.isSafeInteger(value) || (value as number) < 0) fail(`malformed ${label}`); return value as number; }
function validateTimestamp(value: unknown): value is string { return typeof value === "string" && !Number.isNaN(Date.parse(value)); }
function relativePath(path: unknown): path is string { return typeof path === "string" && path.length > 0 && !isAbsolute(path) && !path.split(/[\\/]/).includes(".."); }
function contained(root: string, path: string): boolean { const value = relative(resolve(root), resolve(path)); return value === "" || (!value.startsWith(`..${sep}`) && value !== ".." && !isAbsolute(value)); }

async function readJson(path: string, label: string): Promise<JsonObject> { let value: unknown; try { value = JSON.parse(await readFile(path, "utf8")); } catch { fail(`missing or malformed ${label}`); } if (!isRecord(value)) fail(`malformed ${label}`); return value; }
async function digestPath(path: string): Promise<string> {
  const info = await lstat(path).catch(() => undefined); if (!info) fail(`missing auxiliary artifact: ${path}`); const hash = createHash("sha256");
  if (info.isDirectory()) { const walk = async (directory: string): Promise<void> => { for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) { const child = join(directory, entry.name); const childInfo = await lstat(child); if (childInfo.isDirectory()) await walk(child); else if (childInfo.isFile()) { hash.update(relative(path, child)); hash.update("\0"); hash.update(await readFile(child)); hash.update("\0"); } else fail("unsupported auxiliary artifact entry"); } }; await walk(path); }
  else if (info.isFile()) hash.update(await readFile(path)); else fail("auxiliary artifact is not a file or directory"); return hash.digest("hex");
}

export function validateManifest(manifest: ReleaseManifest): void {
  if (!isRecord(manifest) || manifest.version !== 1 || !Array.isArray(manifest.required) || manifest.required.length !== REQUIRED_CATEGORIES.length) fail("malformed release manifest");
  const ids = new Set<string>(); const stepIds = new Set<string>(); const categories = new Set<string>();
  for (const entry of manifest.required) {
    if (!isRecord(entry) || typeof entry.id !== "string" || typeof entry.category !== "string" || typeof entry.command !== "string" || !relativePath(entry.artifact) || !Array.isArray(entry.testIds) || !Array.isArray(entry.steps) || entry.steps.length === 0) fail("malformed release manifest entry");
    if (ids.has(entry.id) || categories.has(entry.category)) fail("duplicate manifest ID or category"); ids.add(entry.id); categories.add(entry.category);
    if (!entry.testIds.every((id) => typeof id === "string") || new Set(entry.testIds).size !== entry.testIds.length) fail("duplicate or malformed test ID");
    for (const step of entry.steps) {
      if (!isRecord(step) || typeof step.id !== "string" || !["test", "check"].includes(step.kind as string) || !["vitest-json", "swift-output", "xcresult", "command"].includes(step.format as string) || typeof step.cwd !== "string" || !Array.isArray(step.command) || !step.command.every((item) => typeof item === "string") || !relativePath(step.result) || (step.format === "xcresult" && !relativePath(step.xcresult))) fail("malformed release step");
      if (stepIds.has(step.id)) fail(`duplicate test ID: ${step.id}`); stepIds.add(step.id);
    }
    if (stableJson(entry.testIds) !== stableJson(entry.steps.map((step) => step.id))) fail(`test IDs do not match steps: ${entry.id}`);
    if (entry.auxiliary && (!Array.isArray(entry.auxiliary) || !entry.auxiliary.every(relativePath))) fail("malformed auxiliary path");
  }
  for (const category of REQUIRED_CATEGORIES) if (!categories.has(category)) fail(`missing manifest entry for ${category}`);
  const apple = manifest.required.find((entry) => entry.category === "Apple UI acceptance")!;
  const afterStrictPrefix = apple.command.replace(/^\s*set -euo pipefail;\s*/, "");
  if (!/^\s*set -euo pipefail;/.test(apple.command) || /;/.test(afterStrictPrefix)) fail("Apple command must use strict fail-fast chaining");
}

function validateNormalized(value: JsonObject, step: ReleaseStep) {
  if (value.version !== 1 || value.format !== step.format || value.exitCode !== 0) fail(`failed normalized result: ${step.id}`);
  if (step.kind !== "test") return undefined;
  if (!isRecord(value.evidence)) fail(`missing normalized test evidence: ${step.id}`);
  const evidence = { discovered: count(value.evidence.discovered, "discovered"), passed: count(value.evidence.passed, "passed"), failed: count(value.evidence.failed, "failed"), skipped: count(value.evidence.skipped, "skipped") };
  if (evidence.discovered === 0 || evidence.passed + evidence.failed + evidence.skipped !== evidence.discovered || evidence.failed !== 0 || evidence.skipped !== 0) fail(`failed normalized test evidence: ${step.id}`);
  return evidence;
}

function validateContentHash(value: JsonObject, label: string): void { if (typeof value.contentHash !== "string" || !SHA256.test(value.contentHash) || hashObject(value) !== value.contentHash) fail(`${label} content hash mismatch`); }
function collectStrings(value: unknown, output: string[] = []): string[] { if (typeof value === "string") output.push(value); else if (Array.isArray(value)) value.forEach((item) => collectStrings(item, output)); else if (isRecord(value)) Object.values(value).forEach((item) => collectStrings(item, output)); return output; }

function validateMcpEvidence(value: JsonObject, sha: string): void {
  validateContentHash(value, "MCP evidence");
  if (value.version !== 1 || value.sha !== sha || stableJson(value.targets) !== stableJson(["catalyst", "iphone17"]) || value.peakInstances !== 2 || !isRecord(value.cleanup) || value.cleanup.zeroInstances !== true || value.cleanup.memoryChecked !== true || !isRecord(value.redaction) || value.redaction.version !== 1 || value.redaction.arbitraryTextStored !== false || !Array.isArray(value.calls) || value.calls.length === 0) fail("malformed or stale MCP evidence");
  const seen = new Set<string>();
  const starts = new Map<string, number>();
  const stops = new Map<string, number>();
  const startIndexes: number[] = [];
  const stopIndexes: number[] = [];
  const observations = new Map<string, { expectedCount: number; calls: number; index?: number }>([
    ["initial-instances", { expectedCount: 0, calls: 0 }],
    ["running-instances", { expectedCount: 2, calls: 0 }],
    ["final-instances", { expectedCount: 0, calls: 0 }],
  ]);
  for (const [callIndex, call] of value.calls.entries()) {
    if (!isRecord(call) || typeof call.tool !== "string" || !REQUIRED_MCP_TOOLS.includes(call.tool) || !["host", "catalyst", "iphone17"].includes(call.target as string) || call.success !== true || !isRecord(call.arguments) || typeof call.label !== "string") fail("malformed MCP call evidence");
    seen.add(call.tool);
    if (call.tool === "start_app" || call.tool === "stop_app") {
      if (call.target === "host" || call.arguments.app !== call.target) fail(`MCP ${call.tool} target does not match its app argument`);
      const counts = call.tool === "start_app" ? starts : stops;
      counts.set(call.target as string, (counts.get(call.target as string) ?? 0) + 1);
      (call.tool === "start_app" ? startIndexes : stopIndexes).push(callIndex);
    }
    const observation = observations.get(call.label);
    const hasObservedInstanceCount = Object.prototype.hasOwnProperty.call(call, "observedInstanceCount");
    if (observation) {
      if (call.tool !== "list_app_instances" || call.target !== "host") fail(`invalid MCP instance observation: ${call.label}`);
      if (!Number.isSafeInteger(call.observedInstanceCount) || (call.observedInstanceCount as number) < 0) fail(`malformed MCP observed instance count: ${call.label}`);
      if (call.observedInstanceCount !== observation.expectedCount) fail(`unexpected MCP observed instance count: ${call.label}`);
      observation.calls += 1;
      observation.index = callIndex;
    } else if (hasObservedInstanceCount) {
      fail("MCP observed instance count appears on an unrelated call");
    }
    for (const text of collectStrings(call.arguments)) if (!STABLE_EVIDENCE_STRINGS.has(text)) fail("MCP evidence violates redaction contract");
  }
  for (const tool of REQUIRED_MCP_TOOLS) if (!seen.has(tool)) fail(`missing required MCP call: ${tool}`);
  for (const target of ["catalyst", "iphone17"]) if (starts.get(target) !== 1 || stops.get(target) !== 1) fail(`MCP evidence must start and stop ${target} exactly once`);
  if (starts.size !== 2 || stops.size !== 2) fail("MCP evidence contains an unexpected app start or stop target");
  for (const [label, observation] of observations) if (observation.calls !== 1) fail(`MCP evidence must contain exactly one successful ${label} list observation`);
  if (value.calls.filter((call) => isRecord(call) && call.tool === "list_app_instances").length !== observations.size) fail("MCP evidence contains an unlabeled or duplicate app-instance observation");
  const initialIndex = observations.get("initial-instances")!.index!;
  const runningIndex = observations.get("running-instances")!.index!;
  const finalIndex = observations.get("final-instances")!.index!;
  if (initialIndex >= Math.min(...startIndexes) || Math.max(...startIndexes) >= runningIndex || runningIndex >= Math.min(...stopIndexes) || Math.max(...stopIndexes) >= finalIndex) fail("MCP instance lifecycle calls are out of order");
}

function validateE2eEvidence(value: JsonObject, sha: string): void {
  validateContentHash(value, "E2E evidence");
  if (value.version !== 1 || value.sha !== sha || stableJson(value.targets) !== stableJson(["catalyst", "iphone17"]) || value.failed !== 0 || !Array.isArray(value.assertions)) fail("malformed or stale E2E evidence");
  const assertions = new Map<string, boolean>(); for (const item of value.assertions) { if (!isRecord(item) || typeof item.id !== "string" || typeof item.passed !== "boolean" || assertions.has(item.id)) fail("malformed E2E assertion"); assertions.set(item.id, item.passed); }
  if (assertions.size !== REQUIRED_E2E_ASSERTIONS.length) fail("unexpected E2E assertion set"); for (const id of REQUIRED_E2E_ASSERTIONS) if (assertions.get(id) !== true) fail(`missing or failed E2E assertion: ${id}`);
}

async function verifyArtifact(entry: ReleaseManifestEntry, root: string, sha: string): Promise<void> {
  const artifact = await readJson(resolve(root, entry.artifact), `artifact ${entry.id}`); validateContentHash(artifact, `artifact ${entry.id}`);
  if (artifact.version !== 2 || artifact.id !== entry.id || artifact.category !== entry.category || artifact.command !== entry.command || artifact.sha !== sha || stableJson(artifact.testIds) !== stableJson(entry.testIds) || !validateTimestamp(artifact.startedAt) || !validateTimestamp(artifact.finishedAt) || artifact.exitCode !== 0 || !Array.isArray(artifact.results) || !Array.isArray(artifact.auxiliary)) fail(`malformed or stale artifact: ${entry.id}`);
  const expectedTotals = { discovered: 0, passed: 0, failed: 0, skipped: 0 };
  if (artifact.results.length !== entry.steps.length) fail(`missing normalized result: ${entry.id}`);
  for (let index = 0; index < entry.steps.length; index += 1) {
    const step = entry.steps[index]; const result = artifact.results[index]; if (!isRecord(result) || result.id !== step.id || result.path !== step.result || result.format !== step.format || typeof result.sha256 !== "string") fail(`malformed normalized result reference: ${step.id}`);
    const path = resolve(root, step.result); const raw = await readFile(path).catch(() => fail(`missing normalized result: ${step.id}`)); if (createHash("sha256").update(raw).digest("hex") !== result.sha256) fail(`normalized result hash mismatch: ${step.id}`);
    const normalized = JSON.parse(raw.toString()) as JsonObject; const evidence = validateNormalized(normalized, step); if (evidence) { for (const key of Object.keys(expectedTotals) as Array<keyof typeof expectedTotals>) expectedTotals[key] += evidence[key]; }
  }
  for (const key of Object.keys(expectedTotals) as Array<keyof typeof expectedTotals>) if (artifact[key] !== expectedTotals[key]) fail(`fabricated aggregate count: ${entry.id}`);
  if (expectedTotals.discovered === 0) fail(`zero discovery: ${entry.id}`);
  const expectedAuxiliary = entry.auxiliary ?? []; if (artifact.auxiliary.length !== expectedAuxiliary.length) fail("missing auxiliary artifact hash");
  for (let index = 0; index < expectedAuxiliary.length; index += 1) { const item = artifact.auxiliary[index]; const path = expectedAuxiliary[index]; if (!isRecord(item) || item.path !== path || typeof item.sha256 !== "string" || await digestPath(resolve(root, path)) !== item.sha256) fail(`auxiliary artifact hash mismatch: ${path}`); }
  if (entry.category === "Apple UI acceptance") {
    const mcp = await readJson(resolve(root, "shared-reading-mcp-evidence.json"), "MCP evidence"); const e2e = await readJson(resolve(root, "shared-reading-apple-e2e-evidence.json"), "E2E evidence"); validateMcpEvidence(mcp, sha); validateE2eEvidence(e2e, sha);
  }
}

export async function verifyRelease(options: VerificationOptions, dependencies: VerificationDependencies = realDependencies): Promise<VerificationResult> {
  const repoRoot = resolve(options.repoRoot ?? process.cwd());
  if ((await dependencies.worktreeStatus(repoRoot)).trim()) fail("verification requires a clean worktree before verification");
  if (!COMMIT_SHA.test(options.sha) || await dependencies.gitHead() !== options.sha) fail("requested SHA does not match git HEAD"); validateManifest(options.manifest);
  const root = resolve(options.evidenceRoot); if (contained(repoRoot, root)) fail("evidence root must be outside repository");
  const artifacts: string[] = []; for (const entry of options.manifest.required) { await verifyArtifact(entry, root, options.sha); artifacts.push(entry.artifact); }
  if ((await dependencies.worktreeStatus(repoRoot)).trim()) fail("worktree became dirty during verification");
  return { ok: true, sha: options.sha, artifacts };
}

async function parseCli(arguments_: string[]) { let manifestPath: string | undefined; let evidenceRoot: string | undefined; let sha: string | undefined; for (let index = 0; index < arguments_.length; index += 1) { const flag = arguments_[index]; const value = arguments_[++index]; if (!value || value.startsWith("--")) fail(`${flag} requires a value`); if (flag === "--manifest") manifestPath = value; else if (flag === "--evidence-root") evidenceRoot = value; else if (flag === "--sha") sha = value; else fail(`unknown option: ${flag}`); } if (!manifestPath || !evidenceRoot || !sha) fail("usage: verify-shared-reading-release.ts --manifest PATH --evidence-root PATH --sha SHA"); return { manifest: JSON.parse(await readFile(manifestPath, "utf8")) as ReleaseManifest, evidenceRoot, sha }; }
if (import.meta.main) { try { await verifyRelease(await parseCli(process.argv.slice(2))); console.log("shared-reading release evidence verified"); } catch (error) { console.error(error instanceof Error ? error.message : "release evidence rejected"); process.exitCode = 1; } }
