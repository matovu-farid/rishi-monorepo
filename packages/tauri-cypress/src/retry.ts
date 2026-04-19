export interface RetryOptions {
  timeout: number;
  interval: number;
}

const DEFAULTS: RetryOptions = {
  timeout: 4000,
  interval: 50,
};

/**
 * Retries `fn` until it succeeds or `timeout` expires.
 * Waits `interval` ms between attempts. Throws the last error on timeout.
 */
export async function retry<T>(
  fn: () => T | Promise<T>,
  options?: Partial<RetryOptions>
): Promise<T> {
  const { timeout, interval } = { ...DEFAULTS, ...options };
  const deadline = Date.now() + timeout;
  let lastError: Error | undefined;

  while (Date.now() < deadline) {
    try {
      return await fn();
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      await new Promise((r) => setTimeout(r, Math.min(interval, remaining)));
    }
  }

  throw lastError ?? new Error(`Timed out after ${timeout}ms`);
}
