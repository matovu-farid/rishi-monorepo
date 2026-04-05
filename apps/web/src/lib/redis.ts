"use server"

import { Redis } from '@upstash/redis'
const redis = Redis.fromEnv()

export async function saveUser(userId: string, state: string) {
  await redis.set(`auth:state:${state}`, userId, { ex: 600 }) // 10 minute TTL
}
