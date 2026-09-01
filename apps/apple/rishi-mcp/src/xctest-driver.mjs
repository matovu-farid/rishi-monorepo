import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { execFile, spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveDeveloperDirectory } from "./xcode-toolchain.mjs";

const project = () => process.env.RISHI_MCP_PROJECT ?? resolve(dirname(fileURLToPath(import.meta.url)), "../../rishi/rishi.xcodeproj");
const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
const running = (child) => child.exitCode === null && child.signalCode === null;

function command(commandName, args, env = process.env) {
  return new Promise((resolvePromise) => execFile(commandName, args, { timeout: 3000, env }, (error, stdout) => resolvePromise(error ? "" : stdout)));
}

function signalProcessGroup(child, signal) {
  if (!running(child)) return;
  try { process.kill(-child.pid, signal); } catch { child.kill(signal); }
}

async function waitForExit(child, timeoutMs) {
  if (!running(child)) return;
  await new Promise((resolvePromise) => {
    const timer = setTimeout(resolvePromise, timeoutMs);
    child.once("exit", () => { clearTimeout(timer); resolvePromise(); });
  });
}

async function iphone17DeviceIds(env = process.env) {
  // Preserve an explicitly selected simulator UUID exactly as supplied. Xcode
  // accepts the canonical UUID here, but can reject a lowercased destination
  // even though `simctl` reports the device as available.
  if (process.env.RISHI_MCP_IPHONE_DEVICE) return [process.env.RISHI_MCP_IPHONE_DEVICE];
  try {
    const devices = JSON.parse(await command("xcrun", ["simctl", "list", "devices", "available", "-j"], env));
    return Object.values(devices.devices ?? {}).flat().filter((device) => device.name === "iPhone 17").map((device) => device.udid.toLowerCase());
  } catch { return []; }
}

async function externalTargets(env = process.env) {
  const processes = await command("ps", ["-axo", "pid=,command="], env);
  const deviceIds = (await iphone17DeviceIds(env)).map((id) => id.toLowerCase());
  const targets = new Set();
  for (const line of processes.split("\n")) {
    if (/rishi\.app\/Contents\/MacOS\/rishi(?:\s|$)/i.test(line)) targets.add("catalyst");
    if (deviceIds.some((id) => line.toLowerCase().includes(`/devices/${id}/`)) && /rishi\.app\/rishi(?:\s|$)/i.test(line)) targets.add("iphone17");
  }
  return targets;
}

export class XCTestDriver {
  #sessions = new Map();
  #project;
  #scheme;
  #xcodebuild;
  #environment;
  constructor({ projectPath = project(), scheme = process.env.RISHI_MCP_SCHEME ?? "rishi-mcp", xcodebuild = "xcodebuild", environment = process.env } = {}) {
    this.#project = projectPath;
    this.#scheme = scheme;
    this.#xcodebuild = xcodebuild;
    this.#environment = { ...environment, DEVELOPER_DIR: resolveDeveloperDirectory({ environment }) };
  }

  async listApps() {
    const targets = await externalTargets(this.#environment);
    for (const session of this.#sessions.values()) if (running(session.child)) targets.add(session.target);
    return [...targets].map((target) => ({ id: target, displayName: `Rishi ${target}`, isRunning: true, windows: [{ id: 1, app: target }] }));
  }

  async launch(target) {
    if (this.#sessions.has(target)) throw Object.assign(new Error(`target already running: ${target}`), { code: "INSTANCE_ALREADY_RUNNING" });
    const temp = await mkdtemp(join(tmpdir(), "rishi-mcp-"));
    const server = createServer();
    const session = { target, temp, child: null, server, port: null, pending: [] };
    server.on("connection", (connection) => {
      const pending = session.pending.shift();
      if (!pending) {
        connection.destroy();
        return;
      }
      let data = "";
      let settled = false;
      const finish = (error, response) => {
        if (settled) return;
        settled = true;
        connection.destroy();
        pending.finish(error, response);
      };
      connection.setEncoding("utf8");
      connection.on("data", (chunk) => {
        if (settled) return;
        data += chunk;
        if (data.length > 2 * 1024 * 1024) {
          finish(Object.assign(new Error("bridge response exceeded 2 MiB"), { code: "STATE_CHANGED" }));
          return;
        }
        const newline = data.indexOf("\n");
        if (newline < 0) return;
        try {
          const response = JSON.parse(data.slice(0, newline));
          if (response.ok === false) finish(Object.assign(new Error(response.error ?? "bridge action failed"), { code: response.code ?? "STATE_CHANGED" }));
          else finish(null, response);
        } catch (error) {
          finish(error);
        }
      });
      connection.on("error", finish);
      connection.on("close", () => {
        if (!settled) {
          const output = (session.output ?? []).join("").trim().slice(-4000);
          const detail = output ? `: ${output}` : "";
          finish(Object.assign(new Error(`MCP bridge connection closed before responding${detail}`), { code: "STATE_CHANGED" }));
        }
      });
      connection.write(`${JSON.stringify(pending.payload)}\n`, (error) => {
        if (error) finish(error);
      });
    });
    await new Promise((resolvePromise, reject) => {
      server.once("error", reject);
      server.listen({ host: "127.0.0.1", port: 0 }, () => {
        server.removeListener("error", reject);
        resolvePromise();
      });
    });
    session.port = server.address().port;
    session.bridgeConfig = join("/private/tmp", `rishi-mcp-${target}-bridge.json`);
    await writeFile(session.bridgeConfig, JSON.stringify({ port: session.port }), { mode: 0o600 });
    const destination = target === "iphone17"
      ? `platform=iOS Simulator,id=${(await iphone17DeviceIds(this.#environment))[0] ?? ""}`
      : "platform=macOS,variant=Mac Catalyst";
    const env = this.#environment;
    const derivedData = process.env.RISHI_MCP_DERIVED_DATA ?? join(temp, "derived");
    const buildAction = process.env.RISHI_MCP_TEST_WITHOUT_BUILDING === "1" ? "test-without-building" : "test";
    const args = [buildAction, "-project", this.#project, "-scheme", this.#scheme, "-configuration", "Debug", "-destination", destination, "-only-testing:rishiUITests/MCPControlUITests/testServer", "-parallel-testing-enabled", "NO", "-derivedDataPath", derivedData];
    const child = spawn(this.#xcodebuild, args, { detached: true, env, stdio: ["ignore", "pipe", "pipe"] });
    session.child = child;
    session.command = `${this.#xcodebuild} ${args.join(" ")}`;
    session.output = [];
    const capture = (chunk) => {
      session.output.push(chunk.toString());
      while (session.output.join("").length > 20000) session.output.shift();
    };
    child.stdout.on("data", capture);
    child.stderr.on("data", capture);
    this.#sessions.set(target, session);
    child.once("exit", () => {
      if (this.#sessions.get(target) === session) this.#sessions.delete(target);
      const output = (session.output ?? []).join("").trim().slice(-4000);
      const detail = output ? `\ncommand: ${session.command}\noutput: ${output}` : `\ncommand: ${session.command}`;
      for (const pending of session.pending.splice(0)) pending.finish(Object.assign(new Error(`xcodebuild exited for ${target}${detail}`), { code: "DRIVER_UNAVAILABLE" }));
      server.close();
      void rm(session.bridgeConfig, { force: true }).catch(() => {});
      void rm(temp, { recursive: true, force: true }).catch(() => {});
    });
    try { await this.#waitForBridge(session); return { target, started: true }; } catch (error) { await this.terminate(target).catch(() => {}); throw error; }
  }

  async terminate(target) {
    const session = this.#sessions.get(target);
    if (!session) return { target, stopped: false };
    try { await this.request(target, { op: "stop" }, 2000); } catch {}
    await waitForExit(session.child, 3000);
    signalProcessGroup(session.child, "SIGTERM");
    await waitForExit(session.child, 3000);
    signalProcessGroup(session.child, "SIGKILL");
    await waitForExit(session.child, 1000);
    for (const pending of session.pending.splice(0)) pending.finish(Object.assign(new Error(`bridge stopped for ${target}`), { code: "INSTANCE_NOT_FOUND" }));
    serverClose(session.server);
    await rm(session.bridgeConfig, { force: true }).catch(() => {});
    this.#sessions.delete(target);
    await rm(session.temp, { recursive: true, force: true }).catch(() => {});
    return { target, stopped: true };
  }

  async #waitForBridge(session) {
    const deadline = Date.now() + Number(process.env.RISHI_MCP_START_TIMEOUT_MS ?? 120000);
    let lastError;
    while (Date.now() < deadline) {
      if (session.child.exitCode !== null || session.child.signalCode !== null) {
        const output = (session.output ?? []).join("").trim().slice(-4000);
        const detail = output ? ": " + output : "";
        throw Object.assign(new Error("xcodebuild exited before the XCTest bridge was ready for " + session.target + detail), { code: "DRIVER_UNAVAILABLE" });
      }
      // Do not use app.debugDescription as the readiness probe. The first iOS
      // snapshot can block while SwiftUI restores its persisted library state;
      // a lightweight bridge ping proves XCTest is connected without touching
      // the app's accessibility tree.
      try { return await this.request(session.target, { op: "ping" }, 30000); } catch (error) { lastError = error; await sleep(250); }
    }
    const output = (session.output ?? []).join("").trim().slice(-4000);
    const detail = output ? ": " + output : "";
    throw Object.assign(new Error("XCTest bridge did not become ready: " + (lastError?.message ?? "timeout") + detail), { code: "DRIVER_UNAVAILABLE" });
  }

  async request(target, payload, timeoutMs = 30000) {
    const session = this.#sessions.get(target);
    if (!session) throw Object.assign(new Error(`no XCTest session for ${target}`), { code: "INSTANCE_NOT_FOUND" });
    return new Promise((resolvePromise, reject) => {
      const pending = {
        payload,
        finish: (error, response) => {
          clearTimeout(timer);
          if (error) reject(error);
          else resolvePromise(response);
        },
      };
      const timer = setTimeout(() => {
        const index = session.pending.indexOf(pending);
        if (index >= 0) session.pending.splice(index, 1);
        pending.finish(Object.assign(new Error(`bridge timeout for ${payload.op}`), { code: "WAIT_TIMEOUT" }));
      }, timeoutMs);
      session.pending.push(pending);
    });
  }

  async state(target, screenshot = false) {
    const response = await this.request(target, { op: "snapshot", screenshot });
    return { window: { id: 1, app: target }, accessibility: { tree: response.debugDescription ?? "" }, screenshots: response.screenshotPath ? [{ id: "latest", url: `file://${response.screenshotPath}` }] : [] };
  }
  async logs(target, limit = 200) {
    const directory = target === "catalyst"
      ? join(process.env.HOME ?? "/Users/faridmatovu", "Library", "Containers", "org.fidexa.rishi", "Data", "Library", "Application Support", "rishi-dump")
      : join((await command("xcrun", ["simctl", "get_app_container", (await iphone17DeviceIds(this.#environment))[0] ?? "", "org.fidexa.rishi", "data"], this.#environment)).trim(), "tmp", "rishi-dump");
    let raw = "";
    try { raw = await readFile(join(directory, "all.log"), "utf8"); } catch {}
    const entries = raw.split("\n").filter(Boolean).map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean).slice(-limit);
    return { target, directory, entries };
  }
  async clickIdentifier(target, identifier, action = "open") { return this.request(target, { op: "tap", identifier, action }); }
  async clickText(target, text) { return this.request(target, { op: "tapText", text }); }
  async typeText(target, text) { return this.request(target, { op: "type", text }); }
  async openURL(target, url) { return this.request(target, { op: "openURL", url }); }
}

function serverClose(server) {
  if (!server.listening) return;
  server.close();
}
