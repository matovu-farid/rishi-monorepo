import test from "node:test";
import assert from "node:assert/strict";
import { InstanceRegistry, ErrorCodes, RegistryError } from "../src/instance-registry.mjs";

function fakeDriver() {
  const running = new Set();
  return { running, listApps: async () => [...running].map((id) => ({ id, isRunning: true, windows: [{ id: 1 }] })), launch: async (id) => running.add(id), terminate: async (id) => running.delete(id) };
}

test("prevents duplicates and only cleans up owned instances", async () => {
  const driver = fakeDriver();
  const registry = new InstanceRegistry(driver, async (app) => ({ app, matchingProcesses: [] }));
  const started = await registry.start("catalyst");
  assert.equal(started.owned, true);
  await assert.rejects(() => registry.start("catalyst"), (error) => error instanceof RegistryError && error.code === ErrorCodes.INSTANCE_ALREADY_RUNNING);
  assert.deepEqual(await registry.stop("other"), { app: "other", stopped: false, reason: "not_owned" });
  assert.equal(driver.running.has("catalyst"), true);
  await registry.cleanup();
  assert.equal(driver.running.size, 0);
});

test("refuses restarting a running instance it does not own", async () => {
  const driver = fakeDriver();
  driver.running.add("catalyst");
  const registry = new InstanceRegistry(driver, async () => ({}));
  await assert.rejects(() => registry.restart("catalyst"), (error) => error.code === ErrorCodes.INSTANCE_ALREADY_RUNNING);
  assert.equal(driver.running.size, 1);
});

test("serializes concurrent starts for one target", async () => {
  const driver = fakeDriver();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const originalLaunch = driver.launch;
  driver.launch = async (id) => { await gate; return originalLaunch(id); };
  const registry = new InstanceRegistry(driver, async () => ({}));
  const first = registry.start("catalyst");
  await assert.rejects(() => registry.start("catalyst"), (error) => error.code === ErrorCodes.INSTANCE_ALREADY_RUNNING);
  release();
  await first;
});
