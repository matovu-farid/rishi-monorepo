#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { lstat, mkdir, readdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { validateManifest, type ReleaseManifest, type ReleaseManifestEntry, type ReleaseStep } from "./verify-shared-reading-release";

type JsonObject = Record<string, unknown>;
type StepContext = { repoRoot: string; evidenceRoot: string; sha: string };
export type ReleaseRunDependencies = {
  now?: () => Date;
  gitHead: () => string | Promise<string>;
  worktreeStatus: (repoRoot: string) => string | Promise<string>;
  runStep: (step: ReleaseStep, context: StepContext) => void | Promise<void>;
};
export type ReleaseRunOptions = { manifest: ReleaseManifest; evidenceRoot: string; sha: string; dryRun?: boolean; repoRoot?: string };
export type ReleaseRunResult = { sha: string; dryRun: boolean; artifacts: string[]; commands: string[] };

const DECLARED_PLACEHOLDERS = new Set(["RISHI_RELEASE_ROOT", "RISHI_RELEASE_SHA"]);

export function expandStepArgs(args: string[], context: StepContext): string[] {
  return args.map((arg) => {
    const expanded = arg.replace(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g, (placeholder, bracedName: string | undefined, bareName: string | undefined) => {
      const name = bracedName ?? bareName!;
      if (!DECLARED_PLACEHOLDERS.has(name)) throw new Error(`unknown step argv placeholder: $${name}`);
      return name === "RISHI_RELEASE_ROOT" ? context.evidenceRoot : context.sha;
    });
    if (expanded.includes("$")) throw new Error(`unknown step argv placeholder in: ${arg}`);
    return expanded;
  });
}

async function spawn(command: string[], cwd: string): Promise<string> {
  const child = Bun.spawn(command, { cwd, env: process.env, stdout: "pipe", stderr: "pipe" });
  const stdout = await new Response(child.stdout).text();
  const stderr = await new Response(child.stderr).text();
  if (await child.exited !== 0) throw new Error(stderr.trim() || `command failed: ${command[0]}`);
  return stdout;
}

const realDependencies: ReleaseRunDependencies = {
  gitHead: async () => (await spawn(["git", "rev-parse", "HEAD"], process.cwd())).trim(),
  worktreeStatus: (repoRoot) => spawn(["git", "status", "--porcelain=v1", "--untracked-files=all"], repoRoot),
  runStep: async (step, context) => {
    const args = ["bun", join(context.repoRoot, "scripts/test-integrity/run-verified.ts"), step.format, "--artifact", resolve(context.evidenceRoot, step.result), "--owned-output-root", context.evidenceRoot, "--cwd", resolve(context.repoRoot, step.cwd)];
    if (step.format === "xcresult") args.push("--xcresult", resolve(context.evidenceRoot, step.xcresult!));
    args.push("--", ...step.command);
    await spawn(args, context.repoRoot);
  },
};

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") { const object = value as JsonObject; return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`; }
  return JSON.stringify(value);
}
function hashObject(value: JsonObject): string { const unsigned = { ...value }; delete unsigned.contentHash; return createHash("sha256").update(stableJson(unsigned)).digest("hex"); }
async function writeAtomic(path: string, value: unknown): Promise<void> { await mkdir(dirname(path), { recursive: true }); const temporary = join(dirname(path), `.${path.split("/").at(-1)}.${crypto.randomUUID()}.tmp`); await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 }); await rename(temporary, path); }
function inside(root: string, path: string): boolean { const value = relative(resolve(root), resolve(path)); return value === "" || (!value.startsWith(`..${sep}`) && value !== ".." && !isAbsolute(value)); }

async function digestPath(path: string): Promise<string> {
  const info = await lstat(path).catch(() => undefined); if (!info) throw new Error(`missing required output: ${path}`);
  const hash = createHash("sha256");
  if (info.isDirectory()) {
    const walk = async (directory: string): Promise<void> => {
      const entries = (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name));
      for (const entry of entries) { const child = join(directory, entry.name); const childInfo = await lstat(child); if (childInfo.isDirectory()) await walk(child); else if (childInfo.isFile()) { hash.update(relative(path, child)); hash.update("\0"); hash.update(await readFile(child)); hash.update("\0"); } else throw new Error(`unsupported output entry: ${child}`); }
    }; await walk(path);
  } else if (info.isFile()) hash.update(await readFile(path)); else throw new Error(`required output is not a file or directory: ${path}`);
  return hash.digest("hex");
}

function count(value: unknown, label: string): number { if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error(`malformed normalized ${label}`); return value as number; }
async function consumeNormalized(step: ReleaseStep, root: string) {
  const path = resolve(root, step.result); let raw: Uint8Array; let value: unknown;
  try { raw = await readFile(path); value = JSON.parse(new TextDecoder().decode(raw)); } catch { throw new Error(`missing or malformed normalized result: ${step.id}`); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`malformed normalized result: ${step.id}`);
  const artifact = value as JsonObject;
  if (artifact.version !== 1 || artifact.format !== step.format || artifact.exitCode !== 0) throw new Error(`failed normalized result: ${step.id}`);
  let evidence: { discovered: number; passed: number; failed: number; skipped: number } | undefined;
  if (step.kind === "test") {
    if (!artifact.evidence || typeof artifact.evidence !== "object" || Array.isArray(artifact.evidence)) throw new Error(`missing normalized test evidence: ${step.id}`);
    const record = artifact.evidence as JsonObject;
    evidence = { discovered: count(record.discovered, "discovered"), passed: count(record.passed, "passed"), failed: count(record.failed, "failed"), skipped: count(record.skipped, "skipped") };
    if (evidence.discovered === 0) throw new Error(`normalized discovered=0: ${step.id}`);
    if (evidence.passed + evidence.failed + evidence.skipped !== evidence.discovered) throw new Error(`malformed normalized counts: ${step.id}`);
    if (evidence.skipped !== 0) throw new Error(`normalized result contains skipped tests: ${step.id}`);
    if (evidence.failed !== 0) throw new Error(`normalized result contains failed tests: ${step.id}`);
  }
  return { id: step.id, kind: step.kind, format: step.format, path: step.result, sha256: createHash("sha256").update(raw).digest("hex"), ...(evidence ?? {}) };
}

async function assertFresh(path: string): Promise<void> { if (await lstat(path).catch(() => undefined)) throw new Error(`release artifact already exists: ${path}`); }
function orderedEntries(manifest: ReleaseManifest): ReleaseManifestEntry[] { return [...manifest.required].sort((a, b) => Number(a.category === "Apple UI acceptance") - Number(b.category === "Apple UI acceptance")); }

export async function runRelease(options: ReleaseRunOptions, dependencies: ReleaseRunDependencies = realDependencies): Promise<ReleaseRunResult> {
  if (!/^[a-f0-9]{40}$/.test(options.sha)) throw new Error("--sha must be a full commit SHA");
  const repoRoot = resolve(options.repoRoot ?? process.cwd()); const evidenceRoot = resolve(options.evidenceRoot);
  validateManifest(options.manifest);
  if (inside(repoRoot, evidenceRoot)) throw new Error("evidence root must be outside repository");
  if (await dependencies.gitHead() !== options.sha) throw new Error("requested SHA does not match git HEAD before release run");
  if ((await dependencies.worktreeStatus(repoRoot)).trim()) throw new Error("release run requires a clean worktree");
  const ordered = orderedEntries(options.manifest);
  if (options.dryRun) return { sha: options.sha, dryRun: true, artifacts: ordered.map((entry) => entry.artifact), commands: ordered.map((entry) => entry.command) };
  await mkdir(evidenceRoot, { recursive: true });
  for (const entry of ordered) {
    await assertFresh(resolve(evidenceRoot, entry.artifact));
    for (const step of entry.steps) { await assertFresh(resolve(evidenceRoot, step.result)); if (step.xcresult) await assertFresh(resolve(evidenceRoot, step.xcresult)); }
    for (const path of entry.auxiliary ?? []) await assertFresh(resolve(evidenceRoot, path));
  }
  const pending: Array<{ entry: ReleaseManifestEntry; artifact: JsonObject }> = [];
  for (const entry of ordered) {
    const startedAt = (dependencies.now ?? (() => new Date()))().toISOString(); const results = [];
    for (const step of entry.steps) {
      const context = { repoRoot, evidenceRoot, sha: options.sha };
      const resolvedStep = { ...step, command: expandStepArgs(step.command, context) };
      await dependencies.runStep(resolvedStep, context);
      results.push(await consumeNormalized(step, evidenceRoot));
    }
    const testResults = results.filter((result) => result.kind === "test");
    const totals = testResults.reduce((sum, result) => ({ discovered: sum.discovered + (result.discovered ?? 0), passed: sum.passed + (result.passed ?? 0), failed: sum.failed + (result.failed ?? 0), skipped: sum.skipped + (result.skipped ?? 0) }), { discovered: 0, passed: 0, failed: 0, skipped: 0 });
    if (totals.discovered === 0) throw new Error(`category has zero normalized test discovery: ${entry.category}`);
    const auxiliary = []; for (const path of entry.auxiliary ?? []) auxiliary.push({ path, sha256: await digestPath(resolve(evidenceRoot, path)) });
    const artifact: JsonObject = { version: 2, id: entry.id, category: entry.category, command: entry.command, sha: options.sha, testIds: entry.testIds, ...totals, startedAt, finishedAt: (dependencies.now ?? (() => new Date()))().toISOString(), exitCode: 0, results, auxiliary };
    artifact.contentHash = hashObject(artifact); pending.push({ entry, artifact });
  }
  if (await dependencies.gitHead() !== options.sha) throw new Error("git HEAD changed during release run");
  if ((await dependencies.worktreeStatus(repoRoot)).trim()) throw new Error("worktree became dirty during release run");
  for (const item of pending) await writeAtomic(resolve(evidenceRoot, item.entry.artifact), item.artifact);
  return { sha: options.sha, dryRun: false, artifacts: pending.map((item) => item.entry.artifact), commands: ordered.map((entry) => entry.command) };
}

async function parseCli(arguments_: string[]) {
  let manifestPath: string | undefined; let evidenceRoot: string | undefined; let sha: string | undefined; let dryRun = false;
  for (let index = 0; index < arguments_.length; index += 1) { const flag = arguments_[index]; if (flag === "--dry-run") { dryRun = true; continue; } const value = arguments_[++index]; if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`); if (flag === "--manifest") manifestPath = value; else if (flag === "--evidence-root") evidenceRoot = value; else if (flag === "--sha") sha = value; else throw new Error(`unknown option: ${flag}`); }
  if (!manifestPath || !evidenceRoot || !sha) throw new Error("usage: run-shared-reading-release.ts --manifest PATH --evidence-root PATH --sha SHA [--dry-run]");
  return { manifest: JSON.parse(await readFile(manifestPath, "utf8")) as ReleaseManifest, evidenceRoot, sha, dryRun };
}
if (import.meta.main) { try { await runRelease(await parseCli(process.argv.slice(2))); console.log("shared-reading release commands completed"); } catch (error) { console.error(error instanceof Error ? error.message : "release run failed"); process.exitCode = 1; } }
