/** Best-effort debug log to the worker's auth debug endpoint. Never throws. */
export async function logAuthDebug(
  state: string,
  step: string,
  data?: unknown,
  error?: string,
) {
  try {
    const workerUrl = process.env.NEXT_PUBLIC_WORKER_URL ?? "https://rishi-worker.faridmato90.workers.dev";
    await fetch(`${workerUrl}/api/auth/debug`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        state,
        source: "web-client",
        step,
        data: data ?? null,
        error: error ?? null,
      }),
    });
  } catch {
    // swallow — must never block auth flow
  }
}
