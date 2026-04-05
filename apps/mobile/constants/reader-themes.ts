import { ReaderTheme, ThemeName } from '@/types/book'

export const READER_THEMES: Record<ThemeName, ReaderTheme> = {
  white: {
    name: 'white',
    label: 'Light',
    background: '#FFFFFF',
    color: '#000000',
    toolbarBg: 'rgba(255, 255, 255, 0.95)',
    toolbarText: '#000000',
    swatchColor: '#FFFFFF',
    swatchBorder: '#D1D5DB',
  },
  dark: {
    name: 'dark',
    label: 'Dark',
    background: 'rgb(48, 48, 50)',
    color: 'rgb(184, 184, 185)',
    toolbarBg: 'rgba(48, 48, 50, 0.95)',
    toolbarText: 'rgb(184, 184, 185)',
    swatchColor: '#303032',
    swatchBorder: '#303032',
  },
  yellow: {
    name: 'yellow',
    label: 'Sepia',
    background: 'rgb(246, 240, 226)',
    color: 'rgb(43, 42, 40)',
    toolbarBg: 'rgba(246, 240, 226, 0.95)',
    toolbarText: 'rgb(43, 42, 40)',
    swatchColor: '#F6F0E2',
    swatchBorder: '#F6F0E2',
  },
}

export const DEFAULT_THEME = READER_THEMES.white
