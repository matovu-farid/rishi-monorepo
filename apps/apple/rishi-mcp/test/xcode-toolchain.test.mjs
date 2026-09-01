import test from "node:test";
import assert from "node:assert/strict";
import { resolveDeveloperDirectory } from "../src/xcode-toolchain.mjs";

test("falls back from CommandLineTools to an installed Xcode developer directory", () => {
  const result = resolveDeveloperDirectory({
    environment: { DEVELOPER_DIR: "/Library/Developer/CommandLineTools" },
    installedDirectories: ["/Applications/Xcode-beta.app/Contents/Developer"],
  });

  assert.equal(result, "/Applications/Xcode-beta.app/Contents/Developer");
});

test("rejects an explicitly invalid developer directory with an actionable error", () => {
  assert.throws(
    () => resolveDeveloperDirectory({
      environment: { DEVELOPER_DIR: "/Library/Developer/CommandLineTools" },
      installedDirectories: [],
    }),
    /does not contain Xcode tools/,
  );
});
