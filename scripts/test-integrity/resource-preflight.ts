#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { basename, dirname, resolve } from "node:path";

const GIB = 1024 ** 3;
const SAMPLE_MAX_AGE_MS = 10_000;
const APPLE_LANE_IDENTITIES: Record<string, string[]> = {
  catalyst: ["xcodebuild", "rishi"],
  iphone17pro: ["xcodebuild", "Simulator", "rishi"],
};

export function resourceLaneLockPath(target: string): string {
  return `/tmp/rishi-test-integrity-${target}.lock`;
}

export type CommandResult = { exitCode: number; stdout: string; stderr: string };
export type ResourcePreflightDependencies = {
  now: () => Date;
  platform: () => NodeJS.Platform;
  run: (command: string[]) => CommandResult | Promise<CommandResult>;
};

export type PreflightOptions = {
  target: string;
  minAvailableMemoryGiB: number;
  minFreeDiskGiB: number;
};

export type ResourceSample = {
  version: 1;
  sampledAt: string;
  platform: "darwin";
  target: string;
  availableMemoryGiB: number;
  freeDiskGiB: number;
  thresholds: { minAvailableMemoryGiB: number; minFreeDiskGiB: number };
  processInventory: string[];
  lockInventory: string[];
  digest: string;
};

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function digestSample(sample: Omit<ResourceSample, "digest">): string {
  return createHash("sha256").update(stableJson(sample)).digest("hex");
}

function parseAvailableMemory(output: string): number {
  const pageSize = output.match(/page size of\s+(\d+)\s+bytes/i)?.[1];
  const free = output.match(/Pages free:\s+(\d+)\./i)?.[1];
  const inactive = output.match(/Pages inactive:\s+(\d+)\./i)?.[1];
  const speculative = output.match(/Pages speculative:\s+(\d+)\./i)?.[1];
  if (!pageSize || !free || !inactive || !speculative) throw new Error("malformed vm_stat output");
  return (Number(pageSize) * (Number(free) + Number(inactive) + Number(speculative))) / GIB;
}

function parseFreeDisk(output: string): number {
  const lines = output.trim().split("\n");
  if (lines.length < 2) throw new Error("malformed df output");
  const fields = lines.at(-1)!.trim().split(/\s+/);
  if (fields.length < 4 || !/^\d+$/.test(fields[3])) throw new Error("malformed df output");
  return (Number(fields[3]) * 1024) / GIB;
}

function nonEmptyLines(output: string): string[] {
  return output.split("\n").map((line) => line.trim()).filter(Boolean);
}

const realDependencies: ResourcePreflightDependencies = {
  now: () => new Date(),
  platform: () => process.platform,
  run: async (command) => {
    const child = Bun.spawn(command, { stdout: "pipe", stderr: "pipe" });
    return { exitCode: await child.exited, stdout: await new Response(child.stdout).text(), stderr: await new Response(child.stderr).text() };
  },
};

export async function collectResourceSample(options: PreflightOptions, dependencies: ResourcePreflightDependencies = realDependencies): Promise<ResourceSample> {
  if (dependencies.platform() !== "darwin") throw new Error("resource preflight requires macOS");
  if (!/^[A-Za-z0-9._-]+$/.test(options.target) || !Number.isFinite(options.minAvailableMemoryGiB) || !Number.isFinite(options.minFreeDiskGiB)) throw new Error("invalid preflight options");
  const identities = APPLE_LANE_IDENTITIES[options.target] ?? [options.target];
  const processPattern = `(^|/)(${identities.map((identity) => identity.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})([[:space:]]|$)`;
  const lockPath = resourceLaneLockPath(options.target);
  const [memory, disk, processes, locks] = await Promise.all([
    dependencies.run(["vm_stat"]),
    dependencies.run(["df", "-k", "/"]),
    dependencies.run(["pgrep", "-fl", processPattern]),
    dependencies.run(["lsof", "-Fpcn", "--", lockPath]),
  ]);
  if (memory.exitCode !== 0 || disk.exitCode !== 0 || ![0, 1].includes(processes.exitCode) || ![0, 1].includes(locks.exitCode)) throw new Error("malformed platform command result");
  const unsigned = {
    version: 1 as const,
    sampledAt: dependencies.now().toISOString(),
    platform: "darwin" as const,
    target: options.target,
    availableMemoryGiB: parseAvailableMemory(memory.stdout),
    freeDiskGiB: parseFreeDisk(disk.stdout),
    thresholds: { minAvailableMemoryGiB: options.minAvailableMemoryGiB, minFreeDiskGiB: options.minFreeDiskGiB },
    processInventory: nonEmptyLines(processes.stdout),
    lockInventory: nonEmptyLines(locks.stdout),
  };
  return { ...unsigned, digest: digestSample(unsigned) };
}

export function validateResourceSample(sample: ResourceSample, options: PreflightOptions, now = new Date(), ignoredVerifierPids = new Set<number>()): string[] {
  const issues: string[] = [];
  if (!sample || typeof sample !== "object") return ["malformed resource sample"];
  const sampledAt = new Date(sample.sampledAt);
  if (!sample || sample.version !== 1 || sample.platform !== "darwin" || sample.target !== options.target || Number.isNaN(sampledAt.valueOf())) issues.push("malformed resource sample");
  else {
    const { digest, ...unsigned } = sample;
    if (!/^[a-f0-9]{64}$/.test(digest) || digestSample(unsigned) !== digest) issues.push("resource sample digest mismatch");
    if (now.valueOf() - sampledAt.valueOf() > SAMPLE_MAX_AGE_MS || sampledAt.valueOf() > now.valueOf() + SAMPLE_MAX_AGE_MS) issues.push("resource sample is stale");
    const thresholds = sample.thresholds as unknown;
    const thresholdKeys = ["minAvailableMemoryGiB", "minFreeDiskGiB"];
    if (!thresholds || typeof thresholds !== "object" || Array.isArray(thresholds)
      || Object.keys(thresholds).length !== thresholdKeys.length
      || thresholdKeys.some((key) => !(key in thresholds))) {
      issues.push("malformed thresholds");
    } else {
      const thresholdRecord = thresholds as Record<string, unknown>;
      if (thresholdKeys.some((key) => !Number.isFinite(thresholdRecord[key]) || (thresholdRecord[key] as number) < 0)) issues.push("malformed thresholds");
    }
    if (!Number.isFinite(sample.availableMemoryGiB) || sample.availableMemoryGiB < options.minAvailableMemoryGiB) issues.push("available memory is below threshold");
    if (!Number.isFinite(sample.freeDiskGiB) || sample.freeDiskGiB < options.minFreeDiskGiB) issues.push("free disk is below threshold");
    if (!Array.isArray(sample.processInventory)) issues.push("malformed process inventory");
    else {
      const processRecord = (line: unknown): { pid: number; valid: boolean } | undefined => {
        if (typeof line !== "string") return undefined;
        const match = line.match(/^[1-9]\d*\s+(\S+)(?:\s+.*)?$/);
        if (!match) return undefined;
        return { pid: Number(line.match(/^([1-9]\d*)/)?.[1]), valid: (APPLE_LANE_IDENTITIES[sample.target] ?? [sample.target]).includes(basename(match[1])) };
      };
      const records = sample.processInventory.map(processRecord);
      if (records.some((record) => !record?.valid)) issues.push("malformed process inventory");
      if (records.some((record) => record?.valid && !ignoredVerifierPids.has(record.pid))) issues.push("duplicate target process");
    }
    if (!Array.isArray(sample.lockInventory)) issues.push("malformed lock inventory");
    else if (sample.lockInventory.length > 0) {
      const holders: Array<{ pid: string; command: string; path: string }> = [];
      for (let index = 0; index < sample.lockInventory.length; index += 3) {
        const pid = sample.lockInventory[index]?.match(/^p(\d+)$/)?.[1];
        const command = sample.lockInventory[index + 1]?.match(/^c(.+)$/)?.[1];
        const path = sample.lockInventory[index + 2]?.match(/^n(.+)$/)?.[1];
        if (!pid || !command || path !== resourceLaneLockPath(sample.target)) {
          issues.push("malformed lock inventory");
          break;
        }
        holders.push({ pid, command, path });
      }
      const conflictingHolders = holders.filter((holder) => !ignoredVerifierPids.has(Number(holder.pid)));
      if (conflictingHolders.length > 0) issues.push("conflicting lock");
      if (new Set(conflictingHolders.map((holder) => holder.pid)).size !== conflictingHolders.length) issues.push("duplicate target lock holder");
    }
  }
  return issues;
}

export async function writeResourceArtifact(artifact: string, content: string, ownedOutputRoot = dirname(resolve(artifact))): Promise<void> {
  const { writeContainedFile } = await import("./run-verified");
  await writeContainedFile(artifact, ownedOutputRoot, content);
}

export function parseResourcePreflightCli(arguments_: string[]) {
  const allowed = new Set(["--target", "--min-available-memory-gib", "--min-free-disk-gib", "--artifact", "--owned-output-root"]);
  const values = new Map<string, string>();
  for (let index = 0; index < arguments_.length; index += 2) {
    const key = arguments_[index];
    const value = arguments_[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error("usage: --target NAME --min-available-memory-gib N --min-free-disk-gib N --artifact PATH");
    if (!allowed.has(key)) throw new Error(`unknown option: ${key}`);
    if (values.has(key)) throw new Error(`duplicate option: ${key}`);
    values.set(key, value);
  }
  const target = values.get("--target");
  const artifact = values.get("--artifact");
  if (!target || !artifact) throw new Error("usage: --target NAME --min-available-memory-gib N --min-free-disk-gib N --artifact PATH");
  return { artifact, ownedOutputRoot: values.get("--owned-output-root"), options: { target, minAvailableMemoryGiB: Number(values.get("--min-available-memory-gib")), minFreeDiskGiB: Number(values.get("--min-free-disk-gib")) } };
}

if (import.meta.main) {
  try {
    const { artifact, ownedOutputRoot, options } = parseResourcePreflightCli(process.argv.slice(2));
    const sample = await collectResourceSample(options);
    const issues = validateResourceSample(sample, options);
    await writeResourceArtifact(artifact, `${JSON.stringify(sample, null, 2)}\n`, ownedOutputRoot);
    if (issues.length) throw new Error(issues.join("; "));
    process.stdout.write(`${JSON.stringify(sample)}\n`);
  } catch (error) {
    process.stderr.write(`resource-preflight: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
