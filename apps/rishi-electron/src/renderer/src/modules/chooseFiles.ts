/**
 * File picker - Electron version.
 * Uses native dialog via IPC instead of Tauri dialog plugin.
 */
export async function chooseFiles(): Promise<string[]> {
  const result = await window.electron.showOpenDialog({
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: 'Books', extensions: ['epub', 'pdf', 'mobi', 'azw3', 'djvu'] },
      { name: 'EPUB Books', extensions: ['epub'] },
      { name: 'PDF Files', extensions: ['pdf'] },
      { name: 'MOBI Books', extensions: ['mobi', 'azw3'] },
      { name: 'DJVU Documents', extensions: ['djvu'] }
    ]
  })
  return result?.filePaths || []
}
