const EXPLICIT_CORS_ORIGINS = new Set([
  "https://rishi.fidexa.org",
  "https://app.fidexa.org",
  "tauri://localhost",
  "http://tauri.localhost",
  "http://localhost:3000",
  "http://localhost:5173",
  "http://localhost:5174",
  "rishi-electron://",
]);

const LOOPBACK_ORIGIN = /^https?:\/\/(127\.0\.0\.1|localhost):([0-9]{1,5})$/;

export function resolveCorsOrigin(origin: string): string | undefined {
  if (EXPLICIT_CORS_ORIGINS.has(origin)) return origin;

  const match = LOOPBACK_ORIGIN.exec(origin);
  if (!match) return undefined;

  const port = Number(match[2]);
  return port >= 1 && port <= 65_535 ? origin : undefined;
}
