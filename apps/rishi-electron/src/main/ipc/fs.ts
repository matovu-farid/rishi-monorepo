import { app } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import JSZip from 'jszip'
import { handle } from '../../preload/ipc-contract.js'

/**
 * Assert that the given file/directory path is inside the app's userData directory.
 * Prevents IPC callers from accessing arbitrary filesystem paths.
 */
function assertSafePath(filePath: string): void {
  const safeBase = app.getPath('userData')
  const resolved = path.resolve(filePath)
  if (!resolved.startsWith(safeBase + path.sep) && resolved !== safeBase) {
    throw new Error('Access denied: path outside app data directory')
  }
}

/** Size thresholds in bytes per format */
const SIZE_LIMITS: Record<string, { warn: number; block: number }> = {
  epub: { warn: 100 * 1024 * 1024, block: 500 * 1024 * 1024 },
  pdf: { warn: 200 * 1024 * 1024, block: 1024 * 1024 * 1024 },
  mobi: { warn: 100 * 1024 * 1024, block: 500 * 1024 * 1024 },
  azw3: { warn: 100 * 1024 * 1024, block: 500 * 1024 * 1024 },
  default: { warn: 100 * 1024 * 1024, block: 500 * 1024 * 1024 }
}

export function registerFsHandlers(): void {
  handle('fs:checkFileSize', async (_event, filePath, format) => {
    try {
      const stat = await fs.stat(filePath)
      const limits = SIZE_LIMITS[format] ?? SIZE_LIMITS.default

      if (stat.size >= limits.block) {
        return 'blocked'
      } else if (stat.size >= limits.warn) {
        return 'warn'
      }
      return 'ok'
    } catch (error) {
      throw new Error(
        `Failed to check file size: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:unzip', async (_event, filePath, outDir) => {
    try {
      const data = await fs.readFile(filePath)
      const zip = await JSZip.loadAsync(data)

      // Ensure output directory exists
      await fs.mkdir(outDir, { recursive: true })

      const resolvedOutDir = path.resolve(outDir)

      for (const [relativePath, file] of Object.entries(zip.files)) {
        // Zip Slip protection: ensure extracted path stays within outDir
        const targetPath = path.resolve(outDir, relativePath)
        if (!targetPath.startsWith(resolvedOutDir + path.sep) && targetPath !== resolvedOutDir) {
          throw new Error(`Zip entry "${relativePath}" would escape output directory (Zip Slip)`)
        }

        if (file.dir) {
          await fs.mkdir(targetPath, { recursive: true })
        } else {
          await fs.mkdir(path.dirname(targetPath), { recursive: true })
          const content = await file.async('nodebuffer')
          await fs.writeFile(targetPath, content)
        }
      }

      return outDir
    } catch (error) {
      throw new Error(`Failed to unzip: ${error instanceof Error ? error.message : String(error)}`)
    }
  })

  handle('fs:copyFile', async (_event, src, dest) => {
    try {
      await fs.copyFile(src, dest)
    } catch (error) {
      throw new Error(
        `Failed to copy file: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:getAppDataPath', () => {
    try {
      return app.getPath('userData')
    } catch (error) {
      throw new Error(
        `Failed to get app data path: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:readFile', async (_event, filePath) => {
    try {
      // Return the Node.js Buffer directly - Electron's IPC serializes it
      // as a Uint8Array on the renderer side via structured clone
      const buf = await fs.readFile(filePath)
      // Convert to ArrayBuffer for clean serialization across IPC
      return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)
    } catch (error) {
      throw new Error(
        `Failed to read file "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:writeFile', async (_event, filePath, data) => {
    try {
      const buffer =
        data instanceof Uint8Array
          ? data
          : data instanceof ArrayBuffer
            ? Buffer.from(data)
            : Buffer.from(data)
      await fs.writeFile(filePath, buffer)
    } catch (error) {
      throw new Error(
        `Failed to write file "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:exists', async (_event, filePath) => {
    try {
      await fs.access(filePath)
      return true
    } catch {
      return false
    }
  })

  handle('fs:mkdir', async (_event, dirPath) => {
    try {
      await fs.mkdir(dirPath, { recursive: true })
    } catch (error) {
      throw new Error(
        `Failed to create directory "${dirPath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:readDir', async (_event, dirPath) => {
    try {
      assertSafePath(dirPath)
      const entries = await fs.readdir(dirPath)
      return entries
    } catch (error) {
      throw new Error(
        `Failed to read directory "${dirPath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:removeFile', async (_event, filePath) => {
    try {
      assertSafePath(filePath)
      await fs.rm(filePath, { recursive: true, force: true })
    } catch (error) {
      throw new Error(
        `Failed to remove "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('fs:getDirSize', async (_event, dirPath) => {
    try {
      assertSafePath(dirPath)
      return await getDirectorySize(dirPath)
    } catch {
      return 0
    }
  })

  handle('fs:getCacheFileStats', async (_event, dirPath) => {
    try {
      assertSafePath(dirPath)
      return await collectFileStats(dirPath)
    } catch {
      return []
    }
  })
}

/** Recursively compute total size of all files in a directory. */
async function getDirectorySize(dirPath: string): Promise<number> {
  let totalSize = 0
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true })
    for (const entry of entries) {
      const entryPath = path.join(dirPath, entry.name)
      if (entry.isDirectory()) {
        totalSize += await getDirectorySize(entryPath)
      } else {
        const stat = await fs.stat(entryPath)
        totalSize += stat.size
      }
    }
  } catch {
    // Directory may not exist or be inaccessible
  }
  return totalSize
}

/** Recursively collect file path, size, and mtimeMs for cache cleanup. */
async function collectFileStats(
  dirPath: string
): Promise<Array<{ path: string; size: number; mtimeMs: number }>> {
  const results: Array<{ path: string; size: number; mtimeMs: number }> = []
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true })
    for (const entry of entries) {
      const entryPath = path.join(dirPath, entry.name)
      if (entry.isDirectory()) {
        const subResults = await collectFileStats(entryPath)
        results.push(...subResults)
      } else {
        const stat = await fs.stat(entryPath)
        results.push({
          path: entryPath,
          size: stat.size,
          mtimeMs: stat.mtimeMs
        })
      }
    }
  } catch {
    // Directory may not exist
  }
  return results
}
