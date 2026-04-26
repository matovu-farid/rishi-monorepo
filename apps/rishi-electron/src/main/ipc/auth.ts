import { ipcMain, app, safeStorage } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import * as crypto from 'node:crypto'

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev'

/** Path to the encrypted auth token file */
function getTokenPath(): string {
  return path.join(app.getPath('userData'), 'auth-token.enc')
}

/** Path to the auth token expiry file */
function getTokenExpiryPath(): string {
  return path.join(app.getPath('userData'), 'auth-token-expiry.json')
}

/** Path to the stored user JSON file */
function getUserStorePath(): string {
  return path.join(app.getPath('userData'), 'user.json')
}

/** Path to the OAuth state file (PKCE code_verifier + state + timestamp) */
function getOAuthStatePath(): string {
  return path.join(app.getPath('userData'), 'oauth-state.json')
}

export function registerAuthHandlers(): void {
  ipcMain.handle('auth:getToken', async () => {
    try {
      // Check if encryption is available
      if (!safeStorage.isEncryptionAvailable()) {
        return null
      }

      const tokenPath = getTokenPath()
      const expiryPath = getTokenExpiryPath()

      try {
        await fs.access(tokenPath)
      } catch {
        return null // No stored token
      }

      // Check expiry
      try {
        const expiryData = await fs.readFile(expiryPath, 'utf-8')
        const { expiresAt } = JSON.parse(expiryData)
        if (Date.now() > expiresAt) {
          // Token expired, clean up
          await fs.unlink(tokenPath).catch(() => {})
          await fs.unlink(expiryPath).catch(() => {})
          return null
        }
      } catch {
        // No expiry file, token may still be valid
      }

      const encrypted = await fs.readFile(tokenPath)
      const token = safeStorage.decryptString(encrypted)
      return token
    } catch (error) {
      throw new Error(
        `Failed to get auth token: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:saveToken', async (_event, token: string, expiresAt: number) => {
    try {
      if (!safeStorage.isEncryptionAvailable()) {
        throw new Error('Encryption is not available on this system')
      }

      const encrypted = safeStorage.encryptString(token)
      await fs.writeFile(getTokenPath(), encrypted)
      await fs.writeFile(getTokenExpiryPath(), JSON.stringify({ expiresAt }))
    } catch (error) {
      throw new Error(
        `Failed to save auth token: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:clear', async () => {
    try {
      const tokenPath = getTokenPath()
      const expiryPath = getTokenExpiryPath()
      const userPath = getUserStorePath()

      await fs.unlink(tokenPath).catch(() => {})
      await fs.unlink(expiryPath).catch(() => {})
      await fs.unlink(userPath).catch(() => {})
    } catch (error) {
      throw new Error(
        `Failed to clear auth: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:getUserFromStore', async () => {
    try {
      const userPath = getUserStorePath()

      try {
        await fs.access(userPath)
      } catch {
        return null // No stored user
      }

      const data = await fs.readFile(userPath, 'utf-8')
      return JSON.parse(data)
    } catch (error) {
      throw new Error(
        `Failed to get user from store: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:saveUserToStore', async (_event, user: unknown) => {
    try {
      const userPath = getUserStorePath()
      await fs.writeFile(userPath, JSON.stringify(user, null, 2))
    } catch (error) {
      throw new Error(
        `Failed to save user to store: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  // ── PKCE / Deep-link auth ──────────────────────────────────────────

  ipcMain.handle('auth:getOAuthState', async () => {
    try {
      const statePath = getOAuthStatePath()

      // Reuse existing state if it's less than 5 minutes old
      try {
        const existing = JSON.parse(await fs.readFile(statePath, 'utf-8'))
        if (Date.now() - existing.createdAt < 5 * 60 * 1000) {
          return { state: existing.state, codeChallenge: existing.codeChallenge }
        }
      } catch {
        // No existing state or invalid — generate fresh
      }

      const state = crypto.randomUUID()
      const verifierBytes = crypto.randomBytes(32)
      const codeVerifier = verifierBytes.toString('base64url')
      const codeChallenge = crypto.createHash('sha256').update(codeVerifier).digest('base64url')

      await fs.writeFile(
        statePath,
        JSON.stringify({ state, codeVerifier, codeChallenge, createdAt: Date.now() })
      )

      return { state, codeChallenge }
    } catch (error) {
      throw new Error(
        `Failed to generate OAuth state: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:completeAuth', async (_event, state: string) => {
    try {
      // Read persisted code_verifier
      const statePath = getOAuthStatePath()
      let oauthData: { state: string; codeVerifier: string }
      try {
        oauthData = JSON.parse(await fs.readFile(statePath, 'utf-8'))
      } catch {
        throw new Error('Missing code_verifier — please sign in again')
      }

      const response = await fetch(`${WORKER_URL}/api/auth/complete`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          state,
          code_verifier: oauthData.codeVerifier
        })
      })

      if (!response.ok) {
        const body = await response.text().catch(() => '')
        throw new Error(`Auth completion failed (${response.status}): ${body}`)
      }

      const data = (await response.json()) as {
        token?: string
        user?: Record<string, unknown>
        expiresAt?: number
      }

      const token = data.token
      const user = data.user
      const expiresAt = data.expiresAt
      if (!token || !user || !expiresAt) {
        throw new Error('Incomplete auth response from worker')
      }

      // Store token securely
      if (safeStorage.isEncryptionAvailable()) {
        const encrypted = safeStorage.encryptString(token)
        await fs.writeFile(getTokenPath(), encrypted)
        await fs.writeFile(getTokenExpiryPath(), JSON.stringify({ expiresAt }))
      }

      // Store user profile (non-secret)
      await fs.writeFile(getUserStorePath(), JSON.stringify(user, null, 2))

      // Clean up OAuth state file
      await fs.unlink(statePath).catch(() => {})

      return user
    } catch (error) {
      throw new Error(
        `Failed to complete auth: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:checkAuthStatus', async (_event, state: string) => {
    try {
      // Read persisted code_challenge for verification
      const statePath = getOAuthStatePath()
      let codeChallenge = ''
      try {
        const oauthData = JSON.parse(await fs.readFile(statePath, 'utf-8'))
        codeChallenge = oauthData.codeChallenge || ''
      } catch {
        throw new Error('No OAuth state found')
      }

      const response = await fetch(`${WORKER_URL}/api/auth/status/${encodeURIComponent(state)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code_challenge: codeChallenge })
      })
      if (!response.ok) {
        throw new Error(`Status check failed (${response.status})`)
      }
      return await response.json()
    } catch (error) {
      throw new Error(
        `Failed to check auth status: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('auth:signout', async () => {
    try {
      // Best-effort: revoke token on server
      try {
        const tokenPath = getTokenPath()
        const encrypted = await fs.readFile(tokenPath)
        const token = safeStorage.decryptString(encrypted)
        await fetch(`${WORKER_URL}/api/auth/revoke`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}` }
        })
      } catch {
        // Token may not exist or revocation failed — proceed with local cleanup
      }

      // Delete all local auth files
      await fs.unlink(getTokenPath()).catch(() => {})
      await fs.unlink(getTokenExpiryPath()).catch(() => {})
      await fs.unlink(getUserStorePath()).catch(() => {})
      await fs.unlink(getOAuthStatePath()).catch(() => {})
    } catch (error) {
      throw new Error(
        `Failed to sign out: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  // ── Token refresh ─────────────────────────────────────────────────

  /**
   * Refresh auth token if close to expiry.
   * Returns the expiry timestamp (existing or new) on success, null on failure.
   * - number: token is valid (may or may not have been refreshed)
   * - null: no token, refresh failed, or encryption unavailable
   */
  ipcMain.handle('auth:refreshToken', async () => {
    try {
      // 1. Read current token from safeStorage
      if (!safeStorage.isEncryptionAvailable()) {
        return null
      }

      const tokenPath = getTokenPath()
      const expiryPath = getTokenExpiryPath()

      let token: string
      try {
        const encrypted = await fs.readFile(tokenPath)
        token = safeStorage.decryptString(encrypted)
      } catch {
        return null // No stored token
      }

      // 2. Check if token expires within 1 day — if not, skip refresh
      try {
        const expiryData = await fs.readFile(expiryPath, 'utf-8')
        const { expiresAt } = JSON.parse(expiryData) as { expiresAt: number }
        const now = Date.now()
        const oneDay = 24 * 60 * 60 * 1000

        if (expiresAt > now + oneDay) {
          // Token is still fresh (more than 1 day until expiry)
          return expiresAt
        }
        if (now > expiresAt) {
          // Token already expired — refresh endpoint requires a valid token
          return null
        }
      } catch {
        // No expiry file — attempt refresh anyway
      }

      // 3. Call worker refresh endpoint
      const response = await fetch(`${WORKER_URL}/api/auth/refresh`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` }
      })

      if (!response.ok) {
        console.error(
          `[auth:refreshToken] Refresh failed (${response.status}):`,
          await response.text().catch(() => '')
        )
        return null
      }

      const data = (await response.json()) as {
        token?: string
        expiresAt?: number
      }
      const newToken = data.token
      const newExpiresAt = data.expiresAt

      if (!newToken || !newExpiresAt) {
        console.error('[auth:refreshToken] Incomplete refresh response')
        return null
      }

      // 4. Store new token and expiry via safeStorage
      const encrypted = safeStorage.encryptString(newToken)
      await fs.writeFile(tokenPath, encrypted)
      await fs.writeFile(expiryPath, JSON.stringify({ expiresAt: newExpiresAt }))

      return newExpiresAt
    } catch (error) {
      console.error(
        '[auth:refreshToken] Error:',
        error instanceof Error ? error.message : String(error)
      )
      return null
    }
  })

  // ── Get user from API ─────────────────────────────────────────────

  ipcMain.handle('auth:getUser', async (_event, userId: string) => {
    try {
      // Validate userId — only alphanumeric and underscores
      if (!userId || !/^[\w]+$/.test(userId)) {
        throw new Error('Invalid userId format')
      }

      // Read auth token
      if (!safeStorage.isEncryptionAvailable()) {
        throw new Error('Encryption is not available')
      }

      // Check expiry first
      try {
        const expiryData = await fs.readFile(getTokenExpiryPath(), 'utf-8')
        const { expiresAt } = JSON.parse(expiryData)
        if (Date.now() > expiresAt) {
          throw new Error('Session expired — please log in again')
        }
      } catch (e) {
        if (e instanceof Error && e.message.includes('Session expired')) throw e
        // No expiry file — proceed with token
      }

      let token: string
      try {
        const encrypted = await fs.readFile(getTokenPath())
        token = safeStorage.decryptString(encrypted)
      } catch {
        throw new Error('Not authenticated')
      }

      // Call worker API
      const response = await fetch(`${WORKER_URL}/api/clerk/user/${encodeURIComponent(userId)}`, {
        headers: { Authorization: `Bearer ${token}` }
      })

      if (response.status === 401) {
        throw new Error('Session expired — please log in again')
      }

      if (!response.ok) {
        const body = await response.text().catch(() => '')
        throw new Error(`Failed to get user (${response.status}): ${body}`)
      }

      const user = await response.json()

      // Cache user profile locally
      await fs.writeFile(getUserStorePath(), JSON.stringify(user, null, 2))

      return user
    } catch (error) {
      if (error instanceof Error) throw error
      throw new Error(`Failed to get user: ${String(error)}`)
    }
  })

  // ── Auth debug logging ────────────────────────────────────────────

  ipcMain.handle(
    'auth:logDebug',
    async (_event, state: string, step: string, data?: string, error?: string) => {
      try {
        const payload: Record<string, unknown> = { state, step, source: 'electron-ts' }
        if (data) {
          try {
            payload.data = JSON.parse(data)
          } catch {
            payload.data = data
          }
        }
        if (error) {
          payload.error = error
        }

        // Fire and forget — don't block the caller
        void fetch(`${WORKER_URL}/api/auth/debug`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        }).catch(() => {
          // Silently ignore debug logging failures
        })
      } catch {
        // Never throw from debug logging
      }
    }
  )

  ipcMain.handle('auth:getDebug', async (_event, state: string) => {
    try {
      const response = await fetch(`${WORKER_URL}/api/auth/debug/${encodeURIComponent(state)}`)
      if (!response.ok) {
        throw new Error(`Debug fetch failed (${response.status})`)
      }
      const text = await response.text()
      try {
        return JSON.parse(text)
      } catch {
        return []
      }
    } catch (error) {
      throw new Error(
        `Failed to get auth debug: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
