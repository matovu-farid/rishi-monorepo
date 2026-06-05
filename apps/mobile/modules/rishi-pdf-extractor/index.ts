import { requireNativeModule } from 'expo-modules-core'

interface RishiPdfExtractorModule {
  hello(): string
}

const Native = requireNativeModule<RishiPdfExtractorModule>('RishiPdfExtractor')

export function hello(): string {
  return Native.hello()
}
