import { afterEach, describe, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, readdir, rename, rm, symlink, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertNoBuildInfrastructureDiagnostics, collectDescendantPids, exerciseVerificationLocksForTest, mergeBoundedProcessIdentities, parseNodeTap, parseProcessIdentityTable, parseSwiftOutput, parseVitestJson, parseXcresultSummary, posixLibcPathForPlatform, processSnapshotEnvironment, productionLaneLockPath, readBounded, resolveOutputStreamLimit, sampleDescendantsWhileRunning, sampleSessionIdentities, sendPosixSignal, sessionMemberIdentities, terminateProcessGroupMembers, validateCodexJsonl, validateEvidence, validateObservedProcessIdentities, validateSessionSignalMembers, writeContainedFile } from "./run-verified";

const runner = join(import.meta.dir, "run-verified.ts");
const temporaryDirectories: string[] = [];
const darwinTest = process.platform === "darwin" ? test : test.skip;
const vitestWriter = (payload: string) => `const path = process.argv.find((value) => value.startsWith("--outputFile="))?.slice("--outputFile=".length); if (!path) process.exit(9); await Bun.write(path, ${JSON.stringify(payload)});`;

function xcresultSummary(overrides: Record<string, unknown> = {}) {
  return {
    title: "Test - rishi",
    environmentDescription: "rishi · macOS 26.0",
    topInsights: [],
    result: "Failed",
    totalTestCount: 1,
    passedTests: 0,
    failedTests: 1,
    skippedTests: 0,
    expectedFailures: 0,
    statistics: [],
    devicesAndConfigurations: {
      device: { deviceId: "device", deviceName: "iPhone 17 Pro", architecture: "arm64", modelName: "iPhone", osVersion: "26.0" },
      testPlanConfiguration: { configurationId: "1", configurationName: "Test Action" },
      passedTests: 0, failedTests: 1, skippedTests: 0, expectedFailures: 0,
    },
    testFailures: [{ testName: "test", targetName: "rishiTests", failureText: "failed", testIdentifier: 1, testIdentifierString: "Module.Class/test" }],
    runtimeWarnings: [],
    ...overrides,
  };
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function selfDigestedResource(overrides: Record<string, unknown> = {}) {
  const unsigned = {
    version: 1,
    sampledAt: new Date().toISOString(),
    platform: "darwin",
    target: "rishi",
    availableMemoryGiB: 8,
    freeDiskGiB: 32,
    thresholds: { minAvailableMemoryGiB: 4, minFreeDiskGiB: 16 },
    processInventory: [],
    lockInventory: [],
    ...overrides,
  };
  return { ...unsigned, digest: createHash("sha256").update(stableJson(unsigned)).digest("hex") };
}

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "run-verified-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

function terminateIfAlive(pid: number): void {
  if (!Number.isInteger(pid) || pid <= 0) return;
  sendPosixSignal(pid, "SIGKILL");
}

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function run(arguments_: string[], environment?: Record<string, string | undefined>) {
  const process_ = Bun.spawn([process.execPath, runner, ...arguments_], { stdout: "pipe", stderr: "pipe", ...(environment ? { env: environment } : {}) });
  return {
    exitCode: await process_.exited,
    stdout: await new Response(process_.stdout).text(),
    stderr: await new Response(process_.stderr).text(),
  };
}

async function waitForFile(path: string, timeoutMs = 2_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await readFile(path, "utf8").catch(() => undefined);
    if (value !== undefined) return value;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for fixture file: ${path}`);
}

function continuousOutputFixture(statePath: string): string {
  return `const { dlopen, FFIType } = await import("bun:ffi"); const { getsid } = dlopen(${JSON.stringify(posixLibcPathForPlatform())}, { getsid: { args: [FFIType.i32], returns: FFIType.i32 } }).symbols; await Bun.write(${JSON.stringify(statePath)}, JSON.stringify({ pid: process.pid, sessionId: getsid(0) })); const chunk = "x".repeat(4096); while (true) process.stdout.write(chunk)`;
}

async function stopFixtureSession(statePath: string): Promise<void> {
  const state = JSON.parse(await readFile(statePath, "utf8").catch(() => "{}")) as { pid?: number; sessionId?: number };
  if (Number.isInteger(state.sessionId) && state.sessionId! > 0) sendPosixSignal(-state.sessionId!, "SIGKILL");
  terminateIfAlive(state.pid ?? 0);
}

describe("run-verified", () => {
  test("accepts Vitest JSON evidence and writes a normalized artifact", async () => {
    const directory = await temporaryDirectory();
    const artifact = join(directory, "artifact.json");
    const result = await run([
      "--format", "vitest-json", "--expect", "pass", "--cwd", directory, "--artifact", artifact, "--", process.execPath, "-e",
      vitestWriter(JSON.stringify({ numTotalTests: 2, numPassedTests: 2, numPendingTests: 0, numTodoTests: 0, numFailedTests: 0, testResults: [] })), "--",
    ]);

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(await readFile(artifact, "utf8"))).toMatchObject({
      format: "vitest-json", evidence: { discovered: 2, passed: 2, skipped: 0, failed: 0 },
      command: process.execPath, cwd: directory,
    });
  });

  test("rejects a passing expected-red command", async () => {
    const directory = await temporaryDirectory();
    const result = await run([
      "command", "--artifact", join(directory, "artifact.json"), "--expected-red", "--", process.execPath, "-e", "process.exit(0)",
    ]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("expected-red");
  });

  test("requires every requested failing Vitest ID", async () => {
    const directory = await temporaryDirectory();
    const payload = JSON.stringify({
      numTotalTests: 2, numPassedTests: 1, numPendingTests: 0, numFailedTests: 1,
      testResults: [{ assertionResults: [
        { fullName: "math adds", status: "passed" }, { fullName: "math subtracts", status: "failed" },
      ] }],
    });
    const result = await run([
      "--format", "vitest-json", "--expect", "fail", "--cwd", directory, "--artifact", join(directory, "artifact.json"),
      "--require-failure-id", "math subtracts", "--require-failure-id", "math adds", "--",
      process.execPath, "-e", `${vitestWriter(payload)}; process.exit(1)`, "--",
    ]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("math adds");
  });

  test("rejects TAP skips and malformed JSONL", async () => {
    const directory = await temporaryDirectory();
    const tap = await run([
      "node-test", "--artifact", join(directory, "tap.json"), "--", process.execPath, "-e", "console.log('TAP version 13\\n1..1\\nok 1 - skipped # SKIP nope')",
    ]);
    const jsonl = await run([
      "codex-jsonl", "--artifact", join(directory, "jsonl.json"), "--raw-output", join(directory, "raw.jsonl"), "--", process.execPath, "-e", "process.stdout.write('{')",
    ]);
    expect(tap.exitCode).not.toBe(0);
    expect(jsonl.exitCode).not.toBe(0);
  });

  test("parses Node TAP from stdout only", async () => {
    const directory = await temporaryDirectory();
    const result = await run([
      "node-test", "--artifact", join(directory, "tap.json"), "--", process.execPath, "-e",
      "process.stdout.write('TAP version 13\\n1..1\\nok 1 - incomplete\\n'); process.stderr.write('# tests 1\\n# pass 1\\n# fail 0\\n')",
    ]);
    expect(result.exitCode).not.toBe(0);
  });

  test("rejects self-digested resource artifacts that do not meet caller expectations", async () => {
    const directory = await temporaryDirectory();
    const command = ["command", "--artifact", join(directory, "run.json"), "--resource-artifact", join(directory, "resource.json"), "--expected-resource-target", "rishi", "--min-available-memory-gib", "4", "--min-free-disk-gib", "16", "--", process.execPath, "-e", "process.exit(0)"];
    await writeFile(join(directory, "resource.json"), `${JSON.stringify(selfDigestedResource())}\n`);
    expect((await run(command)).exitCode).toBe(0);
    const cases = [
      selfDigestedResource({ thresholds: undefined }),
      selfDigestedResource({ thresholds: {} }),
      selfDigestedResource({ thresholds: { minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 } }),
      selfDigestedResource({ target: "other" }),
    ];
    for (const resource of cases) {
      await writeFile(join(directory, "resource.json"), `${JSON.stringify(resource)}\n`);
      expect((await run(command)).exitCode).not.toBe(0);
    }
  });

  test("rejects impossible Swift arithmetic", async () => {
    const directory = await temporaryDirectory();
    const result = await run([
      "swift-output", "--artifact", join(directory, "swift.json"), "--", process.execPath, "-e",
      "console.log('Executed 1 test, with 3 failures')",
    ]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("malformed");
  });

  test("rejects impossible arithmetic for every normalized test-evidence format", () => {
    expect(() => validateEvidence(parseVitestJson(JSON.stringify({ numTotalTests: 1, numPassedTests: 2, numPendingTests: 0, numTodoTests: 0, numFailedTests: 0, testResults: [] })), false, [])).toThrow("malformed");
    expect(() => validateEvidence(parseNodeTap("TAP version 13\n1..1\nok 1 - one\n# tests 1\n# pass 2\n# fail 0\n"), false, [])).toThrow("malformed");
    expect(() => parseSwiftOutput("Executed 1 test, with 3 failures")).toThrow("malformed");
    expect(() => validateEvidence(parseXcresultSummary(JSON.stringify(xcresultSummary({ totalTestCount: 1, passedTests: 2, failedTests: 0, testFailures: [] }))), false, [])).toThrow("malformed");
  });

  test("requires the complete xcresult 0.4 summary and TestFailure schema", () => {
    expect(() => parseXcresultSummary(JSON.stringify(xcresultSummary()))).not.toThrow();
    for (const malformed of [
      xcresultSummary({ title: undefined }),
      xcresultSummary({ result: "Maybe" }),
      xcresultSummary({ topInsights: [{}] }),
      xcresultSummary({ devicesAndConfigurations: [{}] }),
      xcresultSummary({ runtimeWarnings: [{}] }),
      xcresultSummary({ testFailures: [{ testIdentifierString: "Module.Class/test" }] }),
    ]) expect(() => parseXcresultSummary(JSON.stringify(malformed))).toThrow("malformed");
  });

  test("rejects stale xcresult evidence and compile/link failures before expected-red acceptance", async () => {
    const directory = await temporaryDirectory();
    const xcrun = join(directory, "xcrun");
    const summary = JSON.stringify(xcresultSummary());
    await writeFile(xcrun, `#!/bin/sh\n[ -s "$RUN_VERIFIED_LOCK_PATH" ] || exit 88\nif [ -n "$MUTATE_XCRESULT" ]; then printf 'changed' >> "$MUTATE_XCRESULT/payload"; fi\nprintf '%s\\n' '${summary}'\n`);
    await chmod(xcrun, 0o700);
    const environment = { ...process.env, PATH: `${directory}:${process.env.PATH ?? ""}`, RUN_VERIFIED_LOCK_PATH: join(directory, ".run-verified.lock") };

    const stale = join(directory, "stale.xcresult");
    await mkdir(stale);
    const staleResult = await run([
      "xcresult", "--artifact", join(directory, "stale.json"), "--xcresult", stale,
      "--expected-red", "--require-failure-id", "Module.Class/test", "--",
      process.execPath, "-e", "process.exit(1)", "--", "-resultBundlePath", stale,
    ], environment);
    expect(staleResult.exitCode).not.toBe(0);
    expect(staleResult.stderr).toContain("must not exist");

    for (const diagnostic of [
      "/tmp/Subject.swift:12:3: error: cannot find 'missing' in scope\n** BUILD FAILED **\n",
      "clang: error: linker command failed with exit code 1\n",
    ]) {
      const resultPath = join(directory, `fresh-${crypto.randomUUID()}.xcresult`);
      const command = `await (await import('node:fs/promises')).mkdir(${JSON.stringify(resultPath)}); process.stderr.write(${JSON.stringify(diagnostic)}); process.exit(65)`;
      const result = await run([
        "xcresult", "--artifact", join(directory, `${crypto.randomUUID()}.json`), "--xcresult", resultPath,
        "--expected-red", "--require-failure-id", "Module.Class/test", "--",
        process.execPath, "-e", command, "--", "-resultBundlePath", resultPath,
      ], environment);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("infrastructure diagnostics");
    }

    const mutable = join(directory, "mutable.xcresult");
    const mutableCommand = `const fs = await import('node:fs/promises'); await fs.mkdir(${JSON.stringify(mutable)}); await fs.writeFile(${JSON.stringify(join(mutable, "payload"))}, 'original'); process.exit(1)`;
    const mutated = await run([
      "xcresult", "--artifact", join(directory, "mutable.json"), "--xcresult", mutable,
      "--expected-red", "--require-failure-id", "Module.Class/test", "--",
      process.execPath, "-e", mutableCommand, "--", "-resultBundlePath", mutable,
    ], { ...environment, MUTATE_XCRESULT: mutable });
    expect(mutated.exitCode).not.toBe(0);
    expect(mutated.stderr).toContain("bundle tree changed");
  });

  test("classifies representative compile and link diagnostics", () => {
    expect(() => assertNoBuildInfrastructureDiagnostics("SwiftCompile normal arm64 failed\n")).toThrow("infrastructure diagnostics");
    expect(() => assertNoBuildInfrastructureDiagnostics("The following build commands failed:\n\tLd app\n")).toThrow("infrastructure diagnostics");
    expect(() => assertNoBuildInfrastructureDiagnostics("xcodebuild: error: Unable to find a destination\n")).toThrow("infrastructure diagnostics");
    expect(() => assertNoBuildInfrastructureDiagnostics("Test Case '-[Suite test]' failed (0.01 seconds)\n")).not.toThrow();
  });

  test("validates Codex 0.146 lifecycle, todo updates, null arguments, and MCP results", async () => {
    const directory = await temporaryDirectory();
    const events = (extra: object[] = []) => [
      { type: "thread.started", thread_id: "one" },
      { type: "turn.started" },
      { type: "item.started", item: { id: "todo", type: "todo_list", items: [{ text: "Check", completed: false }] } },
      { type: "item.updated", item: { id: "todo", type: "todo_list", items: [{ text: "Check", completed: true }] } },
      { type: "item.started", item: { id: "call", type: "mcp_tool_call", server: "approved", tool: "safe", arguments: null, result: null, error: null, status: "in_progress" } },
      { type: "item.updated", item: { id: "call", type: "mcp_tool_call", server: "approved", tool: "safe", arguments: null, result: null, error: null, status: "in_progress" } },
      { type: "item.completed", item: { id: "call", type: "mcp_tool_call", server: "approved", tool: "safe", arguments: null, result: { content: [{ type: "text", text: "ok" }], structured_content: { ok: true }, _meta: { trace: "one" } }, error: null, status: "completed" } },
      { type: "item.completed", item: { id: "todo", type: "todo_list", items: [{ text: "Check", completed: true }] } },
      ...extra,
      { type: "turn.completed", usage: {} },
    ].map(JSON.stringify).join("\n") + "\n";
    const withoutThread = events().split("\n").slice(1).join("\n");
    const missingThread = await run(["codex-jsonl", "--artifact", join(directory, "missing.json"), "--raw-output", join(directory, "missing.raw"), "--allow-server", "approved", "--require-tool", "safe", "--", process.execPath, "-e", `process.stdout.write(${JSON.stringify(withoutThread)})`]);
    const shell = await run(["codex-jsonl", "--artifact", join(directory, "shell.json"), "--raw-output", join(directory, "shell.raw"), "--allow-server", "approved", "--require-tool", "safe", "--", process.execPath, "-e", `process.stdout.write(${JSON.stringify(events([{ type: "item.completed", item: { id: "shell", type: "command_execution", status: "completed" } }]))})`]);
    const harmless = await run(["codex-jsonl", "--artifact", join(directory, "harmless.json"), "--raw-output", join(directory, "harmless.raw"), "--allow-server", "approved", "--require-tool", "safe", "--", process.execPath, "-e", `process.stdout.write(${JSON.stringify(events())})`]);
    expect(missingThread.exitCode).not.toBe(0);
    expect(shell.exitCode).not.toBe(0);
    expect(harmless.stderr).toBe("");
    expect(harmless.exitCode).toBe(0);
  });

  test("rejects malformed Codex order, mutation, results, and inexact rejection codes", async () => {
    const directory = await temporaryDirectory();
    const invoke = (name: string, rows: object[], extra: string[] = []) => run(["codex-jsonl", "--artifact", join(directory, `${name}.json`), "--raw-output", join(directory, `${name}.raw`), "--allow-server", "approved", "--require-tool", "safe", ...extra, "--", process.execPath, "-e", `process.stdout.write(${JSON.stringify(rows.map(JSON.stringify).join("\n") + "\n")})`]);
    const start = { type: "item.started", item: { id: "call", type: "mcp_tool_call", server: "approved", tool: "safe", arguments: { value: 1 }, result: null, error: null, status: "in_progress" } };
    const complete = (result: unknown = { content: [], structured_content: null }) => ({ type: "item.completed", item: { ...start.item, result, error: null, status: "completed" } });
    const envelope = (middle: object[]) => [{ type: "thread.started", thread_id: "one" }, { type: "turn.started" }, ...middle, { type: "turn.completed", usage: {} }];
    const cases: Array<[string, object[]]> = [
      ["terminal", [...envelope([start, complete()]), { type: "item.completed", item: { id: "late", type: "agent_message", text: "late" } }]],
      ["duplicate-turn", [{ type: "thread.started", thread_id: "one" }, { type: "turn.started" }, { type: "turn.started" }, start, complete(), { type: "turn.completed", usage: {} }]],
      ["mutation", envelope([start, { ...complete(), item: { ...complete().item, tool: "changed" } }])],
      ["primitive-result", envelope([start, complete("ok")])],
      ["missing-content", envelope([start, complete({ structured_content: {} })])],
      ["bad-content", envelope([start, complete({ content: ["text"], structured_content: {} })])],
    ];
    for (const [name, rows] of cases) expect((await invoke(name, rows)).exitCode).not.toBe(0);
    const failed = { type: "item.completed", item: { ...start.item, result: null, error: { message: "INVALID_REQUEST extra" }, status: "failed" } };
    expect((await invoke("substring", envelope([start, failed]), ["--require-rejection", "INVALID_REQUEST"])).exitCode).not.toBe(0);
    const messageOnly = { type: "item.completed", item: { ...start.item, result: null, error: { message: "INVALID_REQUEST" }, status: "failed" } };
    expect((await invoke("message-only", envelope([start, messageOnly]), ["--require-rejection", "safe=INVALID_REQUEST"])).exitCode).toBe(0);
  });

  test("requires the exact correlated MCP error message", () => {
    const events = (message: string) => [
      { type: "thread.started", thread_id: "one" },
      { type: "turn.started" },
      { type: "item.started", item: { id: "call", type: "mcp_tool_call", server: "approved", tool: "safe", arguments: null, result: null, error: null, status: "in_progress" } },
      { type: "item.completed", item: { id: "call", type: "mcp_tool_call", server: "approved", tool: "safe", arguments: null, result: null, error: { message }, status: "failed" } },
      { type: "turn.completed", usage: {} },
    ].map(JSON.stringify).join("\n") + "\n";
    const options = {
      allowedServers: ["approved"], requiredTools: ["safe"], requireRejection: "safe=INVALID_REQUEST",
    };
    expect(() => validateCodexJsonl(new TextEncoder().encode(events("INVALID_REQUEST")), options)).not.toThrow();
    expect(() => validateCodexJsonl(new TextEncoder().encode(events("INVALID_REQUEST extra")), options)).toThrow("required Codex tool result missing");
  });

  test("samples delayed descendants and rejects output paths outside the effective root", async () => {
    const directory = await temporaryDirectory();
    let finish!: () => void;
    const completion = new Promise<void>((resolveCompletion) => { finish = resolveCompletion; });
    let probes = 0;
    const delayed = sampleDescendantsWhileRunning(100, completion, async () => (++probes < 3 ? [] : [200]), 1);
    setTimeout(finish, 5);
    const traversal = await run([
      "command", "--artifact", join(directory, "..", "outside.json"), "--owned-output-root", directory, "--", process.execPath, "-e", "process.exit(0)",
    ]);
    expect(await delayed).toEqual([200]);
    expect(traversal.exitCode).not.toBe(0);
  });

  test("propagates process snapshot failures and malformed process evidence", async () => {
    await expect(collectDescendantPids(100, async () => ({ exitCode: 1, stdout: "", stderr: "ps failed" }))).rejects.toThrow("process snapshot");
    await expect(collectDescendantPids(100, async () => { throw new Error("ps unavailable"); })).rejects.toThrow("ps unavailable");
    await expect(collectDescendantPids(100, async () => ({ exitCode: 0, stdout: "not pid data\n", stderr: "" }))).rejects.toThrow("malformed process snapshot");
    let finish!: () => void;
    const completion = new Promise<void>((resolveCompletion) => { finish = resolveCompletion; });
    const sampled = sampleDescendantsWhileRunning(100, completion, async () => { throw new Error("process snapshot unavailable"); }, 1);
    setTimeout(finish, 5);
    await expect(sampled).rejects.toThrow("process snapshot unavailable");
  });

  test("parses a full Linux process table with kernel and namespace zero identities", () => {
    const rows = parseProcessIdentityTable([
      "0 0 0 I Thu Jan  1 00:00:00 1970 [swapper/0]",
      "1 0 0 Ss Mon Sep 15 12:34:56 2026 /sbin/init",
      "2 0 0 I Mon Sep 15 12:34:56 2026 [kthreadd]",
      "101 1 101 S Mon Sep 15 12:34:56 2026 /usr/bin/xcodebuild",
    ].join("\n") + "\n");
    expect(rows).toEqual([
      { pid: 0, parentPid: 0, processGroupId: 0, state: "I", startTime: "Thu Jan  1 00:00:00 1970", executable: "[swapper/0]" },
      { pid: 1, parentPid: 0, processGroupId: 0, state: "Ss", startTime: "Mon Sep 15 12:34:56 2026", executable: "/sbin/init" },
      { pid: 2, parentPid: 0, processGroupId: 0, state: "I", startTime: "Mon Sep 15 12:34:56 2026", executable: "[kthreadd]" },
      { pid: 101, parentPid: 1, processGroupId: 101, state: "S", startTime: "Mon Sep 15 12:34:56 2026", executable: "/usr/bin/xcodebuild" },
    ]);
  });

  test("keeps the C locale for portable lstart parsing without discarding the caller environment", () => {
    expect(processSnapshotEnvironment({ PATH: "/test/bin", LC_ALL: "de_DE.UTF-8", PRESERVE_ME: "yes" })).toEqual({
      PATH: "/test/bin", LC_ALL: "C", PRESERVE_ME: "yes",
    });
  });

  test("uses the same POSIX libc choice in test fixtures as production", () => {
    expect(posixLibcPathForPlatform("darwin")).toBe("/usr/lib/libSystem.B.dylib");
    expect(posixLibcPathForPlatform("linux")).toBe("libc.so.6");
    expect(posixLibcPathForPlatform("win32")).toBeUndefined();
  });

  test("delivers signals through libc with portable numeric signal constants", () => {
    expect(sendPosixSignal(process.pid, 0)).toBe(true);
    expect(sendPosixSignal(2_147_483_647, "SIGTERM")).toBe(false);
    expect(() => sendPosixSignal(0, "SIGTERM")).toThrow("nonzero process identity");
    expect(() => sendPosixSignal(2_147_483_648, 0)).toThrow("signed 32-bit process identity");
  });

  test("reports a bounded sanitized malformed process-table row", () => {
    const malformed = `101 1 101 S Mon September 15 12:34:56 2026 /usr/bin/xcodebuild ${"x".repeat(512)}`;
    expect(() => parseProcessIdentityTable(`${malformed}\n`)).toThrow(/malformed process identity snapshot row: .{1,256}$/);
    expect(() => parseProcessIdentityTable("\n")).toThrow("malformed process identity snapshot row: <empty>");
  });

  test("proves a snapshotted process exited before treating a failed getsid as benign", async () => {
    const row = { pid: 101, parentPid: 1, processGroupId: 100, state: "S", startTime: "Mon Sep 15 12:34:56 2026", executable: "/bin/short-lived" };
    await expect(sessionMemberIdentities(100, 100, [row], new Map(), {
      sessionIdFor: () => -1,
      resnapshot: async () => [],
    })).resolves.toEqual([]);
    await expect(sessionMemberIdentities(100, 100, [row], new Map(), {
      sessionIdFor: () => -1,
      resnapshot: async () => [row],
    })).rejects.toThrow("unable to verify the POSIX session for live process 101 (S)");
    const knownIdentity = { pid: row.pid, processGroupId: row.processGroupId, sessionId: 100, startTime: row.startTime, executable: row.executable };
    const known = new Map([[`${knownIdentity.pid}\0${knownIdentity.processGroupId}\0${knownIdentity.sessionId}\0${knownIdentity.startTime}\0${knownIdentity.executable}`, knownIdentity]]);
    await expect(sessionMemberIdentities(100, 100, [row], known, {
      sessionIdFor: () => -1,
      resnapshot: async () => [],
    })).resolves.toEqual([]);
  });

  test("uses fresh identity snapshots instead of a signal-zero liveness probe", async () => {
    const row = { pid: 2_147_483_647, parentPid: 1, processGroupId: 100, state: "S", startTime: "Mon Sep 15 12:34:56 2026", executable: "/bin/short-lived" };
    const snapshots = [[row], []];
    await expect(sessionMemberIdentities(100, 100, [row], new Map(), {
      sessionIdFor: () => -1,
      resnapshot: async () => snapshots.shift() ?? [],
    })).resolves.toEqual([]);
    expect(snapshots).toEqual([]);
  });

  test("runs an ordinary command in a verified launcher session", async () => {
    const directory = await temporaryDirectory();
    const artifact = join(directory, "artifact.json");
    const targetSessionId = join(directory, "target.sid");
    const sessionProbe = `const { dlopen, FFIType } = await import("bun:ffi"); const { getsid } = dlopen(${JSON.stringify(posixLibcPathForPlatform())}, { getsid: { args: [FFIType.i32], returns: FFIType.i32 } }).symbols; await Bun.write(${JSON.stringify(targetSessionId)}, String(getsid(0)) + "\\n")`;
    const result = await run([
      "command", "--artifact", artifact, "--cwd", directory, "--", process.execPath, "-e", sessionProbe,
    ]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toBe("");
    const record = JSON.parse(await readFile(artifact, "utf8"));
    expect(record.child).toMatchObject({ containment: "posix-session" });
    expect(record.child.pid).toBe(record.child.sessionId);
    expect(record.child.pid).toBe(record.child.processGroupId);
    expect(await readFile(targetSessionId, "utf8")).toBe(`${record.child.sessionId}\n`);
  });

  test("fails closed when the launcher cannot establish its POSIX session", async () => {
    const directory = await temporaryDirectory();
    const result = await run([
      "command", "--artifact", join(directory, "artifact.json"), "--", process.execPath, "-e", "process.exit(0)",
    ], { ...process.env, RUN_VERIFIED_TEST_FORCE_SESSION_FAILURE: "1" });
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("session launcher");
  });

  test("detects and cleans an orphan created immediately before target exit", async () => {
    const directory = await temporaryDirectory();
    const pidFile = join(directory, "orphan.pid");
    let orphanPid = 0;
    try {
      const result = await run([
        "command", "--artifact", join(directory, "artifact.json"), "--cwd", directory, "--", "/bin/sh", "-c",
        `sleep 30 >/dev/null 2>&1 & printf '%s' $! > ${JSON.stringify(pidFile)}`,
      ]);
      expect(result.exitCode).toBe(0);
      orphanPid = Number(await waitForFile(pidFile));
      expect(sendPosixSignal(orphanPid, 0)).toBe(false);
      const record = JSON.parse(await readFile(join(directory, "artifact.json"), "utf8"));
      expect(record.child.descendantPids).toContain(orphanPid);
      expect(record.child.remainingAfterCleanup).toEqual([]);
    } finally {
      terminateIfAlive(orphanPid || Number(await readFile(pidFile, "utf8").catch(() => "0")));
    }
  });

  test("releases an owned-output lock only after session cleanup completes", async () => {
    const root = await temporaryDirectory();
    const pidFile = join(root, "orphan.pid");
    const first = Bun.spawn([process.execPath, runner, "command", "--artifact", join(root, "first.json"), "--owned-output-root", root, "--", "/bin/sh", "-c", `sleep 30 >/dev/null 2>&1 & printf '%s' $! > ${JSON.stringify(pidFile)}`], { stdout: "pipe", stderr: "pipe" });
    let orphanPid = 0;
    try {
      expect(await first.exited).toBe(0);
      orphanPid = Number(await waitForFile(pidFile));
      expect(sendPosixSignal(orphanPid, 0)).toBe(false);
      const second = await run(["command", "--artifact", join(root, "second.json"), "--owned-output-root", root, "--", process.execPath, "-e", "process.exit(0)"]);
      expect(second.exitCode).toBe(0);
    } finally {
      terminateIfAlive(orphanPid || Number(await readFile(pidFile, "utf8").catch(() => "0")));
    }
  });

  test("bounds accumulated process identities by count and serialized bytes", () => {
    const observed = new Map<string, { pid: number; processGroupId: number; sessionId: number; startTime: string; executable: string }>();
    mergeBoundedProcessIdentities(observed, [{ pid: 1, processGroupId: 1, sessionId: 1, startTime: "start", executable: "/bin/one" }], 1, 1_000);
    expect(() => mergeBoundedProcessIdentities(observed, [{ pid: 2, processGroupId: 1, sessionId: 1, startTime: "start", executable: "/bin/two" }], 1, 1_000)).toThrow("count safety limit");
    expect(() => mergeBoundedProcessIdentities(new Map(), [{ pid: 1, processGroupId: 1, sessionId: 1, startTime: "start", executable: "/bin/too-long" }], 10, 4)).toThrow("byte safety limit");
  });

  test("cleans the contained process group before propagating an identity-budget failure", async () => {
    const first = { pid: 10, processGroupId: 10, sessionId: 10, startTime: "first", executable: "/bin/first" };
    const overflow = { pid: 11, processGroupId: 10, sessionId: 10, startTime: "second", executable: "/bin/second" };
    const observed = new Map([["existing", first]]);
    const snapshots = [[overflow], [], []];
    const signals: Array<{ processGroupIds: number[]; signal: NodeJS.Signals }> = [];
    await expect(terminateProcessGroupMembers(10, 9, observed, {
      snapshotMembers: async () => snapshots.shift() ?? [],
      validateSignalMembers: async (members) => members,
      signalGroups: (processGroupIds, signal) => signals.push({ processGroupIds, signal }),
      wait: async () => {},
    }, { countLimit: 1, byteLimit: 1_000 })).rejects.toThrow("count safety limit");
    expect(signals).toEqual([{ processGroupIds: [10], signal: "SIGTERM" }]);
    expect(snapshots.length).toBe(0);
  });

  test("fails closed and kills the owned leader group when cleanup cannot snapshot members", async () => {
    const signals: Array<{ processGroupIds: number[]; signal: NodeJS.Signals }> = [];
    await expect(terminateProcessGroupMembers(10, 9, new Map(), {
      snapshotMembers: async () => { throw new Error("snapshot unavailable"); },
      signalGroups: (processGroupIds, signal) => signals.push({ processGroupIds, signal }),
      wait: async () => {},
    })).rejects.toThrow("snapshot unavailable");
    expect(signals).toEqual([]);
  });

  test("retries cleanup proof and validates identity immediately before signaling", async () => {
    const member = { pid: 11, processGroupId: 11, sessionId: 10, startTime: "start", executable: "/bin/member" };
    const snapshots: Array<Error | typeof member[]> = [new Error("transient snapshot failure"), [member], []];
    const signals: number[][] = [];
    await expect(terminateProcessGroupMembers(10, 10, new Map(), {
      snapshotMembers: async () => {
        const next = snapshots.shift() ?? [];
        if (next instanceof Error) throw next;
        return next;
      },
      validateSignalMembers: async () => [],
      signalGroups: (processGroupIds) => signals.push(processGroupIds),
      wait: async () => {},
    })).resolves.toMatchObject({ remaining: [] });
    expect(signals).toEqual([]);
  });

  test("production pre-signal validation rejects departed and reused identities but retains a live match", async () => {
    const member = { pid: 11, processGroupId: 11, sessionId: 10, startTime: "Mon Sep 15 12:34:56 2026", executable: "/bin/member" };
    const row = { ...member, parentPid: 10, state: "S" };
    const dependencies = { sessionIdFor: () => 10, processTable: async () => [row] };
    await expect(validateSessionSignalMembers(10, 10, [member], { ...dependencies, processTable: async () => [] })).resolves.toEqual([]);
    await expect(validateSessionSignalMembers(10, 10, [member], { ...dependencies, processTable: async () => [{ ...row, startTime: "Mon Sep 15 12:34:57 2026" }] })).resolves.toEqual([]);
    await expect(validateSessionSignalMembers(10, 10, [member], dependencies)).resolves.toEqual([member]);
  });

  test("sampler failures are owned and cancellation stops further polling", async () => {
    const failed = sampleSessionIdentities(10, 10, new Promise(() => {}), new Map(), undefined, async () => { throw new Error("sample failed"); }, async () => {});
    await expect(failed).rejects.toThrow("sample failed");
    const abort = new AbortController();
    let polls = 0;
    const sampling = sampleSessionIdentities(10, 10, new Promise(() => {}), new Map(), abort.signal, async () => { polls += 1; abort.abort(); return []; }, async () => {});
    await sampling;
    expect(polls).toBe(1);
  });

  test("observed daemon identities are revalidated outside the original session and signaled by PID", async () => {
    const member = { pid: 11, processGroupId: 11, sessionId: 10, startTime: "Mon Sep 15 12:34:56 2026", executable: "/bin/member" };
    const observed = new Map([[`${member.pid}\0${member.processGroupId}\0${member.sessionId}\0${member.startTime}\0${member.executable}`, member]]);
    const row = { ...member, parentPid: 1, state: "S" };
    expect(validateObservedProcessIdentities(observed, [row], () => 11)).toEqual([{ ...member, sessionId: 11 }]);
    expect(validateObservedProcessIdentities(observed, [{ ...row, startTime: "Mon Sep 15 12:34:57 2026" }], () => 11)).toEqual([]);
    const pidSignals: number[][] = [];
    await terminateProcessGroupMembers(10, 10, observed, {
      snapshotMembers: (() => { const values = [[{ ...member, sessionId: 11 }], []]; return async () => values.shift() ?? []; })(),
      validateSignalMembers: async (members) => members,
      signalPids: (pids) => pidSignals.push(pids),
      signalGroups: () => { throw new Error("detached member must not be group-signaled"); },
      wait: async () => {},
    });
    expect(pidSignals).toEqual([[11]]);
  });

  test("never group-signals a nonpositive process group", async () => {
    const member = { pid: 11, processGroupId: 0, sessionId: 10, startTime: "start", executable: "/bin/member" };
    const groupSignals: number[][] = [];
    const pidSignals: number[][] = [];
    await terminateProcessGroupMembers(10, 10, new Map(), {
      snapshotMembers: (() => { const values = [[member], []]; return async () => values.shift() ?? []; })(),
      validateSignalMembers: async (members) => members,
      signalGroups: (processGroupIds) => groupSignals.push(processGroupIds),
      signalPids: (processIds) => pidSignals.push(processIds),
      wait: async () => {},
    });
    expect(groupSignals).toEqual([]);
    expect(pidSignals).toEqual([[11]]);
  });

  test("requires a fresh cleanup snapshot after failed signal delivery", async () => {
    const member = { pid: 11, processGroupId: 11, sessionId: 10, startTime: "start", executable: "/bin/member" };
    const snapshots = [[member], []];
    const deliveryResults: boolean[] = [];
    await expect(terminateProcessGroupMembers(10, 10, new Map(), {
      snapshotMembers: async () => snapshots.shift() ?? [],
      validateSignalMembers: async (members) => members,
      signalGroups: () => { deliveryResults.push(false); },
      wait: async () => {},
    })).resolves.toMatchObject({ remaining: [] });
    expect(deliveryResults).toEqual([false]);
    expect(snapshots).toEqual([]);
  });

  test("output overflow drains, terminates, and reaps a continuously writing subprocess", async () => {
    const directory = await temporaryDirectory();
    const statePath = join(directory, "writer.json");
    const wrapper = Bun.spawn([process.execPath, runner, "command", "--artifact", join(directory, "artifact.json"), "--", process.execPath, "-e", continuousOutputFixture(statePath)], {
      stdout: "pipe", stderr: "pipe", env: { ...process.env, RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES: "4096" },
    });
    try {
      const outcome = await Promise.race([wrapper.exited, Bun.sleep(3_000).then(() => "timeout" as const)]);
      expect(outcome).not.toBe("timeout");
      expect(outcome).not.toBe(0);
      expect(await new Response(wrapper.stderr).text()).toContain("byte safety limit");
      const state = JSON.parse(await waitForFile(statePath));
      expect(sendPosixSignal(state.pid, 0)).toBe(false);
    } finally {
      wrapper.kill("SIGKILL");
      await stopFixtureSession(statePath);
      await wrapper.exited;
    }
  }, 5_000);

  test("rejects a non-canonical output-limit test override", async () => {
    const directory = await temporaryDirectory();
    const result = await run([
      "command", "--artifact", join(directory, "artifact.json"), "--", process.execPath, "-e", "process.exit(0)",
    ], { ...process.env, RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES: "1e3" });
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("strict positive integer");
  });

  test("output-limit test overrides cannot relax the production cap", () => {
    expect(resolveOutputStreamLimit(String(32 * 1024 * 1024 + 1))).toBe(32 * 1024 * 1024);
    expect(resolveOutputStreamLimit("4096")).toBe(4096);
    for (const invalid of ["0", "-1", "+1", " 1", "1.5", "1e3", "9007199254740992"]) {
      expect(() => resolveOutputStreamLimit(invalid)).toThrow("strict positive integer");
    }
  });

  test("marks the owned lock poisoned when cleanup cannot prove the session empty", async () => {
    const root = await temporaryDirectory();
    const statePath = join(root, "writer.json");
    const wrapper = Bun.spawn([process.execPath, runner, "command", "--artifact", join(root, "first.json"), "--owned-output-root", root, "--", process.execPath, "-e", continuousOutputFixture(statePath)], {
      stdout: "pipe", stderr: "pipe", env: { ...process.env, RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES: "4096", RUN_VERIFIED_TEST_FAIL_CLEANUP_SNAPSHOTS: "always" },
    });
    try {
      const outcome = await Promise.race([wrapper.exited, Bun.sleep(3_000).then(() => "timeout" as const)]);
      expect(outcome).not.toBe("timeout");
      const state = JSON.parse(await waitForFile(statePath));
      expect(sendPosixSignal(state.pid, 0)).toBe(false);
      const second = await run(["command", "--artifact", join(root, "second.json"), "--owned-output-root", root, "--", process.execPath, "-e", "process.exit(0)"]);
      expect(second.exitCode).not.toBe(0);
      expect(second.stderr).toContain("cleanup remains unproven");
    } finally {
      wrapper.kill("SIGKILL");
      await stopFixtureSession(statePath);
      await wrapper.exited;
    }
  }, 5_000);

  test("unproven cleanup cannot hang on inherited output descriptors", async () => {
    const root = await temporaryDirectory();
    const pidPath = join(root, "holder.pid");
    const target = `const child = Bun.spawn(["sleep", "30"], { stdout: "inherit", stderr: "inherit" }); child.unref(); await Bun.write(${JSON.stringify(pidPath)}, String(child.pid)); process.stdout.write("x".repeat(8192))`;
    const result = await Promise.race([
      run(["command", "--artifact", join(root, "artifact.json"), "--owned-output-root", root, "--", process.execPath, "-e", target], { ...process.env, RUN_VERIFIED_TEST_OUTPUT_LIMIT_BYTES: "4096", RUN_VERIFIED_TEST_FAIL_CLEANUP_SNAPSHOTS: "always" }),
      Bun.sleep(4_000).then(() => "timeout" as const),
    ]);
    expect(result).not.toBe("timeout");
    if (result !== "timeout") {
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("cleanup failed");
    }
    const pidText = await readFile(pidPath, "utf8");
    expect(pidText).toMatch(/^[1-9]\d*$/);
    terminateIfAlive(Number(pidText));
    expect((await readFile(join(root, ".run-verified.lock"))).length).toBeGreaterThan(0);
  }, 5_000);

  test("SIGTERM routes through cleanup and preserves signal exit semantics", async () => {
    const root = await temporaryDirectory();
    const pidPath = join(root, "target.pid");
    const wrapper = Bun.spawn([process.execPath, runner, "command", "--artifact", join(root, "artifact.json"), "--owned-output-root", root, "--", process.execPath, "-e", `await Bun.write(${JSON.stringify(pidPath)}, String(process.pid)); await Bun.sleep(30_000)`], { stdout: "pipe", stderr: "pipe" });
    const pidText = await waitForFile(pidPath);
    expect(pidText).toMatch(/^[1-9]\d*$/);
    wrapper.kill("SIGTERM");
    expect(await Promise.race([wrapper.exited, Bun.sleep(4_000).then(() => "timeout" as const)])).toBe(143);
    expect(sendPosixSignal(Number(pidText), 0)).toBe(false);
    expect((await readFile(join(root, ".run-verified.lock"))).length).toBe(0);
  }, 5_000);

  test("in-progress markers survive unproven cleanup on both private safety locks", async () => {
    const testRoot = await temporaryDirectory();
    const firstRoot = join(testRoot, "first");
    const secondRoot = join(testRoot, "second");
    await mkdir(firstRoot, { mode: 0o700 });
    await mkdir(secondRoot, { mode: 0o700 });
    const realLaneLock = "/tmp/rishi-test-integrity-iphone17pro.lock";
    const realLaneLockBefore = await readFile(realLaneLock).catch(() => undefined);
    const exercise = exerciseVerificationLocksForTest as unknown as (root: string, laneRoot: string, options: { cleanupProven: boolean }) => Promise<void>;
    await expect(exercise(firstRoot, testRoot, { cleanupProven: false })).rejects.toThrow("cleanup remains unproven");
    await expect(exercise(secondRoot, testRoot, { cleanupProven: true })).rejects.toThrow("cleanup remains unproven");
    expect((await readFile(join(firstRoot, ".run-verified.lock"))).length).toBeGreaterThan(0);
    expect((await readFile(join(testRoot, "rishi-test-integrity-iphone17pro.lock"))).length).toBeGreaterThan(0);
    expect(await readFile(realLaneLock).catch(() => undefined)).toEqual(realLaneLockBefore);
  });

  test("partial marker failure retains earlier markers and never starts work", async () => {
    const testRoot = await temporaryDirectory();
    const ownedRoot = join(testRoot, "owned");
    await mkdir(ownedRoot, { mode: 0o700 });
    let started = false;
    const exercise = exerciseVerificationLocksForTest as unknown as (root: string, laneRoot: string, options: { cleanupProven: boolean; failMarkAt: number; beforeExecution: () => void }) => Promise<void>;
    await expect(exercise(ownedRoot, testRoot, { cleanupProven: true, failMarkAt: 1, beforeExecution: () => { started = true; } })).rejects.toThrow("forced marker write failure");
    expect(started).toBeFalse();
    expect((await readFile(join(ownedRoot, ".run-verified.lock"))).length).toBeGreaterThan(0);
  });

  test("proven cleanup clears both private safety-lock markers", async () => {
    const testRoot = await temporaryDirectory();
    const ownedRoot = join(testRoot, "owned");
    await mkdir(ownedRoot, { mode: 0o700 });
    const rootLock = join(ownedRoot, ".run-verified.lock");
    const laneLock = join(testRoot, "rishi-test-integrity-iphone17pro.lock");
    const exercise = exerciseVerificationLocksForTest as unknown as (root: string, laneRoot: string, options: { cleanupProven: boolean; beforeExecution: () => Promise<void> }) => Promise<void>;
    await exercise(ownedRoot, testRoot, {
      cleanupProven: true,
      beforeExecution: async () => {
        expect((await readFile(rootLock)).length).toBeGreaterThan(0);
        expect((await readFile(laneLock)).length).toBeGreaterThan(0);
      },
    });
    expect((await readFile(rootLock)).length).toBe(0);
    expect((await readFile(laneLock)).length).toBe(0);
  });

  test("owned-root marker exists before the target starts and clears after cleanup proof", async () => {
    const root = await temporaryDirectory();
    const lockPath = join(root, ".run-verified.lock");
    const result = await run([
      "command", "--artifact", join(root, "artifact.json"), "--owned-output-root", root, "--", process.execPath, "-e",
      `const { readFileSync } = require("node:fs"); if (readFileSync(${JSON.stringify(lockPath)}).length === 0) process.exit(91)`,
    ]);
    expect(result.exitCode).toBe(0);
    expect((await readFile(lockPath)).length).toBe(0);
  });

  test("production Xcode lane lock path is fixed", () => {
    expect(productionLaneLockPath("catalyst")).toBe("/tmp/rishi-test-integrity-catalyst.lock");
    expect(productionLaneLockPath("iphone17pro")).toBe("/tmp/rishi-test-integrity-iphone17pro.lock");
  });

  test("detects and terminates a child that survives beyond the leader's final descendant sample", async () => {
    const directory = await temporaryDirectory();
    const pidFile = join(directory, "sleep.pid");
    let sleepPid = 0;
    try {
      const result = await run([
        "command", "--artifact", join(directory, "artifact.json"), "--", "/bin/sh", "-c",
        `sleep 30 >/dev/null 2>&1 & printf '%s' $! > ${JSON.stringify(pidFile)}`,
      ]);
      expect(result.exitCode).toBe(0);
      sleepPid = Number(await readFile(pidFile, "utf8"));
      expect(sendPosixSignal(sleepPid, 0)).toBe(false);
    } finally {
      terminateIfAlive(sleepPid || Number(await readFile(pidFile, "utf8").catch(() => "0")));
    }
  });

  test("rescans the process group and terminates a child spawned during cleanup", async () => {
    const directory = await temporaryDirectory();
    const pidFile = join(directory, "late-sleep.pid");
    const helperPidFile = join(directory, "helper.pid");
    const helper = `process.once("SIGTERM", async () => { const child = Bun.spawn(["sleep", "30"], { stdout: "ignore", stderr: "ignore" }); await Bun.write(${JSON.stringify(pidFile)}, String(child.pid)); process.exit(0); }); setInterval(() => {}, 1000)`;
    const target = `const helper = Bun.spawn([process.execPath, "-e", ${JSON.stringify(helper)}], { stdout: "ignore", stderr: "ignore" }); helper.unref(); await Bun.write(${JSON.stringify(helperPidFile)}, String(helper.pid))`;
    let helperPid = 0;
    let sleepPid = 0;
    try {
      const result = await run([
        "command", "--artifact", join(directory, "artifact.json"), "--", process.execPath, "-e", target,
      ]);
      expect(result.exitCode).toBe(0);
      const helperPidText = await readFile(helperPidFile, "utf8");
      const sleepPidText = await readFile(pidFile, "utf8");
      expect(helperPidText).toMatch(/^[1-9]\d*$/);
      expect(sleepPidText).toMatch(/^[1-9]\d*$/);
      helperPid = Number(helperPidText);
      sleepPid = Number(sleepPidText);
      expect(sendPosixSignal(helperPid, 0)).toBe(false);
      const status = Bun.spawnSync(["ps", "-o", "pid=,ppid=,pgid=,state=,comm=", "-p", String(sleepPid)]);
      expect(new TextDecoder().decode(status.stdout).trim()).toBe("");
    } finally {
      terminateIfAlive(helperPid || Number(await readFile(helperPidFile, "utf8").catch(() => "0")));
      terminateIfAlive(sleepPid || Number(await readFile(pidFile, "utf8").catch(() => "0")));
    }
  });

  test("process-group cleanup does not signal an unrelated process group", async () => {
    const directory = await temporaryDirectory();
    const ownedPidFile = join(directory, "owned.pid");
    const unrelated = Bun.spawn(["sleep", "30"], { detached: true, stdout: "ignore", stderr: "ignore" });
    try {
      const result = await run([
        "command", "--artifact", join(directory, "artifact.json"), "--", "/bin/sh", "-c",
        `sleep 30 >/dev/null 2>&1 & printf '%s' $! > ${JSON.stringify(ownedPidFile)}`,
      ]);
      expect(result.exitCode).toBe(0);
      expect(sendPosixSignal(unrelated.pid, 0)).toBe(true);
    } finally {
      terminateIfAlive(Number(await readFile(ownedPidFile, "utf8").catch(() => "0")));
      sendPosixSignal(-unrelated.pid, "SIGKILL");
      await unrelated.exited;
    }
  });

  test("streams command output through a fail-closed byte limit", async () => {
    const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array([1, 2])); controller.enqueue(new Uint8Array([3, 4])); controller.close(); } });
    await expect(readBounded(stream, 3, "fixture")).rejects.toThrow("safety limit");
  });

  test("requires private xcode roots and rejects a concurrent destination lane", async () => {
    const directory = await temporaryDirectory();
    const firstRoot = join(directory, "first");
    const secondRoot = join(directory, "second");
    const publicRoot = join(directory, "public");
    await mkdir(firstRoot, { mode: 0o700 });
    await mkdir(secondRoot, { mode: 0o700 });
    await mkdir(publicRoot, { mode: 0o750 });
    const fake = join(directory, "xcodebuild");
    await writeFile(fake, "#!/bin/sh\nsleep 1\n");
    await chmod(fake, 0o700);
    const destination = "platform=iOS Simulator,name=iPhone 17 Pro";
    const missingRoot = await run(["command", "--artifact", join(directory, "missing-root.json"), "--", fake, "-destination", destination]);
    const nonPrivateRoot = await run(["command", "--artifact", join(publicRoot, "artifact.json"), "--owned-output-root", publicRoot, "--", fake, "-destination", destination]);
    expect(missingRoot.stderr).toContain("--owned-output-root");
    expect(nonPrivateRoot.exitCode).not.toBe(0);
    expect(nonPrivateRoot.stderr).toContain("mode 0700");
    const first = Bun.spawn([process.execPath, runner, "command", "--artifact", join(firstRoot, "artifact.json"), "--owned-output-root", firstRoot, "--", fake, "-destination", destination], { stdout: "pipe", stderr: "pipe" });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const second = await run(["command", "--artifact", join(secondRoot, "artifact.json"), "--owned-output-root", secondRoot, "--", fake, "-destination", destination]);
    expect(second.exitCode).not.toBe(0);
    expect(second.stderr).toContain("already locked");
    expect(await first.exited).toBe(0);
  });

  test("locks every explicit owned root, including non-Xcode commands", async () => {
    const root = await temporaryDirectory();
    const first = Bun.spawn([process.execPath, runner, "command", "--artifact", join(root, "first.json"), "--owned-output-root", root, "--", process.execPath, "-e", "await Bun.sleep(800)"], { stdout: "pipe", stderr: "pipe" });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const second = await run(["command", "--artifact", join(root, "second.json"), "--owned-output-root", root, "--", process.execPath, "-e", "process.exit(0)"]);
    expect(second.exitCode).not.toBe(0);
    expect(second.stderr).toContain("already locked");
    expect(await first.exited).toBe(0);
  });

  test("infers an Apple lane through xcrun before executing", async () => {
    const directory = await temporaryDirectory();
    const xcrun = join(directory, "xcrun");
    const marker = join(directory, "executed");
    await writeFile(xcrun, `#!/bin/sh\nprintf executed > ${JSON.stringify(marker)}\n`);
    await chmod(xcrun, 0o700);
    const result = await run(["command", "--artifact", join(directory, "artifact.json"), "--", xcrun, "xcodebuild", "-destination", "platform=iOS Simulator,name=iPhone 17 Pro"]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("--owned-output-root");
    expect(await readFile(marker, "utf8").catch(() => null)).toBeNull();
  });

  darwinTest("resamples resources under the lane lock and rejects a process that appeared after preflight", async () => {
    const root = await temporaryDirectory();
    const tools = join(root, "tools");
    const marker = join(root, "executed");
    const resourceArtifact = join(root, "resource.json");
    await mkdir(tools, { mode: 0o700 });
    await writeFile(resourceArtifact, `${JSON.stringify(selfDigestedResource({ target: "iphone17pro", thresholds: { minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 } }))}\n`);
    const fixtures: Record<string, string> = {
      vm_stat: "#!/bin/sh\nprintf 'Pages free: 1000.\\nPages inactive: 1000.\\nPages speculative: 1000.\\nPage size of 4096 bytes.\\n'\n",
      df: "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/disk 100 1 1048576 1%% /\\n'\n",
      pgrep: "#!/bin/sh\n/usr/sbin/lsof -t -- /tmp/rishi-test-integrity-iphone17pro.lock >/dev/null || exit 2\nprintf '999 /usr/bin/xcodebuild build\\n'\n",
      lsof: "#!/bin/sh\nexit 1\n",
      xcodebuild: `#!/bin/sh\nprintf executed > ${JSON.stringify(marker)}\n`,
    };
    for (const [name, contents] of Object.entries(fixtures)) {
      const path = join(tools, name);
      await writeFile(path, contents);
      await chmod(path, 0o700);
    }
    const result = await run([
      "command", "--artifact", join(root, "artifact.json"), "--resource-artifact", resourceArtifact,
      "--expected-resource-target", "iphone17pro", "--min-available-memory-gib", "0", "--min-free-disk-gib", "0",
      "--owned-output-root", root, "--", join(tools, "xcodebuild"), "-destination", "platform=iOS Simulator,name=iPhone 17 Pro",
    ], { ...process.env, PATH: `${tools}:${process.env.PATH ?? ""}` });
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("duplicate target process");
    expect(await readFile(marker, "utf8").catch(() => null)).toBeNull();
  });

  test("rejects symlink escapes for normalized, raw, and reporter outputs", async () => {
    const directory = await temporaryDirectory();
    const root = join(directory, "root");
    const outside = join(directory, "outside");
    await mkdir(root, { mode: 0o700 });
    await mkdir(outside);
    await symlink(outside, join(root, "escape"));
    const normalized = await run(["command", "--artifact", join(root, "escape", "artifact.json"), "--owned-output-root", root, "--", process.execPath, "-e", "process.exit(0)"]);
    const raw = await run(["codex-jsonl", "--artifact", join(root, "artifact.json"), "--raw-output", join(root, "escape", "raw.jsonl"), "--owned-output-root", root, "--", process.execPath, "-e", "process.stdout.write('')"]);
    const linkedRoot = join(directory, "linked-root");
    await symlink(outside, linkedRoot);
    const reporter = await run(["vitest-json", "--artifact", join(linkedRoot, "artifact.json"), "--owned-output-root", linkedRoot, "--", process.execPath, "-e", "process.exit(0)"]);
    expect(normalized.exitCode).not.toBe(0);
    expect(raw.exitCode).not.toBe(0);
    expect(reporter.exitCode).not.toBe(0);
    expect(normalized.stderr).toContain("symlink");
    expect(raw.stderr).toContain("symlink");
    expect(reporter.stderr).toContain("symlink");
  });

  test("does not create an output root through a symlinked missing ancestor", async () => {
    const directory = await temporaryDirectory();
    const outside = join(directory, "outside");
    await mkdir(outside);
    await symlink(outside, join(directory, "link"));
    const root = join(directory, "link", "missing-root");
    await expect(writeContainedFile(join(root, "artifact.json"), root, "never")).rejects.toThrow(/symlink|pin|root/);
    expect(await readFile(join(outside, "missing-root", "artifact.json"), "utf8").catch(() => null)).toBeNull();
  });

  test("atomically rejects root, parent, and artifact symlink swaps without writing outside", async () => {
    const directory = await temporaryDirectory();
    const outside = join(directory, "outside");
    await mkdir(outside);

    const rootSwap = join(directory, "root-swap");
    const rootArtifact = join(rootSwap, "artifact.json");
    await mkdir(rootSwap, { mode: 0o700 });
    await expect(writeContainedFile(rootArtifact, rootSwap, "never", async () => {
      await rm(rootSwap, { recursive: true });
      await symlink(outside, rootSwap);
    })).rejects.toThrow(/changed|symlink/);
    expect(await readFile(join(outside, "artifact.json"), "utf8").catch(() => null)).toBeNull();

    const parentSwap = join(directory, "parent-swap");
    const parent = join(parentSwap, "nested");
    const parentArtifact = join(parent, "artifact.json");
    await mkdir(parent, { recursive: true, mode: 0o700 });
    await chmod(parentSwap, 0o700);
    await expect(writeContainedFile(parentArtifact, parentSwap, "never", async () => {
      await rm(parent, { recursive: true });
      await symlink(outside, parent);
    })).rejects.toThrow(/changed|symlink/);
    expect(await readFile(join(outside, "artifact.json"), "utf8").catch(() => null)).toBeNull();

    const artifactSwap = join(directory, "artifact-swap");
    const artifact = join(artifactSwap, "artifact.json");
    const outsideArtifact = join(outside, "escaped.json");
    await mkdir(artifactSwap, { mode: 0o700 });
    await expect(writeContainedFile(artifact, artifactSwap, "never", async () => {
      await symlink(outsideArtifact, artifact);
    })).rejects.toThrow(/changed|symlink/);
    expect(await readFile(outsideArtifact, "utf8").catch(() => null)).toBeNull();
  });

  test("fails closed when the root or parent is replaced after descriptors are pinned", async () => {
    const directory = await temporaryDirectory();
    const root = join(directory, "root-after-pin");
    const displacedRoot = join(directory, "displaced-root");
    await mkdir(root, { mode: 0o700 });
    await expect(writeContainedFile(join(root, "artifact.json"), root, "never", async (boundary) => {
      if (boundary !== "before-commit") return;
      await rename(root, displacedRoot);
      await mkdir(root, { mode: 0o700 });
    })).rejects.toThrow(/root changed|pin/);
    expect(await readFile(join(root, "artifact.json"), "utf8").catch(() => null)).toBeNull();
    expect(await readFile(join(displacedRoot, "artifact.json"), "utf8").catch(() => null)).toBeNull();

    const parentRoot = join(directory, "parent-after-pin");
    const parent = join(parentRoot, "nested");
    const displacedParent = join(parentRoot, "displaced-parent");
    let transientTemporaryEscaped = false;
    await mkdir(parent, { recursive: true, mode: 0o700 });
    await chmod(parentRoot, 0o700);
    await expect(writeContainedFile(join(parent, "artifact.json"), parentRoot, "never", async (boundary) => {
      if (boundary !== "before-commit") return;
      await rename(parent, displacedParent);
      transientTemporaryEscaped = (await readdir(displacedParent)).some((entry) => entry.startsWith(".run-verified-") && entry.endsWith(".tmp"));
      await mkdir(parent, { mode: 0o700 });
    })).rejects.toThrow(/parent directory changed|pin/);
    expect(transientTemporaryEscaped).toBe(false);
    expect(await readFile(join(parent, "artifact.json"), "utf8").catch(() => null)).toBeNull();
    expect(await readFile(join(displacedParent, "artifact.json"), "utf8").catch(() => null)).toBeNull();
  });

  test("atomically replaces an artifact symlink raced after its parent is pinned", async () => {
    const directory = await temporaryDirectory();
    const root = join(directory, "artifact-after-pin");
    const outside = join(directory, "outside.json");
    const artifact = join(root, "artifact.json");
    await mkdir(root, { mode: 0o700 });
    await writeContainedFile(artifact, root, "contained", async (boundary) => {
      if (boundary === "before-commit") await symlink(outside, artifact);
    });
    expect(await readFile(artifact, "utf8")).toBe("contained");
    expect(await readFile(outside, "utf8").catch(() => null)).toBeNull();
  });

  test("fails closed for a not-yet-created output root", async () => {
    const directory = await temporaryDirectory();
    const artifact = join(directory, "future", "artifact.json");
    const result = await run(["command", "--artifact", artifact, "--", process.execPath, "-e", "process.exit(0)"]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("must already exist");
  });

  test("self-test covers runner fixtures", async () => {
    const result = await run(["self-test"]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("self-test: passed");
  });
});
