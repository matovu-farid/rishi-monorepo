import { sql } from "drizzle-orm";
import { userApiUsage } from "@rishi/shared/schema";
import { createDb } from "../db/drizzle";

export type ApiUsageMetric = "voiceChat" | "tts";

export async function incrementApiUsage(
  env: Env,
  userId: string,
  metric: ApiUsageMetric,
): Promise<void> {
  const now = Date.now();
  const db = createDb(env.DB);

  if (metric === "voiceChat") {
    await db
      .insert(userApiUsage)
      .values({
        userId,
        voiceChatRequests: 1,
        ttsRequests: 0,
        createdAt: now,
        updatedAt: now,
      })
      .onConflictDoUpdate({
        target: userApiUsage.userId,
        set: {
          voiceChatRequests: sql`${userApiUsage.voiceChatRequests} + 1`,
          updatedAt: now,
        },
      })
      .run();
    return;
  }

  if (metric === "tts") {
    await db
      .insert(userApiUsage)
      .values({
        userId,
        voiceChatRequests: 0,
        ttsRequests: 1,
        createdAt: now,
        updatedAt: now,
      })
      .onConflictDoUpdate({
        target: userApiUsage.userId,
        set: {
          ttsRequests: sql`${userApiUsage.ttsRequests} + 1`,
          updatedAt: now,
        },
      })
      .run();
    return;
  }

  throw new Error(`Unsupported API usage metric: ${String(metric)}`);
}
