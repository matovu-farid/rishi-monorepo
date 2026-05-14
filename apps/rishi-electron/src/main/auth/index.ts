import { BrowserWindow } from 'electron'
import { authService } from './auth-service'
import { handle } from '../../preload/ipc-contract'

export function registerAuthIpc(_getMainWindow: () => BrowserWindow | null): void {
  // Hydrate stored session on app start
  void authService.hydrate()

  // Broadcast changes to all renderer processes
  authService.onChange((user) => {
    for (const win of BrowserWindow.getAllWindows()) {
      win.webContents.send('session-changed', user)
    }
  })

  handle('auth:start-magic-link', async (_evt, email) => {
    await authService.startMagicLink(email)
  })

  handle('auth:start-google', async () => {
    await authService.startGoogleSignIn()
  })

  handle('auth:get-session', () => authService.getUser())

  handle('auth:sign-out', async () => {
    await authService.signOut()
  })

  handle('auth:delete-account', async () => {
    await authService.deleteAccount()
  })

  handle('auth:get-token', async () => await authService.getSessionToken())
}

export { authService } from './auth-service'
