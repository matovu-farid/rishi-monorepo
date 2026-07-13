import { drizzle } from "drizzle-orm/d1";
import { relations } from "./relations";

export function createDb(d1: D1Database) {
  return drizzle(d1, { relations });
}

export type WorkerDb = ReturnType<typeof createDb>;
