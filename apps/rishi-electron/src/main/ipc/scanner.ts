import { ipcMain, app, BrowserWindow } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'

const SUPPORTED_EXTENSIONS = new Set(['.pdf', '.epub', '.mobi', '.azw3'])

let scanCancelled = false

function getDefaultBookFolders(): string[] {
  const home = app.getPath('home')
  const documents = app.getPath('documents')
  const downloads = app.getPath('downloads')
  const desktop = app.getPath('desktop')

  const folders = [documents, downloads, desktop]

  if (process.platform === 'darwin') {
    folders.push(path.join(home, 'Library', 'Mobile Documents'))
    folders.push(path.join(home, 'Books'))
  } else if (process.platform === 'win32') {
    folders.push(path.join(home, 'OneDrive', 'Documents'))
  } else {
    folders.push(path.join(home, 'Books'))
  }

  return folders
}

function getMainWindow(): BrowserWindow | null {
  const windows = BrowserWindow.getAllWindows()
  return windows[0] ?? null
}

function sendToRenderer(channel: string, data: unknown): void {
  getMainWindow()?.webContents.send(channel, data)
}

async function walkDirectory(
  dirPath: string,
  visitedPaths: Set<string>,
  onFound: (filepath: string, stat: { size: number }) => void
): Promise<void> {
  if (scanCancelled) return

  let realPath: string
  try {
    realPath = await fs.realpath(dirPath)
  } catch {
    return
  }

  if (visitedPaths.has(realPath)) return
  visitedPaths.add(realPath)

  let entries
  try {
    entries = await fs.readdir(dirPath, { withFileTypes: true })
  } catch {
    return
  }

  // Send progress
  sendToRenderer('scan-progress', {
    folder: dirPath,
    scanned: visitedPaths.size,
    total: 0
  })

  for (const entry of entries) {
    if (scanCancelled) return
    if (entry.name.startsWith('.')) continue

    const fullPath = path.join(dirPath, entry.name)

    if (entry.isDirectory()) {
      const skip = ['node_modules', '.git', '__pycache__', '.Trash', 'Library']
      if (!skip.includes(entry.name)) {
        await walkDirectory(fullPath, visitedPaths, onFound)
      }
    } else if (entry.isFile() || entry.isSymbolicLink()) {
      const ext = path.extname(entry.name).toLowerCase()
      if (SUPPORTED_EXTENSIONS.has(ext)) {
        try {
          const stat = await fs.stat(fullPath)
          onFound(fullPath, { size: stat.size })
        } catch {
          // Skip files we can't stat
        }
      }
    }
  }
}

export function registerScannerHandlers(): void {
  ipcMain.handle('scanner:getDefaultFolders', async () => {
    return getDefaultBookFolders()
  })

  ipcMain.handle('scanner:scan', async (_event, mode: string) => {
    scanCancelled = false
    let count = 0

    const folders = mode === 'full' ? [app.getPath('home')] : getDefaultBookFolders()

    const visitedPaths = new Set<string>()

    for (const folder of folders) {
      if (scanCancelled) break

      try {
        await fs.access(folder)
      } catch {
        continue
      }

      await walkDirectory(folder, visitedPaths, (filepath, stat) => {
        count++
        const ext = path.extname(filepath).toLowerCase().replace('.', '')
        const filename = path.basename(filepath)
        const folderName = path.dirname(filepath)

        // Send each discovered book to the renderer
        sendToRenderer('scan-result', {
          filepath,
          filename,
          title: null, // Could parse metadata but that's slow
          author: null,
          format: ext,
          fileSize: stat.size,
          folder: folderName,
          fileHash: null
        })
      })
    }

    // Signal scan complete
    sendToRenderer('scan-complete', { totalFound: count })
    return count
  })

  ipcMain.handle('scanner:cancel', async () => {
    scanCancelled = true
  })
}
