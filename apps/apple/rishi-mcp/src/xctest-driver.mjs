import { mkdtemp, rm } from "node:fs/promises";
import { createConnection } from "node:net";
import { execFile, spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const project = () => process.env.RISHI_MCP_PROJECT ?? resolve(dirname(fileURLToPath(import.meta.url)), "../../rishi/rishi.xcodeproj");
const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
const running = (child) => child.exitCode === null && child.signalCode === null;

function command(commandName, args) {
  return new Promise((resolvePromise) => execFile(commandName, args, { timeout: 3000 }, (error, stdout) => resolvePromise(error ? "" : stdout)));
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

async function iphone17DeviceIds() {
  if (process.env.RISHI_MCP_IPHONE_DEVICE) return [process.env.RISHI_MCP_IPHONE_DEVICE.toLowerCase()];
  try {
    const devices = JSON.parse(await command("xcrun", ["simctl", "list", "devices", "available", "-j"]));
    return Object.values(devices.devices ?? {}).flat().filter((device) => device.name === "iPhone 17").map((device) => device.udid.toLowerCase());
  } catch { return []; }
}

async function externalTargets() {
  const processes = await command("ps", ["-axo", "pid=,command="]);
  const deviceIds = await iphone17DeviceIds();
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
  constructor({ projectPath = project(), scheme = process.env.RISHI_MCP_SCHEME ?? "rishi-mcp", xcodebuild = "xcodebuild" } = {}) { this.#project = projectPath; this.#scheme = scheme; this.#xcodebuild = xcodebuild; }

  async listApps() {
    const targets = await externalTargets();
    for (const session of this.#sessions.values()) if (running(session.child)) targets.add(session.target);
    return [...targets].map((target) => ({ id: target, displayName: `Rishi ${target}`, isRunning: true, windows: [{ id: 1, app: target }] }));
  }

  async launch(target) {
    if (this.#sessions.has(target)) throw Object.assign(new Error(`target already running: ${target}`), { code: "INSTANCE_ALREADY_RUNNING" });
    const temp = await mkdtemp(join(tmpdir(), "rishi-mcp-"));
    const socket = join(temp, "bridge.sock");
    const destination = target === "iphone17" ? "platform=iOS Simulator,name=iPhone 17" : "platform=macOS,variant=Mac Catalyst";
    const env = { ...process.env, RISHI_MCP_SOCKET: socket };
    const derivedData = process.env.RISHI_MCP_DERIVED_DATA ?? join(temp, "derived");
    const buildAction = process.env.RISHI_MCP_TEST_WITHOUT_BUILDING === "1" ? "test-without-building" : "test";
    const child = spawn(this.#xcodebuild, [buildAction, "-project", this.#project, "-scheme", this.#scheme, "-configuration", "Debug", "-destination", destination, "-only-testing:rishiUITests/MCPControlUITests/testServer", "-parallel-testing-enabled", "NO", "-derivedDataPath", derivedData], { detached: true, env, stdio: ["ignore", "ignore", "ignore"] });
    const session = { target, socket, temp, child };
    this.#sessions.set(target, session);
    child.once("exit", () => {
      if (this.#sessions.get(target) === session) this.#sessions.delete(target);
      void rm(temp, { recursive: true, force: true });
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
    this.#sessions.delete(target);
    await rm(session.temp, { recursive: true, force: true });
    return { target, stopped: true };
  }

  async #waitForBridge(session) {
    const deadline = Date.now() + Number(process.env.RISHI_MCP_START_TIMEOUT_MS ?? 120000);
    let lastError;
    while (Date.now() < deadline) {
      if (session.child.exitCode !== null || session.child.signalCode !== null) {
        throw Object.assign(new Error(`xcodebuild exited before the XCTest bridge was ready for ${session.target}`), { code: "DRIVER_UNAVAILABLE" });
      }
      try { return await this.request(session.target, { op: "snapshot", screenshot: false }, 1000); } catch (error) { lastError = error; await sleep(250); }
    }
    throw Object.assign(new Error(`XCTest bridge did not become ready: ${lastError?.message ?? "timeout"}`), { code: "DRIVER_UNAVAILABLE" });
  }

  async request(target, payload, timeoutMs = 30000) {
    const session = this.#sessions.get(target);
    if (!session) throw Object.assign(new Error(`no XCTest session for ${target}`), { code: "INSTANCE_NOT_FOUND" });
    return new Promise((resolvePromise, reject) => {
      const socket = createConnection(session.socket);
      let data = "";
      let settled = false;
      const fail = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        reject(error);
      };
      const timer = setTimeout(() => fail(Object.assign(new Error(`bridge timeout for ${payload.op}`), { code: "WAIT_TIMEOUT" })), timeoutMs);
      socket.setEncoding("utf8");
      socket.once("connect", () => {
        socket.write(`${JSON.stringify(payload)}\n`, (error) => {
          if (error) fail(error);
        });
      });
      socket.on("data", (chunk) => {
        if (settled) return;
        data += chunk;
        if (data.length > 2 * 1024 * 1024) {
          fail(Object.assign(new Error("bridge response exceeded 2 MiB"), { code: "STATE_CHANGED" }));
          return;
        }
        const newline = data.indexOf("\n");
        if (newline < 0) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        try {
          const response = JSON.parse(data.slice(0, newline));
          if (response.ok === false) reject(Object.assign(new Error(response.error ?? "bridge action failed"), { code: response.code ?? "STATE_CHANGED" }));
          else resolvePromise(response);
        } catch (error) { reject(error); }
      });
      socket.on("error", fail);
    });
  }

  async state(target, screenshot = false) {
    const response = await this.request(target, { op: "snapshot", screenshot });
    return { window: { id: 1, app: target }, accessibility: { tree: response.debugDescription ?? "" }, screenshots: response.screenshotPath ? [{ id: "latest", url: `file://${response.screenshotPath}` }] : [] };
  }

  async clickIdentifier(target, identifier, action = "open") { return this.request(target, { op: "tap", identifier, action }); }
  async clickText(target, text) { return this.request(target, { op: "tapText", text }); }
  async typeText(target, text) { return this.request(target, { op: "type", text }); }
  async openURL(target, url) { return this.request(target, { op: "openURL", url }); }
}
