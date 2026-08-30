import { execFile } from "node:child_process";

function run(command, args) {
  return new Promise((resolve) => execFile(command, args, { timeout: 3000 }, (error, stdout) => resolve(error ? "" : stdout)));
}

export async function memorySnapshot(match = "") {
  const [vmstat, processes] = await Promise.all([
    run("vm_stat", []),
    run("ps", ["-axo", "pid=,rss=,command="]),
  ]);
  const pageSize = Number(vmstat.match(/page size of (\d+) bytes/)?.[1] ?? 4096);
  const pages = Object.fromEntries([...vmstat.matchAll(/^Pages ([^:]+):\s+(\d+)/gm)].map((m) => [m[1].trim().toLowerCase().replaceAll(" ", "_"), Number(m[2])]));
  const processMatch = /^(catalyst|iphone17)$/i.test(match) ? "rishi.app" : match;
  const matchingProcesses = processes.split("\n").map((line) => line.trim()).filter(Boolean).filter((line) => !processMatch || line.toLowerCase().includes(processMatch.toLowerCase())).map((line) => {
    const [, pid, rss, command] = line.match(/^(\d+)\s+(\d+)\s+(.+)$/) ?? [];
    return pid ? { pid: Number(pid), rssKb: Number(rss), command } : null;
  }).filter(Boolean);
  return { host: { pageSize, pages, processRssKb: process.memoryUsage().rss / 1024 }, matchingProcesses };
}
