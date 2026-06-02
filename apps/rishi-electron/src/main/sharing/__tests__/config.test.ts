import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getSharingConfig } from '../config.js'

describe('getSharingConfig', () => {
  const savedEnv = { ...process.env }

  beforeEach(() => {
    delete process.env.SHARING_WORKER_URL
    delete process.env.RISHI_SHARING_WORKER_URL
    delete process.env.RISHI_SHARING_WS_URL
  })

  afterEach(() => {
    process.env = { ...savedEnv }
  })

  it('falls back to production URLs when no env vars are set', () => {
    const cfg = getSharingConfig()
    expect(cfg.workerBaseUrl).toBe('https://sharing.rishi.fidexa.org')
    expect(cfg.wsBaseUrl).toBe('wss://sharing.rishi.fidexa.org')
  })

  it('reads SHARING_WORKER_URL when set (E2E injection)', () => {
    process.env.SHARING_WORKER_URL = 'http://localhost:8787'
    const cfg = getSharingConfig()
    expect(cfg.workerBaseUrl).toBe('http://localhost:8787')
  })

  it('prefers SHARING_WORKER_URL over RISHI_SHARING_WORKER_URL', () => {
    process.env.SHARING_WORKER_URL = 'http://from-plan3:1'
    process.env.RISHI_SHARING_WORKER_URL = 'http://from-plan2:2'
    const cfg = getSharingConfig()
    expect(cfg.workerBaseUrl).toBe('http://from-plan3:1')
  })

  it('falls back to RISHI_SHARING_WORKER_URL when SHARING_WORKER_URL not set', () => {
    process.env.RISHI_SHARING_WORKER_URL = 'http://only-plan2:3'
    const cfg = getSharingConfig()
    expect(cfg.workerBaseUrl).toBe('http://only-plan2:3')
  })

  it('exposes STUN ice servers list', () => {
    const cfg = getSharingConfig()
    expect(cfg.iceServers.length).toBeGreaterThan(0)
    expect(cfg.iceServers[0].urls).toMatch(/^stun:/)
  })
})
