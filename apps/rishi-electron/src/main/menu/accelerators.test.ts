import { describe, it, expect } from 'vitest'
import { ACCELERATORS } from './accelerators'

describe('ACCELERATORS', () => {
  it('uses CmdOrCtrl prefix so Electron does the OS mapping', () => {
    expect(ACCELERATORS.importBook).toBe('CmdOrCtrl+O')
    expect(ACCELERATORS.closeWindow).toBe('CmdOrCtrl+W')
    expect(ACCELERATORS.focusLibrary).toBe('CmdOrCtrl+1')
    expect(ACCELERATORS.toggleTheme).toBe('CmdOrCtrl+Shift+T')
    expect(ACCELERATORS.toggleTOC).toBe('CmdOrCtrl+T')
    expect(ACCELERATORS.toggleThumbnails).toBe('CmdOrCtrl+\\')
    expect(ACCELERATORS.toggleDualPage).toBe('CmdOrCtrl+Shift+D')
    expect(ACCELERATORS.addBookmark).toBe('CmdOrCtrl+D')
    expect(ACCELERATORS.readAloud).toBe('CmdOrCtrl+R')
    expect(ACCELERATORS.voiceChat).toBe('CmdOrCtrl+Shift+V')
    expect(ACCELERATORS.openChat).toBe('CmdOrCtrl+K')
    expect(ACCELERATORS.readAloudFromSelection).toBe('CmdOrCtrl+Shift+L')
  })
})
