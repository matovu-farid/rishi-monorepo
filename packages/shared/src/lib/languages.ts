/**
 * ISO-639-1 codes for languages the realtime voice chat supports.
 *
 * Kept short on purpose — each entry must (a) be supported by OpenAI's
 * Realtime API transcription, and (b) be a language we expect a real
 * user to want voice chat in. Adding a code here also requires adding a
 * matching label below.
 *
 * The worker (`workers/worker/src/index.ts`) maintains a parallel list and
 * coerces unknown codes to 'en'. Keep them in sync.
 */
export const ALLOWED_LANGUAGES = [
  'en',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ja',
  'ko',
  'zh',
  'ar',
  'hi',
  'ru'
] as const

export type AllowedLanguage = (typeof ALLOWED_LANGUAGES)[number]

export const DEFAULT_LANGUAGE: AllowedLanguage = 'en'

/**
 * Human-readable language names. The realtime model handles language *names*
 * better than ISO codes in instructions, so we pass these into the system
 * prompt rather than the codes themselves.
 */
export const LANGUAGE_LABELS: Record<AllowedLanguage, string> = {
  en: 'English',
  es: 'Spanish',
  fr: 'French',
  de: 'German',
  it: 'Italian',
  pt: 'Portuguese',
  ja: 'Japanese',
  ko: 'Korean',
  zh: 'Chinese',
  ar: 'Arabic',
  hi: 'Hindi',
  ru: 'Russian'
}

export function isAllowedLanguage(value: unknown): value is AllowedLanguage {
  return typeof value === 'string' && (ALLOWED_LANGUAGES as readonly string[]).includes(value)
}
