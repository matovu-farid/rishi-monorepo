import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

const commandLineToolsDirectory = "/Library/Developer/CommandLineTools";

function containsXcodeTools(directory) {
  return existsSync(join(directory, "usr", "bin", "xcodebuild"))
    && existsSync(join(directory, "usr", "bin", "simctl"));
}

function installedXcodeDirectories() {
  let applicationNames = [];
  try {
    applicationNames = readdirSync("/Applications")
      .filter((name) => /^Xcode(?:-.*)?\.app$/i.test(name))
      .sort((left, right) => {
        if (left === "Xcode.app") return -1;
        if (right === "Xcode.app") return 1;
        return left.localeCompare(right);
      });
  } catch {}
  return applicationNames.map((name) => join("/Applications", name, "Contents", "Developer"));
}

export function resolveDeveloperDirectory({
  environment = process.env,
  installedDirectories = installedXcodeDirectories(),
  isUsable = containsXcodeTools,
} = {}) {
  const configured = environment.DEVELOPER_DIR?.trim();
  if (configured && configured !== commandLineToolsDirectory) {
    if (isUsable(configured)) return configured;
    throw new Error(`DEVELOPER_DIR=${configured} does not contain Xcode tools (xcodebuild and simctl)`);
  }

  const fallback = installedDirectories.find((directory) => isUsable(directory));
  if (fallback) return fallback;

  const active = configured || commandLineToolsDirectory;
  throw new Error(
    `No usable Xcode developer directory found; active DEVELOPER_DIR=${active} does not contain Xcode tools. `
      + "Install Xcode or set DEVELOPER_DIR to an Xcode.app/Contents/Developer directory.",
  );
}
