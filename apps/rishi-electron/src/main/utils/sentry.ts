import { app } from 'electron'
import * as Sentry from '@sentry/electron/main'

// `process.env.SENTRY_DSN` may be `undefined` *or* an empty string when the
// env var is unset in CI/local builds — both cases should fall back to the
// hard-coded production DSN, so we normalise empty strings to `undefined`
// before applying the nullish coalesce.
const envDsn = process.env.SENTRY_DSN === '' ? undefined : process.env.SENTRY_DSN
const DSN =
  envDsn ??
  'https://37b935f34d09bb053baeff3a28d6b9d1@o4510586781958144.ingest.de.sentry.io/4511372584747088'

let initialized = false

export function initMainSentry(): void {
  if (initialized) return
  initialized = true

  if (!app.isPackaged) return

  Sentry.init({
    dsn: DSN,
    release: `rishi-electron@${app.getVersion()}`,
    environment: 'production',
    tracesSampleRate: 0.1,
    sendDefaultPii: false
  })
}

export function captureError(error: unknown, context?: Record<string, unknown>): void {
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
