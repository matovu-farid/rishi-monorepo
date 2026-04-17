"use server"

import { Redis } from '@upstash/redis'
import { auth } from '@clerk/nextjs/server'

const redis = Redis.fromEnv({ enableAutoPipelining: false })

/** Best-effort debug log to Redis. Never throws. */
async function debugLog(state: string, step: string, data?: unknown, error?: string) {
  try {
    const now = Date.now()
    await redis.rpush(`auth:debug:${state}`, JSON.stringify({
      source: 'web-server',
      step,
      data: data ?? null,
      error: error ?? null,
      timestamp: now,
      ts: new Date().toISOString(),
    }))
    await redis.expire(`auth:debug:${state}`, 7200)
    // Track in global index for discoverability
    await redis.zadd('auth:debug:_index', { score: now, member: state })
    await redis.expire('auth:debug:_index', 7200)
  } catch {
    // swallow
  }
}

export async function saveUser(userId: string, state: string, codeChallenge: string) {
  await debugLog(state, 'saveUser_called', {
    userId: userId.slice(0, 10) + '...',
    challengeLen: codeChallenge.length,
  })

  const { userId: authedUserId } = await auth()
  await debugLog(state, 'saveUser_auth_checked', {
    authedUserId: authedUserId ? authedUserId.slice(0, 10) + '...' : null,
    match: authedUserId === userId,
  })

  if (!authedUserId || authedUserId !== userId) {
    await debugLog(state, 'saveUser_unauthorized', null, 'userId mismatch')
    throw new Error('Unauthorized: userId does not match authenticated user')
  }

  // Store auth flow data with status tracking (includes code_challenge for PKCE verification)
  // NX prevents overwrites if the state was already claimed by another call
  const wasSet = await redis.set(`auth:state:${state}`, JSON.stringify({
    userId,
    status: 'authenticated',
    retryCount: 0,
    createdAt: Date.now(),
    codeChallenge,
  }), { ex: 600, nx: true }) // 10 minute TTL, set-if-not-exists

  await debugLog(state, 'saveUser_redis_set', { wasSet, nx: true })

  if (!wasSet) {
    // State already exists — verify it belongs to the same user
    const existing = await redis.get(`auth:state:${state}`) as string | null
    if (existing) {
      const parsed = JSON.parse(existing)
      if (parsed.userId !== userId) {
        await debugLog(state, 'saveUser_state_claimed_by_other', null, 'different user')
        throw new Error('Auth state already claimed by another user')
      }
    }
    await debugLog(state, 'saveUser_same_user_retry')
    // Same user retrying — allow silently
    return
  }

  await debugLog(state, 'saveUser_success')

  // Best-effort logging — must not block the auth flow
  try {
    await redis.lpush(`auth:log:${state}`, JSON.stringify({
      step: 'web_authenticated',
      timestamp: Date.now(),
    }))
    await redis.expire(`auth:log:${state}`, 3600) // 1 hour TTL
  } catch (e) {
    console.error('Auth logging failed (non-critical):', e)
  }
}
