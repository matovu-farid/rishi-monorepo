import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
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
  mutateMcp?: (evidence: Record<string, unknown>) => void;
  mutateE2e?: (evidence: Record<string, unknown>) => void;
};

function hashed(value: Record<string, unknown>): Record<string, unknown> {
  return { ...value, contentHash: createHash("sha256").update(stableJson(value)).digest("hex") };
}

function swapMcpCalls(evidence: Record<string, unknown>, first: (call: Record<string, unknown>) => boolean, second: (call: Record<string, unknown>) => boolean): void {
  const calls = evidence.calls as Array<Record<string, unknown>>;
  const firstIndex = calls.findIndex(first);
  const secondIndex = calls.findIndex(second);
  [calls[firstIndex], calls[secondIndex]] = [calls[secondIndex], calls[firstIndex]];
}

async function fixture(options: FixtureOptions = {}) {
  const root = await mkdtemp(join(tmpdir(), "verify-shared-reading-release-test-"));
  temporaryDirectories.push(root);
  const entries = [
    ["worker", "Worker", [{ id: "worker.test", kind: "test", format: "vitest-json" }, { id: "worker.type-check", kind: "check", format: "command" }]],
    ["sharing-worker", "sharing-worker", [{ id: "sharing-worker.test", kind: "test", format: "vitest-json" }, { id: "sharing-worker.type-check", kind: "check", format: "command" }]],
    ["swift-mcp", "Swift MCP", [{ id: "swift-mcp.build", kind: "check", format: "command" }, { id: "swift-mcp.test", kind: "test", format: "swift-output" }]],
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
      const calls: Array<Record<string, unknown>> = [
        { tool: "list_app_instances", target: "host", arguments: {}, success: true, label: "initial-instances", observedInstanceCount: 0 },
        { tool: "start_app", target: "catalyst", arguments: { app: "catalyst" }, success: true, label: "stable" },
        { tool: "start_app", target: "iphone17", arguments: { app: "iphone17" }, success: true, label: "stable" },
        { tool: "list_app_instances", target: "host", arguments: {}, success: true, label: "running-instances", observedInstanceCount: 2 },
        ...mcpTools.filter((tool) => !["list_app_instances", "start_app", "stop_app"].includes(tool)).map((tool) => ({ tool, target: "host", arguments: {}, success: true, label: "stable" })),
        { tool: "stop_app", target: "catalyst", arguments: { app: "catalyst" }, success: true, label: "stable" },
        { tool: "stop_app", target: "iphone17", arguments: { app: "iphone17" }, success: true, label: "stable" },
        { tool: "list_app_instances", target: "host", arguments: {}, success: true, label: "final-instances", observedInstanceCount: 0 },
      ].map((call, index) => ({ index, ...call }));
      const mcpEvidence: Record<string, unknown> = { version: 1, sha, targets: ["catalyst", "iphone17"], peakInstances: 2, calls, cleanup: { zeroInstances: true, memoryChecked: true }, redaction: { version: 1, arbitraryTextStored: false } };
      options.mutateMcp?.(mcpEvidence);
      const mcp = hashed(mcpEvidence);
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

  test("accepts the complete four-category release evidence set", async () => {
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

  test.each([
    ["a peak instance count other than two", (evidence: Record<string, unknown>) => { evidence.peakInstances = 1; }],
    ["duplicate owner starts", (evidence: Record<string, unknown>) => { const calls = evidence.calls as Array<Record<string, unknown>>; calls.push({ ...calls.find((call) => call.tool === "start_app" && call.target === "catalyst"), index: calls.length }); }],
    ["duplicate participant stops", (evidence: Record<string, unknown>) => { const calls = evidence.calls as Array<Record<string, unknown>>; calls.push({ ...calls.find((call) => call.tool === "stop_app" && call.target === "iphone17"), index: calls.length }); }],
    ["a target/argument mismatch on participant start", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.tool === "start_app" && item.target === "iphone17")!; call.arguments = { app: "catalyst" }; }],
    ["a missing participant stop", (evidence: Record<string, unknown>) => { evidence.calls = (evidence.calls as Array<Record<string, unknown>>).filter((call) => !(call.tool === "stop_app" && call.target === "iphone17")); }],
    ["a missing initial observation", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "initial-instances")!; call.label = "stable"; }],
    ["a mislabeled running observation", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "running-instances")!; call.tool = "memory_snapshot"; }],
    ["a failed final observation", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "final-instances")!; call.success = false; }],
    ["a duplicate initial observation", (evidence: Record<string, unknown>) => { const calls = evidence.calls as Array<Record<string, unknown>>; calls.push({ ...calls.find((call) => call.label === "initial-instances"), index: calls.length }); }],
    ["a wrong initial observed count", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "initial-instances")!; call.observedInstanceCount = 1; }],
    ["a wrong running observed count", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "running-instances")!; call.observedInstanceCount = 1; }],
    ["a wrong final observed count", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "final-instances")!; call.observedInstanceCount = 2; }],
    ["a missing observed count", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "running-instances")!; delete call.observedInstanceCount; }],
    ["a malformed observed count", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "final-instances")!; call.observedInstanceCount = "0"; }],
    ["an observed count on an unrelated call", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.tool === "memory_snapshot")!; call.observedInstanceCount = 0; }],
    ["an instance observation targeted at an app", (evidence: Record<string, unknown>) => { const call = (evidence.calls as Array<Record<string, unknown>>).find((item) => item.label === "running-instances")!; call.target = "catalyst"; }],
    ["initial observation after a start", (evidence: Record<string, unknown>) => { swapMcpCalls(evidence, (call) => call.label === "initial-instances", (call) => call.tool === "start_app" && call.target === "catalyst"); }],
    ["running observation before both starts complete", (evidence: Record<string, unknown>) => { swapMcpCalls(evidence, (call) => call.label === "running-instances", (call) => call.tool === "start_app" && call.target === "iphone17"); }],
    ["a stop before the running observation", (evidence: Record<string, unknown>) => { swapMcpCalls(evidence, (call) => call.label === "running-instances", (call) => call.tool === "stop_app" && call.target === "catalyst"); }],
    ["final observation before both stops complete", (evidence: Record<string, unknown>) => { swapMcpCalls(evidence, (call) => call.label === "final-instances", (call) => call.tool === "stop_app" && call.target === "iphone17"); }],
  ] as const)("rejects MCP evidence with %s", async (_name, mutateMcp) => {
    const { root, manifest } = await fixture({ mutateMcp });
    await expect(verifyRelease({ manifest, evidenceRoot: root, sha }, noCommands)).rejects.toThrow(/MCP|instance|observation|start|stop/i);
  });
});

describe("run-shared-reading-acceptance wrapper", () => {
  async function wrapperHarness(fakeHead = sha) {
    const root = await mkdtemp(join(tmpdir(), "shared-reading-wrapper-test-"));
    temporaryDirectories.push(root);
    const fakeBin = join(root, "bin");
    const evidenceRoot = join(root, "evidence");
    const repoRoot = resolve(import.meta.dir, "../..");
    await mkdir(fakeBin, { recursive: true });
    await mkdir(evidenceRoot);
    const gitLog = join(root, "git.log");
    const bunMarker = join(root, "bun-ran");
    const fakeGit = `#!/bin/sh\nprintf '%s\\n' "$*" >> "$TEST_GIT_LOG"\ncase "$*" in\n  "-C $TEST_REPO_ROOT rev-parse --show-toplevel") printf '%s\\n' "$TEST_REPO_ROOT" ;;\n  "-C $TEST_REPO_ROOT rev-parse HEAD") printf '%s\\n' "$TEST_HEAD" ;;\n  *) exit 90 ;;\nesac\n`;
    const fakeBun = `#!/bin/sh\nprintf '%s\\n' "$*" > "$TEST_BUN_MARKER"\nexit 0\n`;
    await writeFile(join(fakeBin, "git"), fakeGit);
    await writeFile(join(fakeBin, "bun"), fakeBun);
    await chmod(join(fakeBin, "git"), 0o755);
    await chmod(join(fakeBin, "bun"), 0o755);
    const mcpBinary = join(root, "mcp-binary");
    const mcpClient = join(root, "mcp-client.ts");
    await writeFile(mcpBinary, "fixture binary");
    await chmod(mcpBinary, 0o755);
    await writeFile(mcpClient, "// fixture client\n");
    return {
      root,
      evidenceRoot,
      repoRoot,
      gitLog,
      bunMarker,
      mcpBinary,
      mcpClient,
      fakeHead,
      script: resolve(import.meta.dir, "../../apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh"),
    };
  }

  async function invoke(harness: Awaited<ReturnType<typeof wrapperHarness>>, requestedSha = sha) {
    const child = Bun.spawn(["/bin/zsh", harness.script,
      "--mcp-binary", harness.mcpBinary,
      "--mcp-client", harness.mcpClient,
      "--owner", "catalyst",
      "--participant", "iphone17",
      "--sync-timeout-ms", "120000",
      "--sha", requestedSha,
      "--evidence-root", harness.evidenceRoot,
    ], {
      env: {
        ...process.env,
        PATH: `${join(harness.root, "bin")}:${process.env.PATH ?? ""}`,
        TEST_GIT_LOG: harness.gitLog,
        TEST_BUN_MARKER: harness.bunMarker,
        TEST_REPO_ROOT: harness.repoRoot,
        TEST_HEAD: harness.fakeHead,
        RISHI_E2E_BOOK_IDENTIFIER: "fixture-book",
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    const stdout = await new Response(child.stdout).text();
    const stderr = await new Response(child.stderr).text();
    return { exitCode: await child.exited, stdout, stderr };
  }

  test("rejects a requested SHA that is not the repository HEAD before running the client", async () => {
    const harness = await wrapperHarness("b".repeat(40));
    const result = await invoke(harness);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toMatch(/SHA.*HEAD|HEAD.*SHA/i);
    await expect(readFile(harness.bunMarker)).rejects.toThrow();
    expect(await readFile(harness.gitLog, "utf8")).toContain(`-C ${harness.repoRoot} rev-parse HEAD`);
  });

  test.each(["shared-reading-mcp-evidence.json", "shared-reading-apple-e2e-evidence.json"])("rejects a pre-existing %s before running the client", async (filename) => {
    const harness = await wrapperHarness();
    await writeFile(join(harness.evidenceRoot, filename), "existing evidence\n");
    const result = await invoke(harness);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain(filename);
    await expect(readFile(harness.bunMarker)).rejects.toThrow();
  });

  test("rejects a dangling evidence symlink rather than treating it as absent", async () => {
    const harness = await wrapperHarness();
    const destination = join(harness.evidenceRoot, "shared-reading-mcp-evidence.json");
    await symlink(join(harness.root, "not-created.json"), destination);
    const result = await invoke(harness);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("shared-reading-mcp-evidence.json");
    await expect(readFile(harness.bunMarker)).rejects.toThrow();
  });

  test("uses the script-derived repository root and runs only after an exact HEAD check", async () => {
    const harness = await wrapperHarness();
    const result = await invoke(harness);
    expect(result.exitCode).toBe(0);
    const gitCalls = await readFile(harness.gitLog, "utf8");
    expect(gitCalls).toContain(`-C ${harness.repoRoot} rev-parse --show-toplevel`);
    expect(gitCalls).toContain(`-C ${harness.repoRoot} rev-parse HEAD`);
    expect(await readFile(harness.bunMarker, "utf8")).toContain(harness.mcpClient);
  });
});
