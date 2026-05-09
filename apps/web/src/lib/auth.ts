// The web app does NOT host a Better Auth instance — the worker does. This file
// only exists for any server actions that need the worker's API base URL.
// Most code should import from auth-client.ts instead.
export const BETTER_AUTH_BASE_URL =
  process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"
