import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { verifyRelease, type ReleaseManifest, type VerificationDependencies } from "./verify-shared-reading-release";

const temporaryDirectories: string[] = [];
const sha = "a".repeat(40);
const mcpTools = ["list_app_instances", "memory_snapshot", "start_app", "stop_app", "inspect_app_state", "select_book", "send_reader_action", "create_reading_session", "join_reading_session", "wait_for_participant", "click_text", "capture_screenshot"];

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

type FixtureOptions = {
  omit?: string;
  mutate?: (artifact: Record<string, unknown>, id: string) => void;
  mutateNormalized?: (normalized: Record<string, unknown>, id: string) => void;
  mutateE2e?: (evidence: Record<string, unknown>) => void;
};

function hashed(value: Record<string, unknown>): Record<string, unknown> {
  return { ...value, contentHash: createHash("sha256").update(stableJson(value)).digest("hex") };
}

async function fixture(options: FixtureOptions = {}) {
  const root = await mkdtemp(join(tmpdir(), "verify-shared-reading-release-test-"));
  temporaryDirectories.push(root);
  const entries = [
    ["worker", "Worker", [{ id: "worker.test", kind: "test", format: "vitest-json" }, { id: "worker.type-check", kind: "check", format: "command" }]],
    ["sharing-worker", "sharing-worker", [{ id: "sharing-worker.test", kind: "test", format: "vitest-json" }, { id: "sharing-worker.type-check", kind: "check", format: "command" }]],
    ["swift-mcp", "Swift MCP", [{ id: "swift-mcp.build", kind: "check", format: "command" }, { id: "swift-mcp.test", kind: "test", format: "swift-output" }]],
    ["swift-e2e-host", "Swift E2E host", [{ id: "swift-e2e-host.build", kind: "check", format: "command" }, { id: "swift-e2e-host.test", kind: "test", format: "swift-output" }]],
    ["apple-ui", "Apple UI acceptance", [{ id: "apple-ui.iphone", kind: "test", format: "xcresult" }, { id: "apple-ui.catalyst", kind: "test", format: "xcresult" }, { id: "apple-ui.acceptance", kind: "check", format: "command" }]],
  ] as const;
  const manifest: ReleaseManifest = {
    version: 1,
    required: entries.map(([id, category, steps]) => ({
      id,
      category,
      command: category === "Apple UI acceptance" ? "set -euo pipefail; first && second && acceptance" : `command-${id}`,
      artifact: `${id}.json`,
      testIds: steps.map((step) => step.id),
      steps: steps.map((step) => ({ ...step, cwd: ".", command: [`command-${step.id}`], result: `normalized/${step.id}.json`, ...(step.format === "xcresult" ? { xcresult: `${step.id}.xcresult` } : {}) })),
      ...(category === "Apple UI acceptance" ? { auxiliary: ["apple-ui.iphone.xcresult", "apple-ui.catalyst.xcresult", "shared-reading-mcp-evidence.json", "shared-reading-apple-e2e-evidence.json"] } : {}),
    })),
  };
  for (const [id, category, steps] of entries) {
    if (options.omit === id) continue;
    const manifestEntry = manifest.required.find((entry) => entry.id === id)!;
    const results: Record<string, unknown>[] = [];
    const totals = { discovered: 0, passed: 0, failed: 0, skipped: 0 };
    for (const step of manifestEntry.steps) {
      const normalized: Record<string, unknown> = { version: 1, format: step.format, exitCode: 0 };
      if (step.kind === "test") {
        normalized.evidence = { discovered: 1, passed: 1, failed: 0, skipped: 0 };
        totals.discovered += 1;
        totals.passed += 1;
      }
      options.mutateNormalized?.(normalized, step.id);
      if (step.kind === "test") {
        const evidence = normalized.evidence as Record<string, number>;
        totals.discovered += evidence.discovered - 1;
        totals.passed += evidence.passed - 1;
        totals.failed += evidence.failed;
        totals.skipped += evidence.skipped;
      }
      const raw = JSON.stringify(normalized, null, 2) + "\n";
      await mkdir(join(root, "normalized"), { recursive: true });
      await writeFile(join(root, step.result), raw);
      results.push({ id: step.id, kind: step.kind, format: step.format, path: step.result, sha256: createHash("sha256").update(raw).digest("hex"), ...(step.kind === "test" ? normalized.evidence as Record<string, number> : {}) });
    }
    const artifact: Record<string, unknown> = {
      version: 2,
      id,
      category,
      command: manifest.required.find((entry) => entry.id === id)!.command,
      sha,
      testIds: manifest.required.find((entry) => entry.id === id)!.testIds,
      ...totals,
      startedAt: "2026-09-16T10:00:00.000Z",
      finishedAt: "2026-09-16T10:00:01.000Z",
      exitCode: 0,
      results,
      auxiliary: [],
    };
    if (id === "apple-ui") {
      await writeFile(join(root, "apple-ui.iphone.xcresult"), "iphone xcresult fixture\n");
      await writeFile(join(root, "apple-ui.catalyst.xcresult"), "catalyst xcresult fixture\n");
      const calls = mcpTools.map((tool, index) => ({ index, tool, target: tool === "start_app" || tool === "stop_app" ? "catalyst" : "host", arguments: {}, success: true, label: "stable" }));
      calls.push({ index: calls.length, tool: "start_app", target: "iphone17", arguments: {}, success: true, label: "stable" });
      calls.push({ index: calls.length, tool: "stop_app", target: "iphone17", arguments: {}, success: true, label: "stable" });
      const mcp = hashed({ version: 1, sha, targets: ["catalyst", "iphone17"], calls, cleanup: { zeroInstances: true, memoryChecked: true }, redaction: { version: 1, arbitraryTextStored: false } });
      const e2e: Record<string, unknown> = { version: 1, sha, targets: ["catalyst", "iphone17"], failed: 0, assertions: ["owner-create-share", "participant-join", "progress-sync", "owner-end", "rejoin-invalidation", "library-interaction"].map((assertionId) => ({ id: assertionId, passed: true })) };
      options.mutateE2e?.(e2e);
      const hashedE2e = hashed(e2e);
      await writeFile(join(root, "shared-reading-mcp-evidence.json"), JSON.stringify(mcp, null, 2) + "\n");
      await writeFile(join(root, "shared-reading-apple-e2e-evidence.json"), JSON.stringify(hashedE2e, null, 2) + "\n");
      artifact.auxiliary = [];
      for (const path of ["apple-ui.iphone.xcresult", "apple-ui.catalyst.xcresult", "shared-reading-mcp-evidence.json", "shared-reading-apple-e2e-evidence.json"]) artifact.auxiliary.push({ path, sha256: createHash("sha256").update(await readFile(join(root, path))).digest("hex") });
    }
    options.mutate?.(artifact, id);
    artifact.contentHash = createHash("sha256").update(stableJson(Object.fromEntries(Object.entries(artifact).filter(([key]) => key !== "contentHash")))).digest("hex");
    await writeFile(join(root, `${id}.json`), JSON.stringify(artifact, null, 2) + "\n");
  }
  return { root, manifest };
}

const noCommands: VerificationDependencies = { gitHead: async () => sha, worktreeStatus: async () => "" };

describe("verify-shared-reading-release", () => {
  test("requires a clean worktree before verification", async () => {
    const { root, manifest } = await fixture();
    const dependencies = { gitHead: async () => sha, worktreeStatus: async () => " M unrelated.txt" } as VerificationDependencies;
    await expect(verifyRelease({ manifest, evidenceRoot: root, sha, repoRoot: "/repo" }, dependencies)).rejects.toThrow(/clean worktree/i);
  });

  test("requires a clean worktree after verification", async () => {
    const { root, manifest } = await fixture();
    let statusCalls = 0;
    const dependencies = {
      gitHead: async () => sha,
      worktreeStatus: async () => ++statusCalls === 1 ? "" : "?? generated.txt",
    } as VerificationDependencies;
    await expect(verifyRelease({ manifest, evidenceRoot: root, sha, repoRoot: "/repo" }, dependencies)).rejects.toThrow(/worktree became dirty/i);
    expect(statusCalls).toBe(2);
  });

  test("accepts the complete five-category release evidence set", async () => {
    const { root, manifest } = await fixture();
    await expect(verifyRelease({ manifest, evidenceRoot: root, sha }, noCommands)).resolves.toMatchObject({ ok: true });
  });

  test.each([
    ["missing manifest entry", async () => fixture({ mutate: (artifact, id) => { if (id === "worker") artifact.testIds = []; } }), /malformed|stale/],
    ["missing artifact", async () => fixture({ omit: "worker" }), /missing.*artifact/],
    ["zero discovery", async () => fixture({ mutateNormalized: (normalized, id) => { if (id === "worker.test") (normalized.evidence as Record<string, number>).discovered = 0; } }), /normalized test evidence|discovered/],
    ["skipped test", async () => fixture({ mutateNormalized: (normalized, id) => { if (id === "worker.test") { const evidence = normalized.evidence as Record<string, number>; evidence.passed = 0; evidence.skipped = 1; } } }), /normalized test evidence|skipped/],
    ["failed test", async () => fixture({ mutateNormalized: (normalized, id) => { if (id === "worker.test") { const evidence = normalized.evidence as Record<string, number>; evidence.passed = 0; evidence.failed = 1; } } }), /failed/],
    ["nonzero command", async () => fixture({ mutateNormalized: (normalized, id) => { if (id === "worker.type-check") normalized.exitCode = 1; } }), /failed normalized/],
    ["stale SHA", async () => fixture({ mutate: (artifact, id) => { if (id === "worker") artifact.sha = "b".repeat(40); } }), /malformed|stale/],
    ["malformed artifact", async () => fixture({ mutate: (artifact, id) => { if (id === "worker") delete artifact.startedAt; } }), /malformed/],
    ["missing xcresult", async () => fixture({ mutate: (artifact, id) => { if (id === "apple-ui") (artifact.auxiliary as Array<Record<string, unknown>>)[0].path = "missing.xcresult"; } }), /xcresult/],
    ["failed E2E assertion", async () => fixture({ mutateE2e: (evidence) => { evidence.failed = 1; } }), /E2E/],
  ] as const)("rejects %s", async (_name, makeFixture, expected) => {
    const { root, manifest } = await makeFixture();
    await expect(verifyRelease({ manifest, evidenceRoot: root, sha }, noCommands)).rejects.toThrow(expected);
  });

  test("rejects duplicate globally unique test IDs and hash-mismatched xcresults", async () => {
    const duplicate = await fixture();
    duplicate.manifest.required[1].testIds = ["worker.test"];
    duplicate.manifest.required[1].steps[0].id = "worker.test";
    await expect(verifyRelease({ manifest: duplicate.manifest, evidenceRoot: duplicate.root, sha }, noCommands)).rejects.toThrow(/duplicate/);

    const hash = await fixture({ mutate: (artifact, id) => { if (id === "apple-ui") (artifact.auxiliary as Array<Record<string, unknown>>)[0].sha256 = "c".repeat(64); } });
    await expect(verifyRelease({ manifest: hash.manifest, evidenceRoot: hash.root, sha }, noCommands)).rejects.toThrow(/hash/);
  });
});
