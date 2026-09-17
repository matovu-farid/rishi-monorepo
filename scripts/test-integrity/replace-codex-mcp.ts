#!/usr/bin/env bun
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type CommandResult = { exitCode: number; stdout: string; stderr: string };
export type McpProcessDependencies = {
  run: (command: string[]) => CommandResult | Promise<CommandResult>;
  setEnabled?: (name: string, enabled: boolean) => void | Promise<void>;
};

type StdioEntry = {
  name: string;
  enabled: boolean;
  transport: { type: "stdio"; command: string; args: string[]; env: Record<string, string> };
};
type Backup = { version: 1; name: string; present: boolean; entry?: StdioEntry };

const realDependencies: McpProcessDependencies = {
  async run(command) {
    const child = Bun.spawn(command, { stdout: "pipe", stderr: "pipe" });
    return {
      exitCode: await child.exited,
      stdout: await new Response(child.stdout).text(),
      stderr: await new Response(child.stderr).text(),
    };
  },
  setEnabled: (name, enabled) => setMcpEnabledInConfig(name, enabled),
};

async function setMcpEnabledInConfig(name: string, enabled: boolean): Promise<void> {
  if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error("invalid MCP server name");
  const configRoot = process.env.CODEX_HOME ? process.env.CODEX_HOME : join(homedir(), ".codex");
  const path = join(configRoot, "config.toml");
  const source = await readFile(path, "utf8");
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const header = new RegExp(`^\\[mcp_servers\\.${escaped}\\]\\s*$`, "m");
  const match = header.exec(source);
  if (!match) throw new Error("Codex MCP config entry not found after add");
  const bodyStart = match.index + match[0].length;
  const tail = source.slice(bodyStart);
  const nextTable = tail.search(/^\[/m);
  const bodyEnd = nextTable < 0 ? source.length : bodyStart + nextTable;
  const body = source.slice(bodyStart, bodyEnd);
  const setting = `enabled = ${enabled ? "true" : "false"}`;
  const updatedBody = /^\s*enabled\s*=.*$/m.test(body)
    ? body.replace(/^\s*enabled\s*=.*$/m, `\n${setting}`)
    : `${body.replace(/\s*$/, "")}\n${setting}\n`;
  const updated = source.slice(0, bodyStart) + updatedBody + source.slice(bodyEnd);
  const info = await stat(path);
  const temporary = join(dirname(path), `.config.toml.${crypto.randomUUID()}.tmp`);
  await writeFile(temporary, updated, { mode: info.mode });
  await rename(temporary, path);
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function normalizeEntry(value: unknown, expectedName?: string): StdioEntry {
  if (!isRecord(value) || typeof value.name !== "string" || (expectedName && value.name !== expectedName)) throw new Error("malformed Codex MCP entry");
  if (typeof value.enabled !== "boolean" || !isRecord(value.transport)) throw new Error("malformed Codex MCP entry");
  const transport = value.transport;
  if (transport.type !== "stdio" || typeof transport.command !== "string" || !Array.isArray(transport.args) || !transport.args.every((arg) => typeof arg === "string")) throw new Error("Codex MCP entry is not a complete stdio server");
  const envValue = transport.env ?? {};
  if (!isRecord(envValue) || !Object.entries(envValue).every(([key, item]) => typeof key === "string" && typeof item === "string")) throw new Error("malformed Codex MCP environment");
  const env = Object.fromEntries(Object.entries(envValue).map(([key, item]) => [key, item as string]).sort(([a], [b]) => a.localeCompare(b))) as Record<string, string>;
  return {
    name: value.name,
    enabled: value.enabled,
    transport: { type: "stdio", command: transport.command, args: [...transport.args], env },
  };
}

async function getEntry(name: string, dependencies: McpProcessDependencies): Promise<StdioEntry | undefined> {
  const result = await dependencies.run(["codex", "mcp", "get", name, "--json"]);
  if (result.exitCode !== 0) {
    if (result.stdout.trim() === "" && /(?:not found|does not exist|no mcp server named|unknown mcp server)/i.test(result.stderr)) return undefined;
    throw new Error("Codex MCP inspection failed");
  }
  if (!result.stdout.trim()) throw new Error("Codex MCP inspection returned no JSON");
  let value: unknown;
  try { value = JSON.parse(result.stdout); } catch { throw new Error("malformed Codex MCP JSON"); }
  return normalizeEntry(value, name);
}

async function writeBackup(path: string, backup: Backup): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${path.split("/").at(-1)}.${crypto.randomUUID()}.tmp`);
  await writeFile(temporary, `${JSON.stringify(backup, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

async function readBackup(path: string): Promise<Backup> {
  let value: unknown;
  try { value = JSON.parse(await readFile(path, "utf8")); } catch { throw new Error("malformed MCP backup"); }
  if (!isRecord(value) || value.version !== 1 || typeof value.name !== "string" || typeof value.present !== "boolean") throw new Error("malformed MCP backup");
  if (value.present !== (value.entry !== undefined)) throw new Error("malformed MCP backup");
  return value.present ? { version: 1, name: value.name, present: true, entry: normalizeEntry(value.entry, value.name) } : { version: 1, name: value.name, present: false };
}

async function removeEntry(name: string, dependencies: McpProcessDependencies): Promise<void> {
  const result = await dependencies.run(["codex", "mcp", "remove", name]);
  if (result.exitCode !== 0) throw new Error("Codex MCP removal failed");
}

async function addEntry(entry: StdioEntry, dependencies: McpProcessDependencies): Promise<void> {
  const command = ["codex", "mcp", "add", entry.name];
  for (const [key, value] of Object.entries(entry.transport.env)) command.push("--env", `${key}=${value}`);
  command.push("--", entry.transport.command, ...entry.transport.args);
  const result = await dependencies.run(command);
  if (result.exitCode !== 0) throw new Error("Codex MCP installation failed");
  if (!entry.enabled) {
    if (!dependencies.setEnabled) throw new Error("cannot restore disabled MCP state");
    await dependencies.setEnabled(entry.name, false);
  }
}

async function ensureAbsent(name: string, dependencies: McpProcessDependencies): Promise<void> {
  const current = await getEntry(name, dependencies);
  if (current) await removeEntry(name, dependencies);
  if (await getEntry(name, dependencies)) throw new Error("Codex MCP entry remained after removal");
}

async function ensureEntry(expected: StdioEntry, dependencies: McpProcessDependencies): Promise<void> {
  const actual = await getEntry(expected.name, dependencies);
  if (!actual || stableJson(actual) !== stableJson(expected)) throw new Error("installed Codex MCP entry does not match requested stdio JSON");
}

async function restoreBackup(backup: Backup, dependencies: McpProcessDependencies): Promise<void> {
  const current = await getEntry(backup.name, dependencies);
  if (current) await removeEntry(backup.name, dependencies);
  if (backup.present) {
    await addEntry(backup.entry!, dependencies);
    const restored = await getEntry(backup.name, dependencies);
    if (!restored || stableJson(restored) !== stableJson(backup.entry)) throw new Error("restored Codex MCP entry does not match backup");
  } else if (await getEntry(backup.name, dependencies)) {
    throw new Error("Codex MCP entry remained after restore");
  }
}

export async function installMcpServer(options: { name: string; command: string; args?: string[]; env?: Record<string, string>; backup: string }, dependencies: McpProcessDependencies = realDependencies): Promise<void> {
  if (!options.name || !options.command || !options.backup) throw new Error("install requires name, command, and backup");
  const previous = await getEntry(options.name, dependencies);
  const backup: Backup = previous ? { version: 1, name: options.name, present: true, entry: previous } : { version: 1, name: options.name, present: false };
  await writeBackup(options.backup, backup);
  const replacement: StdioEntry = { name: options.name, enabled: true, transport: { type: "stdio", command: options.command, args: options.args ?? [], env: options.env ?? {} } };
  try {
    if (previous) await removeEntry(options.name, dependencies);
    await addEntry(replacement, dependencies);
    await ensureEntry(replacement, dependencies);
  } catch (error) {
    try { await restoreBackup(backup, dependencies); } catch (restoreError) {
      throw new Error(`${error instanceof Error ? error.message : "Codex MCP installation failed"}; automatic restore failed: ${restoreError instanceof Error ? restoreError.message : "unknown error"}`);
    }
    throw error;
  }
}

export async function snapshotMcpServer(options: { name: string; backup: string }, dependencies: McpProcessDependencies = realDependencies): Promise<void> {
  if (!options.name || !options.backup) throw new Error("snapshot requires name and backup");
  const previous = await getEntry(options.name, dependencies);
  await writeBackup(options.backup, previous
    ? { version: 1, name: options.name, present: true, entry: previous }
    : { version: 1, name: options.name, present: false });
}

export async function restoreMcpServer(options: { name: string; backup: string }, dependencies: McpProcessDependencies = realDependencies): Promise<void> {
  const backup = await readBackup(options.backup);
  if (backup.name !== options.name) throw new Error("MCP backup name does not match requested server");
  await restoreBackup(backup, dependencies);
}

function value(arguments_: string[], index: number, flag: string): string {
  const result = arguments_[index + 1];
  if (!result || result.startsWith("--")) throw new Error(`${flag} requires a value`);
  return result;
}

function parseCli(arguments_: string[]) {
  const mode = arguments_[0];
  if (mode !== "snapshot" && mode !== "install" && mode !== "restore") throw new Error("usage: replace-codex-mcp.ts snapshot|install|restore --name NAME --backup PATH ...");
  let name: string | undefined;
  let command: string | undefined;
  let backup: string | undefined;
  const args: string[] = [];
  const env: Record<string, string> = {};
  let separator = false;
  for (let index = 1; index < arguments_.length; index += 1) {
    const flag = arguments_[index];
    if (flag === "--") { separator = true; if (mode === "install") command = value(arguments_, index++, flag); args.push(...arguments_.slice(index + 1)); break; }
    if (separator) { args.push(flag); continue; }
    if (flag === "--name") name = value(arguments_, index++, flag);
    else if (flag === "--command") command = value(arguments_, index++, flag);
    else if (flag === "--backup") backup = value(arguments_, index++, flag);
    else if (flag === "--arg") args.push(value(arguments_, index++, flag));
    else if (flag === "--env") { const item = value(arguments_, index++, flag); const equals = item.indexOf("="); if (equals < 1) throw new Error("--env requires KEY=VALUE"); env[item.slice(0, equals)] = item.slice(equals + 1); }
    else throw new Error(`unknown option: ${flag}`);
  }
  if (!name || !backup || (mode === "install" && !command)) throw new Error("usage: replace-codex-mcp.ts snapshot|install|restore --name NAME --backup PATH ...");
  return { mode, name, command, backup, args, env } as const;
}

if (import.meta.main) {
  try {
    const options = parseCli(process.argv.slice(2));
    if (options.mode === "snapshot") await snapshotMcpServer({ name: options.name, backup: options.backup });
    else if (options.mode === "install") await installMcpServer({ name: options.name, command: options.command!, args: options.args, env: options.env, backup: options.backup });
    else await restoreMcpServer({ name: options.name, backup: options.backup });
  } catch (error) {
    console.error(error instanceof Error ? error.message : "Codex MCP operation failed");
    process.exitCode = 1;
  }
}
