#!/usr/bin/env bun

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export type BaselineStage = "T0" | "T1" | "T2";

export interface VerifyBaselineInput {
  exitCode: number | null;
  output: string;
  stage: BaselineStage;
  workerDirectory: string;
}

const stages = ["T0", "T1", "T2"] as const;
const diagnosticLine = /^(?<path>.+)\(\d+,\d+\): error (?<code>TS\d+):/;

const EXPECTED_DIAGNOSTICS: Readonly<Record<BaselineStage, readonly string[]>> = {
  T0: [
    "src/app-store-server-library-node/index.ts TS2769",
    "src/billing/allowance-period-rollover.ts TS2322",
    "src/billing/allowance-period-rollover.ts TS2322",
    "src/billing/apns.ts TS2769",
    "src/billing/entitlement-sync.ts TS2322",
    "src/billing/entitlement-sync.ts TS2322",
    "src/billing/jws-verify.ts TS2769",
    "src/billing/jws-verify.ts TS2769",
    "src/billing/jws-verify.ts TS2769",
    "src/billing/jws-verify.ts TS2769",
    "src/durable-objects/voice-session/nonce.ts TS2345",
    "src/durable-objects/voice-session/nonce.ts TS2345",
    "src/index.ts TS2345",
    "src/index.ts TS2345",
    "src/index.ts TS2345",
    "src/index.ts TS2722",
    "src/index.ts TS2769",
    "src/routes/sync.ts TS2769",
    "src/routes/sync.ts TS2769",
    "src/sync/change-cursor.test.ts TS2353",
  ],
  T1: [
    "src/billing/allowance-period-rollover.ts TS2322",
    "src/billing/allowance-period-rollover.ts TS2322",
    "src/billing/entitlement-sync.ts TS2322",
    "src/billing/entitlement-sync.ts TS2322",
    "src/index.ts TS2345",
    "src/index.ts TS2345",
    "src/index.ts TS2722",
    "src/routes/sync.ts TS2769",
    "src/routes/sync.ts TS2769",
    "src/sync/change-cursor.test.ts TS2353",
  ],
  T2: [
    "src/index.ts TS2345",
    "src/index.ts TS2345",
    "src/index.ts TS2722",
    "src/routes/sync.ts TS2769",
    "src/routes/sync.ts TS2769",
    "src/sync/change-cursor.test.ts TS2353",
  ],
};

export function expectedDiagnostics(): Readonly<Record<BaselineStage, readonly string[]>> {
  return EXPECTED_DIAGNOSTICS;
}

function normalizeDiagnosticPath(diagnosticPath: string, workerDirectory: string): string {
  const absoluteWorkerDirectory = resolve(workerDirectory);
  const absoluteDiagnosticPath = resolve(absoluteWorkerDirectory, diagnosticPath);
  const workerRelativePath = relative(absoluteWorkerDirectory, absoluteDiagnosticPath);

  if (
    workerRelativePath === "" ||
    workerRelativePath === ".." ||
    workerRelativePath.startsWith(`..${sep}`)
  ) {
    throw new Error(`Diagnostic path is outside the Worker directory: ${diagnosticPath}`);
  }

  return workerRelativePath.split(sep).join("/");
}

function parseDiagnostics(output: string, workerDirectory: string): string[] {
  const diagnostics: string[] = [];

  for (const line of output.split(/\r?\n/)) {
    if (line === "" || /^\s/.test(line)) continue;

    const match = diagnosticLine.exec(line);
    if (!match?.groups) {
      throw new Error(`Malformed TypeScript compiler output: ${line}`);
    }

    diagnostics.push(`${normalizeDiagnosticPath(match.groups.path, workerDirectory)} ${match.groups.code}`);
  }

  if (diagnostics.length === 0) {
    throw new Error("Malformed TypeScript compiler output: no diagnostics found");
  }

  return diagnostics.sort();
}

function describeMultisetDifference(expected: readonly string[], actual: readonly string[]): string {
  const remainingExpected = [...expected];
  const extras: string[] = [];

  for (const diagnostic of actual) {
    const index = remainingExpected.indexOf(diagnostic);
    if (index === -1) extras.push(diagnostic);
    else remainingExpected.splice(index, 1);
  }

  return [
    remainingExpected.length > 0 ? `missing: ${remainingExpected.join(", ")}` : null,
    extras.length > 0 ? `extra: ${extras.join(", ")}` : null,
  ].filter(Boolean).join("; ");
}

export function verifyBaseline({ exitCode, output, stage, workerDirectory }: VerifyBaselineInput): void {
  if (exitCode === 0) {
    throw new Error("TypeScript compiler must exit nonzero while a baseline is expected");
  }
  if (exitCode === null) {
    throw new Error("TypeScript compiler did not produce an exit code");
  }

  const actual = parseDiagnostics(output, workerDirectory);
  const expected = [...EXPECTED_DIAGNOSTICS[stage]].sort();
  if (actual.length !== expected.length || actual.some((diagnostic, index) => diagnostic !== expected[index])) {
    throw new Error(
      `TypeScript diagnostic multiset drifted for ${stage}: ${describeMultisetDifference(expected, actual)}`,
    );
  }
}

function assertPinnedTypeScript(workerDirectory: string): void {
  const packageJsonPath = resolve(workerDirectory, "package.json");
  const installedPackagePath = resolve(workerDirectory, "node_modules/typescript/package.json");
  const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as {
    devDependencies?: Record<string, string | undefined>;
  };
  const installedPackage = JSON.parse(readFileSync(installedPackagePath, "utf8")) as { version?: string };

  if (packageJson.devDependencies?.typescript !== "5.9.3" || installedPackage.version !== "5.9.3") {
    throw new Error("verify-typecheck-baseline requires TypeScript 5.9.3 to be pinned and installed locally");
  }
}

function parseStage(argv: readonly string[]): BaselineStage {
  if (argv.length !== 2 || argv[0] !== "--stage" || !stages.includes(argv[1] as BaselineStage)) {
    throw new Error("Usage: bun run scripts/verify-typecheck-baseline.ts --stage T0|T1|T2");
  }
  return argv[1] as BaselineStage;
}

export function main(argv: readonly string[] = process.argv.slice(2)): void {
  const stage = parseStage(argv);
  const workerDirectory = resolve(fileURLToPath(new URL("..", import.meta.url)));
  assertPinnedTypeScript(workerDirectory);

  const compiler = resolve(workerDirectory, "node_modules/typescript/bin/tsc");
  const result = spawnSync(process.execPath, [compiler, "--noEmit", "--pretty", "false"], {
    cwd: workerDirectory,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw result.error;

  verifyBaseline({
    exitCode: result.status,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
    stage,
    workerDirectory,
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
