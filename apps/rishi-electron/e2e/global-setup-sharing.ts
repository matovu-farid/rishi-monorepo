import { startWranglerDev } from './helpers/wrangler-dev'

export default async function globalSetup(): Promise<void> {
  console.log('[sharing setup] Starting wrangler dev…')
  const url = await startWranglerDev()
  console.log(`[sharing setup] wrangler dev ready at ${url}`)
}
