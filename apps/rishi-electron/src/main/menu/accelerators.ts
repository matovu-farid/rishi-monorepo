export const ACCELERATORS = {
  importBook: 'CmdOrCtrl+O',
  closeWindow: 'CmdOrCtrl+W',
  focusLibrary: 'CmdOrCtrl+1',
  toggleTheme: 'CmdOrCtrl+Shift+T',
  toggleTOC: 'CmdOrCtrl+T',
  toggleThumbnails: 'CmdOrCtrl+\\',
  toggleDualPage: 'CmdOrCtrl+Shift+D',
  addBookmark: 'CmdOrCtrl+D',
  readAloud: 'CmdOrCtrl+R',
  voiceChat: 'CmdOrCtrl+Shift+V',
  openChat: 'CmdOrCtrl+K',
  openSettings: 'CmdOrCtrl+,',
  readAloudFromSelection: 'CmdOrCtrl+Shift+L'
} as const

export type AcceleratorKey = keyof typeof ACCELERATORS
