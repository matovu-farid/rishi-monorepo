"use server"

import { Redis } from '@upstash/redis'
import { auth } from '@clerk/nextjs/server'

const redis = Redis.fromEnv({ enableAutoPipelining: false })

export async function saveUser(userId: string, state: string, codeChallenge: string) {
  const { userId: authedUserId } = await auth()
  if (!authedUserId || authedUserId !== userId) {
    throw new Error('Unauthorized: userId does not match authenticated user')
  }

  // Store auth flow data with status tracking (includes code_challenge for PKCE verification)
  await redis.set(`auth:state:${state}`, JSON.stringify({
    userId,
    status: 'authenticated',
    retryCount: 0,
    createdAt: Date.now(),
    codeChallenge,
  }), { ex: 600 }) // 10 minute TTL

  // Best-effort logging — must not block the auth flow
  try {
    await redis.lpush(`auth:log:${state}`, JSON.stringify({
      step: 'web_authenticated',
      timestamp: Date.now(),
    }))
    await redis.expire(`auth:log:${state}`, 3600) // 1 hour TTL for logs
  } catch (e) {
    console.error('Auth logging failed (non-critical):', e)
  }
}
