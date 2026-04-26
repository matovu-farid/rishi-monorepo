export function initSentry(): void {
  // Sentry initialization for Electron
  // @sentry/electron would be configured here
  console.log('[sentry] Initialized (stub)')
}

export function captureError(error: unknown, context?: Record<string, unknown>): void {
  console.error('[sentry]', error, context)
}
