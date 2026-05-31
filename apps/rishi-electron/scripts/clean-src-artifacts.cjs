#!/usr/bin/env node
/**
 * Remove stale .js and .d.ts artifacts under src/ that sit next to a
 * .ts or .tsx source file with the same base name.
 *
 * These artifacts get emitted by stray `tsc` runs and silently shadow
 * the real .ts sources under Vite/Rollup default extension resolution,
 * which has bitten this repo multiple times.
 *
 * Only deletes files whose sibling .ts / .tsx source exists. .js files
 * with no .ts sibling (legitimate JS) are left alone.
 *
 * Usage:
 *   node scripts/clean-src-artifacts.cjs           # delete
 *   node scripts/clean-src-artifacts.cjs --dry-run # just print
 */

'use strict'

const fs = require('node:fs')
const path = require('node:path')

const ROOT = path.resolve(__dirname, '..', 'src')
const DRY_RUN = process.argv.includes('--dry-run')

if (!fs.existsSync(ROOT)) {
  console.error(`[clean-src-artifacts] src directory not found: ${ROOT}`)
  process.exit(0)
}

/** @param {string} dir */
function* walk(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true })
  for (const entry of entries) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      yield* walk(full)
    } else if (entry.isFile()) {
      yield full
    }
  }
}

const toDelete = []

for (const file of walk(ROOT)) {
  // Match either .ts (not .d.ts) or .tsx sources.
  let base
  if (file.endsWith('.d.ts')) continue
  if (file.endsWith('.ts')) {
    base = file.slice(0, -'.ts'.length)
  } else if (file.endsWith('.tsx')) {
    base = file.slice(0, -'.tsx'.length)
  } else {
    continue
  }

  const jsSibling = `${base}.js`
  const dtsSibling = `${base}.d.ts`

  if (fs.existsSync(jsSibling)) toDelete.push(jsSibling)
  if (fs.existsSync(dtsSibling)) toDelete.push(dtsSibling)
}

// Dedupe — both .ts and .tsx with same base could point at the same artifacts.
const unique = Array.from(new Set(toDelete))

let jsCount = 0
let dtsCount = 0

for (const file of unique) {
  if (file.endsWith('.js')) jsCount++
  else if (file.endsWith('.d.ts')) dtsCount++

  if (DRY_RUN) {
    console.log(`[dry-run] would delete: ${path.relative(process.cwd(), file)}`)
  } else {
    try {
      fs.unlinkSync(file)
    } catch (err) {
      console.error(`[clean-src-artifacts] failed to delete ${file}: ${err.message}`)
    }
  }
}

const verb = DRY_RUN ? 'would delete' : 'deleted'
console.log(
  `[clean-src-artifacts] ${verb} ${unique.length} stale artifacts ` +
    `(${jsCount} .js + ${dtsCount} .d.ts) under src/`,
)
