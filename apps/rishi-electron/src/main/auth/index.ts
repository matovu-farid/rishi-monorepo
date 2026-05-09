import { ipcMain, BrowserWindow } from "electron"
import { authService } from "./auth-service"
import { setupDeepLinkHandler, handleUrl, findDeepLinkInArgv } from "./deep-link"

export function registerAuthIpc(getMainWindow: () => BrowserWindow | null): void {
  // Hydrate stored session on app start
  void authService.hydrate()

  // Broadcast changes to all renderer processes
  authService.onChange((user) => {
    for (const win of BrowserWindow.getAllWindows()) {
      win.webContents.send("session-changed", user)
    }
  })

  setupDeepLinkHandler(
    (url) => void authService.handleCallback(url),
    getMainWindow,
  )

  ipcMain.handle("auth:start-magic-link", async (_evt, email: string) => {
    await authService.startMagicLink(email)
  })

  ipcMain.handle("auth:start-google", async () => {
    await authService.startGoogleSignIn()
  })

  ipcMain.handle("auth:get-session", () => authService.getUser())

  ipcMain.handle("auth:sign-out", async () => {
    await authService.signOut()
  })

  ipcMain.handle("auth:delete-account", async () => {
    await authService.deleteAccount()
  })

  ipcMain.handle("auth:get-token", async () => await authService.getSessionToken())
}

export { handleUrl, findDeepLinkInArgv }
export { authService } from "./auth-service"
