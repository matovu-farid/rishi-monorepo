// Pins the path-traversal guard for the renderer file server. The server
// hosts the bundled renderer assets on a local HTTP origin; any request
// that escapes the renderer root must be rejected with 403. A regression
// here means LAN-accessible arbitrary file disclosure if the server were
// ever bound beyond 127.0.0.1.
import { describe, it, expect } from 'vitest'
import { resolve, sep } from 'node:path'
import { resolveServePath } from '../rendererServer.js'

const ROOT = resolve('/tmp/test-renderer-root')

describe('rendererServer resolveServePath', () => {
  it('maps "/" to index.html under the root', () => {
    expect(resolveServePath(ROOT, '/')).toBe(`${ROOT}${sep}index.html`)
  })

  it('maps an asset path to the file under the root', () => {
    expect(resolveServePath(ROOT, '/assets/main.js')).toBe(
      `${ROOT}${sep}assets${sep}main.js`
    )
  })

  it('maps a directory-style path to its index.html', () => {
    expect(resolveServePath(ROOT, '/sub/')).toBe(`${ROOT}${sep}sub${sep}index.html`)
  })

  it('rejects a classic ../ traversal that escapes the root', () => {
    expect(resolveServePath(ROOT, '/../../../etc/passwd')).toBeNull()
  })

  it('rejects a traversal that walks back out of a nested segment', () => {
    expect(resolveServePath(ROOT, '/assets/../../../etc/passwd')).toBeNull()
  })

  it('rejects a relative path-traversal attempt', () => {
    // After stripping the leading slash this becomes "../etc/passwd", which
    // normalizes to a path one level above the root — must be rejected.
    // (Stripping a leading-slash absolute input is intentionally a separate
    // concern; the dangerous case pinned here is `..`-traversal.)
    expect(resolveServePath(ROOT, '/../etc/passwd')).toBeNull()
  })

  it('keeps paths that look traversal-y but stay inside the root', () => {
    // "/assets/sub/../main.js" normalizes to "<root>/assets/main.js"
    // which is still under the root and must be allowed.
    expect(resolveServePath(ROOT, '/assets/sub/../main.js')).toBe(
      `${ROOT}${sep}assets${sep}main.js`
    )
  })
})
