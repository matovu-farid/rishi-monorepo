#!/usr/bin/env node
// Ensure native modules (better-sqlite3, hnswlib-node, sharp) are compiled
// against the currently installed Electron version.
//
// Why this exists: `postinstall` runs `electron-rebuild`, but pnpm only re-runs
// install scripts when the lockfile changes. If Electron is upgraded in a way
// that bumps NODE_MODULE_VERSION without a fresh install (e.g. moving between
// branches, manual node_modules edits, partial installs) `pnpm dev` can boot
// against a stale .node binary and crash with ERR_DLOPEN_FAILED.
//
// Strategy: record the Electron version we last rebuilt against in a marker
// file. If the current Electron version differs, run `electron-rebuild`.

// Why: CommonJS-only pre-dev script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const fs = require('node:fs')
// Why: CommonJS-only pre-dev script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const path = require('node:path')
// Why: CommonJS-only pre-dev script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { execFileSync } = require('node:child_process')

const APP_ROOT = path.join(__dirname, '..')
const MARKER = path.join(APP_ROOT, 'node_modules', '.electron-rebuild-version')

function readElectronVersion() {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const pkg = require(path.join(APP_ROOT, 'node_modules', 'electron', 'package.json'))
    return pkg.version
  } catch {
    return null
  }
}

function readMarker() {
  try {
    return fs.readFileSync(MARKER, 'utf8').trim()
  } catch {
    return null
  }
}

function nativeBindingsPresent() {
  return fs.existsSync(
    path.join(APP_ROOT, 'node_modules', 'better-sqlite3', 'build', 'Release', 'better_sqlite3.node'),
  )
}

function rebuild() {
  console.log('[ensure-native-abi] rebuilding native modules against Electron…')
  // Spawn the electron-rebuild CLI directly via node. Going through `pnpm exec`
  // hits a Windows portability bug: pnpm is a `.cmd` shim there, and
  // `execFileSync` won't shell-resolve `.cmd` files (throws ENOENT/EINVAL).
  // Matches the pattern used in ensure-sharp-vendor.cjs.
  const rebuildMain = require.resolve('@electron/rebuild')
  const rebuildCli = path.join(path.dirname(rebuildMain), 'cli.js')
  execFileSync(process.execPath, [rebuildCli, '-f'], {
    cwd: APP_ROOT,
    stdio: 'inherit',
  })
}

function writeMarker(version) {
  try {
    fs.writeFileSync(MARKER, version)
  } catch (err) {
    console.warn('[ensure-native-abi] could not write marker:', err.message)
  }
}

function main() {
  const electronVersion = readElectronVersion()
  if (!electronVersion) {
    // electron not installed (unusual) — nothing to do.
    return
  }
  if (!nativeBindingsPresent()) {
    // No .node yet — postinstall will/did build it.
    return
  }
  const lastRebuilt = readMarker()
  if (lastRebuilt === electronVersion) {
    return
  }
  rebuild()
  writeMarker(electronVersion)
}

main()
