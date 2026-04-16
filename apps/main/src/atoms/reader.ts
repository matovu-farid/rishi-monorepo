// apps/main/src/atoms/reader.ts
import { atomWithStorage } from 'jotai/utils';
import type { FontSettings } from '@/components/reader/renderers/types';

export const fontSettingsAtom = atomWithStorage<FontSettings>('reader.fontSettings', {
  family: 'Georgia, serif',
  size: 18,
  lineHeight: 1.6,
});

export const invertedDarkModeAtom = atomWithStorage<boolean>('reader.invertedDarkMode', false);
