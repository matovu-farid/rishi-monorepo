"use server"

import { Redis } from '@upstash/redis'
const redis = Redis.fromEnv()

export async function saveUser(userId: string, state: string) {
  await redis.hset(`users`, { [state]: userId })

}
