import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runRelease, type ReleaseRunDependencies } from "./run-shared-reading-release";
import type { ReleaseManifest } from "./verify-shared-reading-release";

const sha = "a".repeat(40);
const otherSha = "b".repeat(40);
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

async function roots() {
  const repoRoot = await mkdtemp(join(tmpdir(), "release-runner-repo-"));
  const evidenceRoot = await mkdtemp(join(tmpdir(), "release-runner-evidence-"));
  temporaryDirectories.push(repoRoot, evidenceRoot);
  return { repoRoot, evidenceRoot };
}

function manifest(): ReleaseManifest {
  const categories = [
    ["worker", "Worker"], ["sharing", "sharing-worker"], ["mcp", "Swift MCP"], ["apple", "Apple UI acceptance"],
  ] as const;
  return {
    version: 1,
    required: categories.map(([id, category]) => ({
      id,
      category,
      command: category === "Apple UI acceptance" ? "set -euo pipefail; first && second && acceptance" : `strict-${id}`,
      artifact: `${id}.json`,
      testIds: [`${id}.tests`],
      steps: [{ id: `${id}.tests`, kind: "test", format: "vitest-json", cwd: ".", command: ["fake", id], result: `normalized/${id}.json` }],
      ...(category === "Apple UI acceptance" ? { auxiliary: ["apple-iphone.xcresult", "apple-catalyst.xcresult", "shared-reading-mcp-evidence.json", "shared-reading-apple-e2e-evidence.json"] } : {}),
    })),
  } as ReleaseManifest;
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") { const object = value as Record<string, unknown>; return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`; }
  return JSON.stringify(value);
}

function hashed<T extends Record<string, unknown>>(value: T) {
  return { ...value, contentHash: createHash("sha256").update(stableJson(value)).digest("hex") };
}

async function writeAcceptanceEvidence(root: string) {
  const calls = ["list_app_instances", "memory_snapshot", "start_app", "inspect_app_state", "stop_app"]
    .map((tool, index) => ({ index, tool, target: tool === "start_app" || tool === "inspect_app_state" || tool === "stop_app" ? "catalyst" : "host", arguments: {}, success: true, label: "stable" }));
  const mcp = hashed({ version: 1, sha, targets: ["catalyst", "iphone17"], calls, cleanup: { zeroInstances: true, memoryChecked: true }, redaction: { version: 1, arbitraryTextStored: false } });
  const e2e = hashed({ version: 1, sha, targets: ["catalyst", "iphone17"], failed: 0, assertions: ["owner-create-share", "participant-join", "progress-sync", "owner-end", "rejoin-invalidation", "library-interaction"].map((id) => ({ id, passed: true })) });
  await writeFile(join(root, "shared-reading-mcp-evidence.json"), `${JSON.stringify(mcp)}\n`);
  await writeFile(join(root, "shared-reading-apple-e2e-evidence.json"), `${JSON.stringify(e2e)}\n`);
  await writeFile(join(root, "apple-iphone.xcresult"), "iphone");
  await writeFile(join(root, "apple-catalyst.xcresult"), "catalyst");
}

function dependencies(overrides: Partial<ReleaseRunDependencies> = {}): ReleaseRunDependencies {
  return {
    gitHead: async () => sha,
    worktreeStatus: async () => "",
    runStep: async (step, context) => {
      const path = join(context.evidenceRoot, step.result);
      await mkdir(join(context.evidenceRoot, "normalized"), { recursive: true });
      await writeFile(path, JSON.stringify({ version: 1, format: step.format, exitCode: 0, evidence: { discovered: 3, passed: 3, failed: 0, skipped: 0 } }));
      if (step.id === "apple.tests") await writeAcceptanceEvidence(context.evidenceRoot);
    },
    ...overrides,
  };
}

describe("shared-reading release runner", () => {
  test("passes real expanded argv to direct-spawn steps and expands only declared placeholders", async () => {
    const { repoRoot, evidenceRoot } = await roots();
    const seen: string[][] = [];
    const releaseManifest = manifest();
    releaseManifest.required[0].steps[0].command = ["tool", "$RISHI_RELEASE_ROOT/output", "$RISHI_RELEASE_SHA"];
    await runRelease({ manifest: releaseManifest, repoRoot, evidenceRoot, sha }, dependencies({
      runStep: async (step, context) => {
        seen.push(step.command);
        await mkdir(join(context.evidenceRoot, "normalized"), { recursive: true });
        await writeFile(join(context.evidenceRoot, step.result), JSON.stringify({ version: 1, format: step.format, exitCode: 0, evidence: { discovered: 1, passed: 1, failed: 0, skipped: 0 } }));
        if (step.id === "apple.tests") await writeAcceptanceEvidence(context.evidenceRoot);
      },
    }));
    expect(seen[0]).toEqual(["tool", join(evidenceRoot, "output"), sha]);
  });

  test("rejects unknown step argv placeholders before spawning", async () => {
    const { repoRoot, evidenceRoot } = await roots();
    const releaseManifest = manifest();
    releaseManifest.required[0].steps[0].command = ["tool", "$UNKNOWN_PLACEHOLDER"];
    let ran = false;
    await expect(runRelease({ manifest: releaseManifest, repoRoot, evidenceRoot, sha }, dependencies({ runStep: async () => { ran = true; } }))).rejects.toThrow(/unknown.*placeholder/i);
    expect(ran).toBe(false);
  });

  test("manifest Apple command cannot mask an earlier command failure", async () => {
    const value = JSON.parse(await readFile(join(import.meta.dir, "../../apps/apple/docs/superpowers/reviews/shared-reading-release-required-tests.json"), "utf8"));
    const command = value.required.find((entry: { category: string }) => entry.category === "Apple UI acceptance").command as string;
    expect(command).toMatch(/set -euo pipefail|&&/);
    const afterStrictPrefix = command.replace(/^\s*set -euo pipefail;\s*/, "");
    expect(afterStrictPrefix).not.toMatch(/;\s*xcodebuild|;\s*apps\/apple/);
  });

  test("rejects a dirty worktree before executing a step", async () => {
    const { repoRoot, evidenceRoot } = await roots();
    let ran = false;
    await expect(runRelease({ manifest: manifest(), repoRoot, evidenceRoot, sha }, dependencies({ worktreeStatus: async () => " M tracked.ts", runStep: async () => { ran = true; } }))).rejects.toThrow(/clean worktree/);
    expect(ran).toBe(false);
  });

  test("requires the evidence root outside the repository", async () => {
    const { repoRoot } = await roots();
    await expect(runRelease({ manifest: manifest(), repoRoot, evidenceRoot: join(repoRoot, "evidence"), sha }, dependencies())).rejects.toThrow(/outside repository/);
  });

  test("rejects missing, zero-discovery, skipped, and failed normalized results", async () => {
    for (const evidence of [undefined, { discovered: 0, passed: 0, failed: 0, skipped: 0 }, { discovered: 1, passed: 0, failed: 0, skipped: 1 }, { discovered: 1, passed: 0, failed: 1, skipped: 0 }]) {
      const { repoRoot, evidenceRoot } = await roots();
      const runStep: ReleaseRunDependencies["runStep"] = async (step, context) => {
        if (evidence === undefined) return;
        await mkdir(join(context.evidenceRoot, "normalized"), { recursive: true });
        await writeFile(join(context.evidenceRoot, step.result), JSON.stringify({ version: 1, format: step.format, exitCode: 0, evidence }));
      };
      await expect(runRelease({ manifest: manifest(), repoRoot, evidenceRoot, sha }, dependencies({ runStep }))).rejects.toThrow(/normalized|discovered|skipped|failed/);
    }
  });

  test("uses actual normalized discovery counts instead of manifest ID counts", async () => {
    const { repoRoot, evidenceRoot } = await roots();
    await runRelease({ manifest: manifest(), repoRoot, evidenceRoot, sha }, dependencies());
    const artifact = JSON.parse(await readFile(join(evidenceRoot, "worker.json"), "utf8"));
    expect(artifact).toMatchObject({ discovered: 3, passed: 3, failed: 0, skipped: 0 });
    expect(artifact.discovered).not.toBe(artifact.testIds.length);
  });

  test("rejects a changed final HEAD or newly dirty worktree", async () => {
    for (const mode of ["head", "dirty"] as const) {
      const { repoRoot, evidenceRoot } = await roots();
      let headCalls = 0;
      let statusCalls = 0;
      const deps = dependencies({
        gitHead: async () => mode === "head" && ++headCalls > 1 ? otherSha : sha,
        worktreeStatus: async () => mode === "dirty" && ++statusCalls > 1 ? "?? generated" : "",
      });
      await expect(runRelease({ manifest: manifest(), repoRoot, evidenceRoot, sha }, deps)).rejects.toThrow(/HEAD changed|worktree became dirty/);
    }
  });
});
