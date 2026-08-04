import {
  adjectives,
  nouns,
  uniqueUsernameGenerator,
} from "unique-username-generator";
import { eq } from "drizzle-orm";
import type { WorkerDb } from "./db/drizzle";
import { usernames } from "./db/schema";

const MAX_USERNAME_ALLOCATION_ATTEMPTS = 8;

type UsernameGenerator = (options: {
  dictionaries: string[][];
  style: "lowerCase";
  separator: string;
  randomDigits: number;
}) => string;

let generator: UsernameGenerator = uniqueUsernameGenerator;

export class UsernameAllocationError extends Error {
  readonly code = "USERNAME_UNAVAILABLE" as const;

  constructor() {
    super("Could not allocate a username");
    this.name = "UsernameAllocationError";
  }
}

export function isUsernameAllocationError(error: unknown): boolean {
  const seen = new Set<unknown>();
  const visit = (value: unknown): boolean => {
    if (!value || seen.has(value)) return false;
    seen.add(value);
    if (value instanceof UsernameAllocationError) return true;
    if (typeof value === "object") {
      const record = value as Record<string, unknown>;
      if (record.code === "USERNAME_UNAVAILABLE" || record.name === "UsernameAllocationError") return true;
      if (visit(record.cause) || visit(record.error)) return true;
    }
    const text = String(value);
    return text.includes("USERNAME_UNAVAILABLE") || text.includes("UsernameAllocationError");
  };
  return visit(error);
}

export function setUsernameGeneratorForTests(next: UsernameGenerator): () => void {
  const previous = generator;
  generator = next;
  return () => {
    generator = previous;
  };
}

export function normalizeUsername(value: string): string {
  return value.trim().toLowerCase();
}

export function validateUsername(value: string):
  | { ok: true; value: string }
  | { ok: false; message: string } {
  const normalized = normalizeUsername(value);
  if (!/^[a-z0-9](?:[a-z0-9_]{1,28}[a-z0-9])$/.test(normalized)) {
    return {
      ok: false,
      message: "Username must be 3–30 characters and contain only letters, numbers, or underscores",
    };
  }
  return { ok: true, value: normalized };
}

export function generateUsernameCandidate(_seed: string): string {
  return normalizeUsername(generator({
    dictionaries: [adjectives, nouns],
    style: "lowerCase",
    separator: "",
    randomDigits: 3,
  }));
}

export function isUsernameConflict(error: unknown): boolean {
  const messages: string[] = [];
  let current: unknown = error;
  for (let depth = 0; current && depth < 4; depth += 1) {
    if (current instanceof Error) {
      messages.push(current.message);
      current = current.cause;
    } else {
      messages.push(String(current));
      break;
    }
  }
  return messages.some((message) =>
    message.includes("UNIQUE constraint failed: usernames.username") ||
    message.includes("usernames.username") && message.toLowerCase().includes("unique"),
  );
}

export async function ensureUsername(
  db: WorkerDb,
  userId: string,
  seed: string,
): Promise<string> {
  const existing = await db.query.usernames.findFirst({ where: { userId } });
  if (existing) return existing.username;

  for (let attempt = 0; attempt < MAX_USERNAME_ALLOCATION_ATTEMPTS; attempt += 1) {
    const candidate = generateUsernameCandidate(seed);
    const now = new Date();

    await db.insert(usernames).values({
      userId,
      username: candidate,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing();

    const allocated = await db.query.usernames.findFirst({ where: { userId } });
    if (allocated) return allocated.username;
  }

  throw new UsernameAllocationError();
}

export async function updateUsername(
  db: WorkerDb,
  userId: string,
  value: string,
): Promise<string> {
  const result = validateUsername(value);
  if (!result.ok) throw new Error(result.message);
  await db.update(usernames)
    .set({ username: result.value, updatedAt: new Date() })
    .where(eq(usernames.userId, userId));
  return result.value;
}
