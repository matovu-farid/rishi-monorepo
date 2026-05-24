#!/usr/bin/env node
// Record the Electron version that `electron-rebuild` was just run against.
// Pair with `scripts/ensure-native-abi.cjs` (the `predev` guard) so we only
// rebuild when Electron's version changes.

// Why: CommonJS-only post-install script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const fs = require('node:fs')
// Why: CommonJS-only post-install script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const path = require('node:path')

const APP_ROOT = path.join(__dirname, '..')
const MARKER = path.join(APP_ROOT, 'node_modules', '.electron-rebuild-version')

try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const pkg = require(path.join(APP_ROOT, 'node_modules', 'electron', 'package.json'))
  fs.writeFileSync(MARKER, pkg.version)
} catch (err) {
  console.warn('[mark-native-abi] could not write marker:', err.message)
  process.exit(0)
}
