import type { BookDataParsed, BookFormat, FormatsIpc } from './types'

export class UnsupportedFormatError extends Error {
  readonly extension: string
  constructor(extension: string) {
    super(`Unsupported format: .${extension}`)
    this.extension = extension
    this.name = 'UnsupportedFormatError'
  }
}

/** Resolve the lowercase extension (no leading dot) from a file path. */
export function extOf(filePath: string): string {
  return filePath.split('.').pop()?.toLowerCase() ?? ''
}

/** Map a normalized extension to the BookFormat tag, or null if unsupported. */
export function formatFor(extension: string): BookFormat | null {
  switch (extension) {
    case 'epub':
      return 'epub'
    case 'pdf':
      return 'pdf'
    case 'mobi':
      return 'mobi'
    case 'azw3':
      return 'azw3'
    case 'djvu':
      return 'djvu'
    default:
      return null
  }
}

export interface DispatchResult {
  format: BookFormat
  data: BookDataParsed
}

/**
 * Internal dispatcher: pick the right `FormatsIpc` method by extension and
 * return the parsed shape plus the normalized format tag. Throws
 * `UnsupportedFormatError` for unknown extensions.
 */
export async function dispatchFormatExtraction(
  formats: FormatsIpc,
  filePath: string
): Promise<DispatchResult> {
  const extension = extOf(filePath)
  const format = formatFor(extension)
  if (format === null) throw new UnsupportedFormatError(extension)

  if (format === 'epub') return { format, data: await formats.getBookData(filePath) }
  if (format === 'pdf') return { format, data: await formats.getPdfData(filePath) }
  if (format === 'mobi' || format === 'azw3')
    return { format, data: await formats.getMobiData(filePath) }
  // format === 'djvu'
  return { format, data: await formats.getDjvuData(filePath) }
}
