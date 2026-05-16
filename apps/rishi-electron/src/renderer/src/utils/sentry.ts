import * as Sentry from '@sentry/electron/renderer'

const DSN =
  'https://37b935f34d09bb053baeff3a28d6b9d1@o4510586781958144.ingest.de.sentry.io/4511372584747088'

let initialized = false

export function initSentry(): void {
  if (initialized) return
  initialized = true

  if (!import.meta.env.PROD) return

  Sentry.init({
    dsn: DSN,
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
