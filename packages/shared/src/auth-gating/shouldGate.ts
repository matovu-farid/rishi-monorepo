import type { PremiumFeature } from './types'

export function shouldGate(
  user: { id: string } | null,
  _feature: PremiumFeature,
): boolean {
  return user === null
}
