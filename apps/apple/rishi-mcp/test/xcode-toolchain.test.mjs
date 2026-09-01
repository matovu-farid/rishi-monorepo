import test from "node:test";
import assert from "node:assert/strict";
import { resolveDeveloperDirectory } from "../src/xcode-toolchain.mjs";
import { selectIPhone17DeviceIds } from "../src/xctest-driver.mjs";

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

test("selects a booted iPhone 17 Pro before other available simulators", () => {
  const devices = {
    devices: {
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        { name: "iPhone 17", udid: "old-device", state: "Booted" },
        { name: "iPhone 17 Pro", udid: "pro-shutdown", state: "Shutdown" },
        { name: "iPhone 17 Pro", udid: "pro-booted", state: "Booted" },
      ],
    },
  };

  assert.deepEqual(selectIPhone17DeviceIds(devices), ["pro-booted", "pro-shutdown"]);
});
