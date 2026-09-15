import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  collectResourceSample,
  parseResourcePreflightCli,
  validateResourceSample,
  writeResourceArtifact,
  type ResourcePreflightDependencies,
} from "./resource-preflight";

const now = new Date("2026-09-15T12:00:00.000Z");

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function resign(sample: Record<string, unknown>): Record<string, unknown> {
  const { digest: _digest, ...unsigned } = sample;
  return { ...unsigned, digest: createHash("sha256").update(stableJson(unsigned)).digest("hex") };
}
const baseDependencies: ResourcePreflightDependencies = {
  now: () => now,
  platform: () => "darwin",
  run: (command) => {
    if (command[0] === "vm_stat") return { exitCode: 0, stdout: "Pages free: 1000.\nPages inactive: 1000.\nPages speculative: 1000.\nPages active: 1000.\nPages occupied by compressor: 0.\nPage size of 4096 bytes.\n", stderr: "" };
    if (command[0] === "df") return { exitCode: 0, stdout: "Filesystem 512-blocks Used Available Capacity iused ifree %iused Mounted on\n/dev/disk3 100 1 4294967296 1% 1 1 1% /tmp\n", stderr: "" };
    if (command[0] === "pgrep") return { exitCode: 1, stdout: "", stderr: "" };
    if (command[0] === "lsof") return { exitCode: 1, stdout: "", stderr: "" };
    throw new Error(`unexpected command: ${command.join(" ")}`);
  },
};

describe("resource preflight", () => {
  test("rejects duplicate and unknown CLI options", () => {
    const valid = ["--target", "catalyst", "--min-available-memory-gib", "8", "--min-free-disk-gib", "20", "--artifact", "/tmp/a.json"];
    expect(() => parseResourcePreflightCli(valid)).not.toThrow();
    expect(() => parseResourcePreflightCli([...valid, "--target", "iphone17pro"])).toThrow("duplicate");
    expect(() => parseResourcePreflightCli([...valid, "--mystery", "value"])).toThrow("unknown");
  });

  test("maps Catalyst and iPhone lanes to real Apple process identities and lane locks", async () => {
    for (const [target, processLine] of [
      ["catalyst", "10 /usr/bin/xcodebuild test"],
      ["catalyst", "10 /tmp/rishi.app/Contents/MacOS/rishi"],
      ["iphone17pro", "10 /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"],
    ] as const) {
      let pgrepPattern = "";
      let lockPath = "";
      const sample = await collectResourceSample({ target, minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, {
        ...baseDependencies,
        run: (command) => {
          if (command[0] === "pgrep") { pgrepPattern = command.at(-1)!; return { exitCode: 0, stdout: `${processLine}\n`, stderr: "" }; }
          if (command[0] === "lsof") { lockPath = command.at(-1)!; return { exitCode: 1, stdout: "", stderr: "" }; }
          return baseDependencies.run(command);
        },
      });
      expect(pgrepPattern).toContain("xcodebuild");
      expect(lockPath).toBe(`/tmp/rishi-test-integrity-${target}.lock`);
      expect(validateResourceSample(sample, { target, minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("duplicate target process");
    }
  });
  test("uses df -k units at the threshold edge and emits a digest", async () => {
    const sample = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0.011444, minFreeDiskGiB: 4096 }, baseDependencies);
    expect(sample.digest).toMatch(/^[a-f0-9]{64}$/);
    expect(validateResourceSample(sample, { target: "rishi", minAvailableMemoryGiB: 0.011444, minFreeDiskGiB: 4096 }, now)).toEqual([]);
    expect(validateResourceSample(sample, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 4096.001 }, now).join(" ")).toContain("free disk");
  });

  test("rejects stale samples, duplicate targets, and conflicting locks", async () => {
    const duplicateDependencies: ResourcePreflightDependencies = {
      ...baseDependencies,
      run: (command) => command[0] === "pgrep"
        ? { exitCode: 0, stdout: "10 rishi\n11 rishi\n", stderr: "" }
        : command[0] === "lsof"
          ? { exitCode: 0, stdout: "p10\ncrishi\nn/tmp/rishi-test-integrity-rishi.lock\np12\ncother\nn/tmp/rishi-test-integrity-rishi.lock\n", stderr: "" }
          : baseDependencies.run(command),
    };
    const sample = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, duplicateDependencies);
    const stale = { ...sample, sampledAt: "2026-09-15T11:59:49.000Z" };
    expect(validateResourceSample(stale, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("stale");
    expect(validateResourceSample(sample, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("duplicate");
    expect(validateResourceSample(sample, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("conflicting lock");
  });

  test("fails closed for malformed macOS command output", async () => {
    await expect(collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, {
      ...baseDependencies,
      run: () => ({ exitCode: 0, stdout: "not a platform response", stderr: "" }),
    })).rejects.toThrow("malformed");
  });

  test("requires complete lock records and rejects duplicate same-target holders", async () => {
    const malformedLocks: ResourcePreflightDependencies = {
      ...baseDependencies,
      run: (command) => command[0] === "lsof"
        ? { exitCode: 0, stdout: "p10\ncrishi\n", stderr: "" }
        : baseDependencies.run(command),
    };
    const duplicateLocks: ResourcePreflightDependencies = {
      ...baseDependencies,
      run: (command) => command[0] === "lsof"
        ? { exitCode: 0, stdout: "p10\ncrishi\nn/tmp/rishi-test-integrity-rishi.lock\np10\ncrishi\nn/tmp/rishi-test-integrity-rishi.lock\n", stderr: "" }
        : baseDependencies.run(command),
    };
    const malformed = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, malformedLocks);
    const duplicate = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, duplicateLocks);
    expect(validateResourceSample(malformed, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("malformed lock");
    expect(validateResourceSample(duplicate, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("duplicate target lock");
  });

  test("allows the lock-owning verifier PID during a live resample", async () => {
    const verifierPid = 42;
    const sample = await collectResourceSample({ target: "iphone17pro", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, {
      ...baseDependencies,
      run: (command) => command[0] === "pgrep"
        ? { exitCode: 0, stdout: `${verifierPid} /usr/bin/xcodebuild wrapper\n`, stderr: "" }
        : command[0] === "lsof"
          ? { exitCode: 0, stdout: `p${verifierPid}\ncrun-verified\nn/tmp/rishi-test-integrity-iphone17pro.lock\n`, stderr: "" }
          : baseDependencies.run(command),
    });
    expect(validateResourceSample(sample, { target: "iphone17pro", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now, new Set([verifierPid]))).toEqual([]);
  });

  test("requires strict PID and exact target command process records", async () => {
    const validProcess: ResourcePreflightDependencies = {
      ...baseDependencies,
      run: (command) => command[0] === "pgrep"
        ? { exitCode: 0, stdout: "10 rishi\n", stderr: "" }
        : baseDependencies.run(command),
    };
    const malformedProcess: ResourcePreflightDependencies = {
      ...baseDependencies,
      run: (command) => command[0] === "pgrep"
        ? { exitCode: 0, stdout: "not-a-pid rishi\n", stderr: "" }
        : baseDependencies.run(command),
    };
    const valid = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, validProcess);
    const malformed = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, malformedProcess);
    expect(validateResourceSample(valid, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("duplicate target process");
    expect(validateResourceSample(malformed, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("malformed process");
  });

  test("recognizes an ordinary executable path and writes artifacts atomically without following symlinks", async () => {
    const processDependencies: ResourcePreflightDependencies = {
      ...baseDependencies,
      run: (command) => command[0] === "pgrep"
        ? { exitCode: 0, stdout: "10 /Applications/rishi.app/Contents/MacOS/rishi --test-mode\n", stderr: "" }
        : baseDependencies.run(command),
    };
    const sample = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, processDependencies);
    expect(validateResourceSample(sample, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("duplicate target process");

    const directory = await mkdtemp(join(tmpdir(), "resource-artifact-test-"));
    try {
      const root = join(directory, "root");
      const outside = join(directory, "outside.json");
      const artifact = join(root, "resource.json");
      await mkdir(root, { mode: 0o700 });
      await symlink(outside, artifact);
      await expect(writeResourceArtifact(artifact, "never", root)).rejects.toThrow("symlink");
      expect(await readFile(outside, "utf8").catch(() => null)).toBeNull();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("rejects re-signed missing, malformed, non-finite, and negative threshold records", async () => {
    const sample = await collectResourceSample({ target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, baseDependencies);
    const missingThresholds = { ...sample } as Record<string, unknown>;
    delete missingThresholds.thresholds;
    expect(validateResourceSample(resign(missingThresholds) as never, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("malformed thresholds");
    const cases: unknown[] = [
      undefined,
      {},
      { minAvailableMemoryGiB: 0 },
      "not-an-object",
      [0, 0],
      { minAvailableMemoryGiB: Number.NaN, minFreeDiskGiB: 0 },
      { minAvailableMemoryGiB: 0, minFreeDiskGiB: Number.NaN },
      { minAvailableMemoryGiB: Number.POSITIVE_INFINITY, minFreeDiskGiB: 0 },
      { minAvailableMemoryGiB: 0, minFreeDiskGiB: Number.NEGATIVE_INFINITY },
      { minAvailableMemoryGiB: "0", minFreeDiskGiB: 0 },
      { minAvailableMemoryGiB: null, minFreeDiskGiB: 0 },
      { minAvailableMemoryGiB: -1, minFreeDiskGiB: 0 },
      { minAvailableMemoryGiB: 0, minFreeDiskGiB: -1 },
      { minAvailableMemoryGiB: 0, minFreeDiskGiB: 0, extra: 0 },
    ];
    for (const thresholds of cases) {
      const forged = resign({ ...sample, thresholds });
      expect(validateResourceSample(forged as never, { target: "rishi", minAvailableMemoryGiB: 0, minFreeDiskGiB: 0 }, now).join(" ")).toContain("malformed thresholds");
    }
  });
});
