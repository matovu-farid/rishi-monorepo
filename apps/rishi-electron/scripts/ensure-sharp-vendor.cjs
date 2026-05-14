#!/usr/bin/env node
// pnpm v10 only runs install scripts for packages listed in `pnpm.onlyBuiltDependencies`
// AT THE WORKSPACE ROOT. We can't reach that root from this app, so sharp's libvips
// downloader gets skipped on every install — leaving sharp's binding unable to dlopen
// libvips-cpp.42.dylib at runtime. Detect and fix here.

// Why: CommonJS-only post-install script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const fs = require('node:fs')
// Why: CommonJS-only post-install script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const path = require('node:path')
// Why: CommonJS-only post-install script
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { execFileSync } = require('node:child_process')

const pnpmDir = path.join(__dirname, '..', 'node_modules', '.pnpm')
if (!fs.existsSync(pnpmDir)) process.exit(0)

const sharpEntry = fs.readdirSync(pnpmDir).find((d) => d.startsWith('sharp@'))
if (!sharpEntry) process.exit(0)

const sharpPkg = path.join(pnpmDir, sharpEntry, 'node_modules', 'sharp')
const vendorDir = path.join(sharpPkg, 'vendor')

if (fs.existsSync(vendorDir) && fs.readdirSync(vendorDir).length > 0) {
  process.exit(0)
}

console.log('[ensure-sharp-vendor] vendor missing, running sharp install/libvips.js')
execFileSync(process.execPath, ['install/libvips.js'], { cwd: sharpPkg, stdio: 'inherit' })
