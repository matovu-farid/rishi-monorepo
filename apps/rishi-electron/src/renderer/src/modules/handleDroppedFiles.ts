/**
 * Drag-and-drop file path resolution.
 *
 * Why this exists: Electron 32+ removed `File.path`. Renderer code now
 * has to call `webUtils.getPathForFile(file)` via the preload bridge.
 * When that bridge is missing (stale dev build) or returns an empty
 * string (the dropped File wasn't backed by an OS path), the previous
 * inline implementation silently fed `[]` into the import pipeline and
 * the user saw nothing. This helper surfaces those failures as a typed
 * error so the caller can show a toast instead of swallowing them.
 */

export class DroppedFilesError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'DroppedFilesError'
  }
}

export function resolveDroppedFilePaths(
  files: readonly File[],
  getPathForFile: (file: File) => string
): string[] {
  if (files.length === 0) return []

  if (typeof getPathForFile !== 'function') {
    throw new DroppedFilesError(
      "Couldn't read dropped files: the Electron preload bridge is missing `getPathForFile`. Restart the app to pick up the latest preload bundle."
    )
  }

  let resolved: string[]
  try {
    resolved = files.map((f) => getPathForFile(f))
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err)
    throw new DroppedFilesError(`Couldn't read dropped files: ${detail}`)
  }

  const paths = resolved.filter((p) => p.length > 0)
  if (paths.length === 0) {
    throw new DroppedFilesError(
      "Couldn't read the path of the dropped file(s). Try opening them via File → Open instead."
    )
  }
  return paths
}

/**
 * Custom file extractor for react-dropzone. Bypasses `file-selector`, which
 * in secure contexts (Electron renderer) reconstructs Files via
 * `getAsFileSystemHandle().getFile()`. Those reconstructed Files are NOT
 * the originals from the drag event and break Electron's
 * `webUtils.getPathForFile` binding — paths come back as `''`.
 *
 * Returning `dataTransfer.files` directly preserves the original File
 * instances so the preload bridge can resolve their OS paths.
 *
 * Typed as `unknown` to satisfy react-dropzone's `DropEvent` union (it
 * includes both synthetic and native events). We narrow at runtime.
 */
export function getFilesFromDropEvent(event: unknown): Promise<File[]> {
  if (!event || typeof event !== 'object') return Promise.resolve([])

  // Drag-and-drop: `DragEvent` carries `dataTransfer.files`.
  const dt = (event as { dataTransfer?: DataTransfer | null }).dataTransfer
  if (dt?.files.length) {
    return Promise.resolve(Array.from(dt.files))
  }
  // <input type="file"> selection: target has `.files`.
  const target = (event as { target?: EventTarget | null }).target as HTMLInputElement | null
  if (target?.files?.length) {
    return Promise.resolve(Array.from(target.files))
  }
  return Promise.resolve([])
}
