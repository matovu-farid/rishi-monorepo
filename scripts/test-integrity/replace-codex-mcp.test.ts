import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { installMcpServer, restoreMcpServer, snapshotMcpServer, type CommandResult, type McpProcessDependencies } from "./replace-codex-mcp";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function backupPath(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "replace-codex-mcp-test-"));
  temporaryDirectories.push(directory);
  return join(directory, "backup.json");
}

function entry(command: string, args: string[] = [], env: Record<string, string> = {}, enabled = true) {
  return {
    name: "rishi-apple",
    enabled,
    transport: { type: "stdio", command, args, env },
  };
}

class FakeCodex implements McpProcessDependencies {
  readonly calls: string[][] = [];
  current: ReturnType<typeof entry> | undefined;
  failAdd = false;
  failRestore = false;
  getFailure: CommandResult | undefined;

  constructor(current?: ReturnType<typeof entry>) {
    this.current = current;
  }

  async run(command: string[]): Promise<CommandResult> {
    this.calls.push(command);
    if (command[0] !== "codex") throw new Error("unexpected executable");
    if (command[1] !== "mcp") throw new Error("unexpected codex command");
    if (command[2] === "get") {
      if (this.getFailure) return this.getFailure;
      return this.current
        ? { exitCode: 0, stdout: `${JSON.stringify(this.current)}\n`, stderr: "" }
        : { exitCode: 1, stdout: "", stderr: "server not found" };
    }
    if (command[2] === "remove") {
      this.current = undefined;
      return { exitCode: 0, stdout: "", stderr: "" };
    }
    if (command[2] === "add") {
      if (this.failAdd) { this.failAdd = false; return { exitCode: 1, stdout: "", stderr: "add failed" }; }
      if (this.failRestore) return { exitCode: 1, stdout: "", stderr: "restore add failed" };
      const separator = command.indexOf("--");
      const commandName = command[separator + 1];
      const args = command.slice(separator + 2);
      const env: Record<string, string> = {};
      for (let index = 3; index < separator; index += 1) {
        if (command[index] === "--env") {
          const [key, ...value] = command[++index].split("=");
          env[key] = value.join("=");
        }
      }
      this.current = entry(commandName, args, env);
      return { exitCode: 0, stdout: "", stderr: "" };
    }
    throw new Error(`unexpected codex subcommand: ${command[2]}`);
  }

  async setEnabled(_name: string, enabled: boolean): Promise<void> {
    if (!this.current) throw new Error("cannot set absent entry state");
    this.current = { ...this.current, enabled };
  }
}

describe("replace-codex-mcp", () => {
  test("snapshots an absent server without mutating MCP registration", async () => {
    const backup = await backupPath();
    const fake = new FakeCodex();
    await snapshotMcpServer({ name: "rishi-apple", backup }, fake);

    expect(fake.current).toBeUndefined();
    expect(fake.calls).toEqual([["codex", "mcp", "get", "rishi-apple", "--json"]]);
    expect(JSON.parse(await readFile(backup, "utf8"))).toEqual({ version: 1, name: "rishi-apple", present: false });
  });

  test("snapshots a complete existing stdio server without remove/add mutation", async () => {
    const backup = await backupPath();
    const previous = entry("node", ["/tmp/old-server.mjs"], { OLD_SECRET: "do-not-print" }, false);
    const fake = new FakeCodex(previous);
    await snapshotMcpServer({ name: "rishi-apple", backup }, fake);

    expect(fake.current).toEqual(previous);
    expect(fake.calls).toEqual([["codex", "mcp", "get", "rishi-apple", "--json"]]);
    expect(JSON.parse(await readFile(backup, "utf8"))).toEqual({ version: 1, name: "rishi-apple", present: true, entry: previous });
  });

  test("installs Swift when the named server is absent and verifies the exact stdio JSON", async () => {
    const backup = await backupPath();
    const fake = new FakeCodex();
    await installMcpServer({ name: "rishi-apple", command: "/tmp/rishi-apple-mcp", backup }, fake);

    expect(fake.current).toEqual(entry("/tmp/rishi-apple-mcp"));
    expect(fake.calls.map((call) => call.slice(0, 4))).toEqual([
      ["codex", "mcp", "get", "rishi-apple"],
      ["codex", "mcp", "add", "rishi-apple"],
      ["codex", "mcp", "get", "rishi-apple"],
    ]);
    expect(JSON.parse(await readFile(backup, "utf8"))).toMatchObject({ version: 1, name: "rishi-apple", present: false });
  });

  test("backs up and replaces an existing Node stdio server without leaking its environment", async () => {
    const backup = await backupPath();
    const fake = new FakeCodex(entry("node", ["/tmp/old-server.mjs"], { OLD_SECRET: "do-not-print" }));
    await installMcpServer({ name: "rishi-apple", command: "/tmp/rishi-apple-mcp", backup }, fake);

    expect(fake.current).toEqual(entry("/tmp/rishi-apple-mcp"));
    expect(JSON.parse(await readFile(backup, "utf8"))).toEqual({ version: 1, name: "rishi-apple", present: true, entry: entry("node", ["/tmp/old-server.mjs"], { OLD_SECRET: "do-not-print" }) });
  });

  test("replaces an existing Swift server and preserves its complete stdio shape for restore", async () => {
    const backup = await backupPath();
    const previous = entry("/tmp/old-swift", ["--mode", "test"], { RISHI_MODE: "old" });
    const fake = new FakeCodex(previous);
    await installMcpServer({ name: "rishi-apple", command: "/tmp/new-swift", args: ["--live"], env: { RISHI_MODE: "new" }, backup }, fake);
    expect(fake.current).toEqual(entry("/tmp/new-swift", ["--live"], { RISHI_MODE: "new" }));

    await restoreMcpServer({ name: "rishi-apple", backup }, fake);
    expect(fake.current).toEqual(previous);
  });

  test("automatically restores the prior entry when installing the replacement fails", async () => {
    const backup = await backupPath();
    const previous = entry("node", ["/tmp/old-server.mjs"], { OLD: "value" });
    const fake = new FakeCodex(previous);
    fake.failAdd = true;

    await expect(installMcpServer({ name: "rishi-apple", command: "/tmp/new", backup }, fake)).rejects.toThrow("Codex MCP installation failed");
    expect(fake.current).toEqual(previous);
    expect(fake.calls.some((call) => call[2] === "remove")).toBe(true);
  });

  test("fails closed when restoring cannot reproduce the backed-up entry", async () => {
    const backup = await backupPath();
    const previous = entry("node", ["/tmp/old-server.mjs"], { OLD: "value" });
    const fake = new FakeCodex(previous);
    await installMcpServer({ name: "rishi-apple", command: "/tmp/new", backup }, fake);
    fake.failRestore = true;
    await expect(restoreMcpServer({ name: "rishi-apple", backup }, fake)).rejects.toThrow("Codex MCP installation failed");
  });

  test("distinguishes true not-found from inspection failures before mutation", async () => {
    const backup = await backupPath();
    const fake = new FakeCodex();
    fake.getFailure = { exitCode: 1, stdout: "", stderr: "permission denied reading config" };

    await expect(installMcpServer({ name: "rishi-apple", command: "/tmp/new", backup }, fake)).rejects.toThrow(/inspection failed/);
    expect(fake.calls).toHaveLength(1);
    expect(await readFile(backup, "utf8").catch(() => undefined)).toBeUndefined();
  });

  test("preserves and restores a disabled server byte-equivalently", async () => {
    const backup = await backupPath();
    const previous = entry("node", ["/tmp/old.mjs"], { MODE: "old" }, false);
    const fake = new FakeCodex(previous);

    await installMcpServer({ name: "rishi-apple", command: "/tmp/new", backup }, fake);
    expect(fake.current?.enabled).toBe(true);
    await restoreMcpServer({ name: "rishi-apple", backup }, fake);
    expect(fake.current).toEqual(previous);
  });
});
