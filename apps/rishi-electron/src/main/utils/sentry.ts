import { app } from 'electron'
import * as Sentry from '@sentry/electron/main'

const DSN =
  process.env.SENTRY_DSN ||
  'https://79d31f9f084402224dc303f699941691@o4510586781958144.ingest.de.sentry.io/4510586797555792'

let initialized = false

export function initMainSentry(): void {
  if (initialized) return
  initialized = true

  Sentry.init({
    dsn: DSN,
    release: `rishi-electron@${app.getVersion()}`,
    environment: app.isPackaged ? 'production' : 'development',
    tracesSampleRate: 0.1,
    sendDefaultPii: false
  })
}

export function captureError(
  error: unknown,
  context?: Record<string, unknown>
): void {
  const err = error instanceof Error ? error : new Error(String(error))
  Sentry.withScope((scope) => {
    if (context) {
      scope.setContext('extra', context)
      if (typeof context.operation === 'string') scope.setTag('operation', context.operation)
      if (typeof context.step === 'string') scope.setTag('step', context.step)
    }
    Sentry.captureException(err)
  })
}
