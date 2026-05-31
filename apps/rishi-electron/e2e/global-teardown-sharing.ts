import { stopWranglerDev } from './helpers/wrangler-dev'

export default async function globalTeardown(): Promise<void> {
  console.log('[sharing teardown] Stopping wrangler dev…')
  stopWranglerDev()
}
