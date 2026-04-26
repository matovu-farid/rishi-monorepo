import { ipcMain, dialog, BrowserWindow } from 'electron'

export function registerDialogHandlers(): void {
  ipcMain.handle('dialog:showOpen', async (_event, options: Electron.OpenDialogOptions) => {
    try {
      const focusedWindow = BrowserWindow.getFocusedWindow()
      const result = focusedWindow
        ? await dialog.showOpenDialog(focusedWindow, options)
        : await dialog.showOpenDialog(options)

      return {
        filePaths: result.filePaths
      }
    } catch (error) {
      throw new Error(
        `Failed to show open dialog: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
