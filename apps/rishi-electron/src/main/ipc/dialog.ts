import { dialog, BrowserWindow } from 'electron'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

export function registerDialogHandlers(): void {
  handle('dialog:showOpen', async (_event, options) => {
    try {
      const focusedWindow = BrowserWindow.getFocusedWindow()
      const result = focusedWindow
        ? await dialog.showOpenDialog(focusedWindow, options)
        : await dialog.showOpenDialog(options)

      return {
        filePaths: result.filePaths
      }
    } catch (error) {
      throw new Error(`Failed to show open dialog: ${errorMessage(error)}`)
    }
  })
}
