import { spawn, type ChildProcess } from 'child_process'
import path from 'path'
import fs from 'fs'
import os from 'os'

const STATE_FILE = path.join(os.tmpdir(), 'rishi-sharing-wrangler-dev-state.json')
const WORKER_DIR = path.resolve(__dirname, '../../../../workers/sharing-worker')
const WRANGLER_READY_RE = /Ready on (http:\/\/[^\s]+)/

export async function startWranglerDev(timeoutMs = 30_000): Promise<string> {
  return new Promise((resolve, reject) => {
    const child: ChildProcess = spawn(
      'pnpm',
      ['exec', 'wrangler', 'dev', '--port', '8788', '--local', '--persist-to', '.wrangler/e2e-state'],
      {
        cwd: WORKER_DIR,
        env: {
          ...process.env,
          WORKER_HMAC_SECRET: 'test-hmac-secret-for-e2e-do-not-use-in-production'
        },
        stdio: ['ignore', 'pipe', 'pipe']
      }
    )

    let url: string | null = null
    const timer = setTimeout(() => {
      child.kill()
      reject(new Error(`wrangler dev did not become ready within ${timeoutMs}ms`))
    }, timeoutMs)

    const onData = (chunk: Buffer): void => {
      const text = chunk.toString()
      process.stdout.write(`[wrangler-dev] ${text}`)
      const m = text.match(WRANGLER_READY_RE)
      if (m && !url) {
        url = m[1]
        clearTimeout(timer)
        fs.writeFileSync(STATE_FILE, JSON.stringify({ url, pid: child.pid }), 'utf8')
        resolve(url)
      }
    }

    child.stdout?.on('data', onData)
    child.stderr?.on('data', onData)
    child.on('exit', (code) => {
      if (!url) {
        clearTimeout(timer)
        reject(new Error(`wrangler dev exited with code ${code} before becoming ready`))
      }
    })
  })
}

export function stopWranglerDev(): void {
  if (!fs.existsSync(STATE_FILE)) return
  try {
    const { pid } = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
    if (pid) process.kill(pid, 'SIGTERM')
  } catch {
    /* already dead */
  } finally {
    fs.rmSync(STATE_FILE, { force: true })
  }
}

export function readWranglerDevUrl(): string {
  const raw = fs.readFileSync(STATE_FILE, 'utf8')
  return JSON.parse(raw).url as string
}
