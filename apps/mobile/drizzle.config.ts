import type { Config } from 'drizzle-kit'

export default {
  dialect: 'sqlite',
  driver: 'expo',
  schema: '../../packages/shared/src/schema.ts',
  out: './drizzle',
} satisfies Config
