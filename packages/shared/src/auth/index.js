/**
 * Convenience barrel for the shared auth helpers.
 *
 * Use a specific subpath import (`@rishi/shared/auth/pkce`) when you only
 * need one helper — keeps tree-shaking obvious. The barrel exists so callers
 * can write `import { startAuthSession, generatePkcePair } from '@rishi/shared/auth'`
 * when they need both.
 */
export * from './pkce';
export * from './startAuthSession';
