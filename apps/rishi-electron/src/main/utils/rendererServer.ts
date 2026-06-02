import { createServer, type Server, type IncomingMessage, type ServerResponse } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve, sep } from 'node:path'

/**
 * Tiny HTTP server that serves the bundled renderer assets in production.
 *
 * Why this exists:
 *   Electron's default approach is `mainWindow.loadFile(...)`, which loads
 *   the renderer from the `file://` scheme. OAuth providers and other web
 *   APIs reject `file:` as a redirect URL scheme, which would break the
 *   in-app webview fallback if we ever needed one. Switching the renderer
 *   to a real HTTP origin also unblocks Service Workers, Fetch, and other
 *   web platform APIs that Chromium restricts on `file://`.
 *
 *   With the Better Auth migration, sign-in itself happens out-of-process
 *   via the system browser + `rishi://` deep links, so the renderer never
 *   navigates to a third-party auth page. Keeping it on a stable
 *   `http://127.0.0.1` origin still pays for itself for the reasons above.
 *
 * What this server does:
 *   - Listens on `127.0.0.1` on an ephemeral port (no external exposure).
 *   - Serves files from `out/renderer/` with correct MIME types.
 *   - Falls back to `index.html` for unknown routes (SPA-style), so the
 *     hash router still works on hard refresh.
 *   - Path traversal is blocked: any request that escapes the renderer
 *     root is rejected with 403.
 */

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.eot': 'application/vnd.ms-fontobject',
  '.wasm': 'application/wasm',
  '.bcmap': 'application/octet-stream',
  '.pfb': 'application/octet-stream',
  '.map': 'application/json; charset=utf-8'
}

function mimeFor(path: string): string {
  return MIME[extname(path).toLowerCase()] || 'application/octet-stream'
}

/**
 * Security boundary: maps an incoming request pathname to an absolute
 * filesystem path under `root`, or returns `null` if the request escapes
 * the renderer root (path-traversal attempt). Exported so the traversal
 * guard can be unit-tested without standing up an HTTP server.
 *
 * Behaviour mirrors the request handler:
 *   - leading slashes are stripped
 *   - empty / trailing-slash paths get `index.html` appended
 *   - percent-encoded segments are decoded by the caller (URL parsing)
 *     before being passed in; this helper assumes a decoded pathname
 */
export function resolveServePath(root: string, decodedPathname: string): string | null {
  const absRoot = resolve(root)
  let relPath = decodedPathname.replace(/^\/+/, '')
  if (relPath === '' || relPath.endsWith('/')) {
    relPath = join(relPath, 'index.html')
  }
  const fullPath = normalize(join(absRoot, relPath))
  if (fullPath !== absRoot && !fullPath.startsWith(absRoot + sep)) {
    return null
  }
  return fullPath
}

let serverInstance: Server | null = null
let serverUrl: string | null = null

/**
 * Preferred fixed port for the renderer server. Using a fixed port (rather
 * than `0`/ephemeral) means OAuth redirect URLs registered in the Clerk
 * Dashboard stay stable across launches. We pick a high, unlikely-to-clash
 * port; if it's in use we fall back to an ephemeral port.
 */
const PREFERRED_PORT = 47823

/**
 * Start the renderer file server. Returns a URL like
 * `http://127.0.0.1:47823` that the BrowserWindow should `loadURL` on.
 *
 * @param rendererRoot Absolute path to the directory containing
 *                     `index.html` (typically `out/renderer`).
 */
export async function startRendererServer(rendererRoot: string): Promise<string> {
  if (serverUrl) return serverUrl

  const root = resolve(rendererRoot)
  const indexHtml = join(root, 'index.html')

  // Sanity check at startup so we fail loudly with a clear message rather
  // than silently 404 every request.
  await stat(indexHtml)

  const handleRequest = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    try {
      // Only serve GET/HEAD; everything else is a programming error.
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405).end('Method Not Allowed')
        return
      }

      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const decoded = decodeURIComponent(url.pathname)

      // Path traversal guard: refuse anything outside the renderer root.
      const fullPath = resolveServePath(root, decoded)
      if (fullPath === null) {
        res.writeHead(403).end('Forbidden')
        return
      }

      let body: Buffer
      let contentType: string
      try {
        body = await readFile(fullPath)
        contentType = mimeFor(fullPath)
      } catch {
        // SPA fallback: unknown route → serve index.html so the hash
        // router can take over. Only do this for paths that don't look
        // like asset requests (no file extension).
        if (extname(fullPath) === '') {
          body = await readFile(indexHtml)
          contentType = MIME['.html']
        } else {
          res.writeHead(404).end('Not Found')
          return
        }
      }

      res.writeHead(200, {
        'Content-Type': contentType,
        'Content-Length': body.byteLength,
        // Renderer assets are content-hashed by Vite, so they're safe to
        // cache aggressively. index.html should not be cached so updates
        // pick up immediately.
        'Cache-Control': fullPath === indexHtml ? 'no-cache' : 'public, max-age=31536000, immutable'
      })
      if (req.method === 'HEAD') {
        res.end()
      } else {
        res.end(body)
      }
    } catch (err) {
      res.writeHead(500).end('Internal Server Error')
      console.error('[rendererServer] request failed', err)
    }
  }

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    void handleRequest(req, res)
  })

  // Try the preferred fixed port first so the renderer URL is stable across
  // launches (matters for any OAuth redirect URLs the user might pin in the
  // Clerk Dashboard). If it's already in use, fall back to an ephemeral
  // port — Clerk's localhost handling is permissive about ports for dev
  // keys, and prod keys validate the host (not the port).
  const tryListen = (port: number): Promise<void> =>
    new Promise<void>((resolveListen, reject) => {
      const onError = (err: NodeJS.ErrnoException) => {
        server.off('listening', onListening)
        reject(err)
      }
      const onListening = () => {
        server.off('error', onError)
        resolveListen()
      }
      server.once('error', onError)
      server.once('listening', onListening)
      // Bind to 127.0.0.1 only so the server is never reachable from the
      // network.
      server.listen(port, '127.0.0.1')
    })

  try {
    await tryListen(PREFERRED_PORT)
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EADDRINUSE') throw err
    console.warn(`[rendererServer] port ${PREFERRED_PORT} in use, using ephemeral port`)
    await tryListen(0)
  }

  const address = server.address()
  if (!address || typeof address === 'string') {
    server.close()
    throw new Error('[rendererServer] failed to bind to an ephemeral port')
  }

  serverInstance = server
  // Why: single-writer — startRendererServer's early-return guard above
  // (`if (serverUrl) return serverUrl`) prevents concurrent runs from racing
  // this assignment.
  // eslint-disable-next-line require-atomic-updates
  serverUrl = `http://127.0.0.1:${address.port}`
  return serverUrl
}

export function getRendererServerUrl(): string | null {
  return serverUrl
}

export async function stopRendererServer(): Promise<void> {
  const s = serverInstance
  if (!s) return
  serverInstance = null
  serverUrl = null
  await new Promise<void>((res) => {
    s.close(() => res())
  })
}
