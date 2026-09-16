import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

interface TypeScriptConfig {
  compilerOptions?: {
    types?: string[];
  };
  include?: string[];
}

describe("Worker TypeScript project boundary", () => {
  const config = JSON.parse(
    readFileSync(new URL("../tsconfig.json", import.meta.url), "utf8"),
  ) as TypeScriptConfig;

  it("excludes the all-shared-source glob", () => {
    expect(config.include).toEqual([
      "src/**/*.ts",
      "src/**/*.tsx",
      "scripts/**/*.ts",
      "drizzle.config.ts",
      "drizzle-do.config.ts",
    ]);
    expect(config.include).not.toContain("../../packages/shared/src/**/*.ts");
  });

  it("uses Wrangler-generated Worker runtime types", () => {
    expect(config.compilerOptions?.types).toEqual([
      "./worker-configuration.d.ts",
    ]);
  });
});
