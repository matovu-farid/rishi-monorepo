import { ReaderTheme } from './commonReader'

export enum ThemeType {
  White = 'white',
  Dark = 'dark',
  Yellow = 'yellow'
}
export interface Theme {
  background: string
  color: string
  readerTheme: ReaderTheme
}
