import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const workerDirectory = fileURLToPath(new URL("../", import.meta.url));
const verifierModule = new URL("./verify-typecheck-baseline.ts", import.meta.url).href;

type VerifyBaseline = (input: {
  exitCode: number | null;
  output: string;
  stage: "T0" | "T1" | "T2";
  workerDirectory: string;
}) => void;

type ExpectedDiagnostics = () => Readonly<Record<"T0" | "T1" | "T2", readonly string[]>>;

async function loadVerifier(): Promise<{
  expectedDiagnostics: ExpectedDiagnostics;
  verifyBaseline: VerifyBaseline;
}> {
  return import(verifierModule) as Promise<{
    expectedDiagnostics: ExpectedDiagnostics;
    verifyBaseline: VerifyBaseline;
  }>;
}

function diagnostic(line: string): string {
  const [path, code] = line.split(" ");
  return `${path}(1,1): error ${code}: fixture error`;
}

async function exactOutput(stage: "T0" | "T1" | "T2"): Promise<string> {
  const { expectedDiagnostics } = await loadVerifier();
  return expectedDiagnostics()[stage].map(diagnostic).join("\n");
}

describe("verify-typecheck-baseline", () => {
  it("accepts only the exact T0, T1, and T2 Worker diagnostic multisets", async () => {
    const { expectedDiagnostics, verifyBaseline } = await loadVerifier();

    expect(expectedDiagnostics()).toEqual({
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
    });

    for (const stage of ["T0", "T1", "T2"] as const) {
      verifyBaseline({
        exitCode: 2,
        output: await exactOutput(stage),
        stage,
        workerDirectory,
      });
    }
  });

  it("rejects an added diagnostic", async () => {
    const { verifyBaseline } = await loadVerifier();
    await expect(async () => verifyBaseline({
      exitCode: 2,
      output: `${await exactOutput("T0")}\nsrc/new-error.ts(1,1): error TS9999: fixture error`,
      stage: "T0",
      workerDirectory,
    })).rejects.toThrow(/diagnostic multiset/i);
  });

  it("rejects a missing diagnostic", async () => {
    const { verifyBaseline } = await loadVerifier();
    const lines = (await exactOutput("T0")).split("\n");
    lines.pop();

    expect(() => verifyBaseline({
      exitCode: 2,
      output: lines.join("\n"),
      stage: "T0",
      workerDirectory,
    })).toThrow(/diagnostic multiset/i);
  });

  it("rejects code and count drift", async () => {
    const { verifyBaseline } = await loadVerifier();
    const output = (await exactOutput("T0")).replace("TS2769", "TS9999");

    expect(() => verifyBaseline({
      exitCode: 2,
      output,
      stage: "T0",
      workerDirectory,
    })).toThrow(/diagnostic multiset/i);
  });

  it("rejects diagnostics outside the Worker directory", async () => {
    const { verifyBaseline } = await loadVerifier();
    const output = `${await exactOutput("T0")}\n../../packages/shared/src/schema.ts(1,1): error TS9999: fixture error`;

    expect(() => verifyBaseline({
      exitCode: 2,
      output,
      stage: "T0",
      workerDirectory,
    })).toThrow(/outside the Worker directory/i);
  });

  it("rejects malformed compiler output", async () => {
    const { verifyBaseline } = await loadVerifier();

    expect(() => verifyBaseline({
      exitCode: 2,
      output: "not TypeScript diagnostic output",
      stage: "T0",
      workerDirectory,
    })).toThrow(/malformed/i);
  });

  it("rejects a zero compiler exit", async () => {
    const { verifyBaseline } = await loadVerifier();
    const output = await exactOutput("T0");

    expect(() => verifyBaseline({
      exitCode: 0,
      output,
      stage: "T0",
      workerDirectory,
    })).toThrow(/nonzero/i);
  });
});
