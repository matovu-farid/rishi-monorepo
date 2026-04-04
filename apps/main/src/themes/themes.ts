import { Theme, ThemeType } from './common'
import grayReaderTheme from './grayReaderTheme'
import whiteReaderTheme from './whiteReaderTheme'
import yellowReaderTheme from './yellowReaderTheme'

export const whiteTheme: Theme = {
  readerTheme: whiteReaderTheme,
  background: whiteReaderTheme.background,
  color: whiteReaderTheme.color
}

export const grayTheme: Theme = {
  readerTheme: grayReaderTheme,
  background: grayReaderTheme.background,
  color: grayReaderTheme.color
}

export const yellowTheme: Theme = {
  readerTheme: yellowReaderTheme,
  background: yellowReaderTheme.background,
  color: yellowReaderTheme.color
}

export const themes: Record<ThemeType, Theme> = {
  [ThemeType.White]: whiteTheme,
  [ThemeType.Dark]: grayTheme,
  [ThemeType.Yellow]: yellowTheme
}
