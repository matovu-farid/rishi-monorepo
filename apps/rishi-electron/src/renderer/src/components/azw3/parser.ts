/**
 * AZW3 / KF8 parser facade backed by foliate-js. Lives in the renderer because
 * foliate-js relies on browser APIs (DOMParser, Blob, XMLSerializer).
 *
 * Foliate's MOBI module returns a different shape for MOBI vs KF8 books, but
 * both expose:
 *   - book.sections: Array<{ load(): Promise<string /* Blob URL *\/>, createDocument?: () => Promise<Document> }>
 *   - book.metadata: { title, author, ... }
 *   - book.toc?: Array<{ label, href, subitems? }>
 *
 * The Blob URL returned by `section.load()` points to a serialized HTML
 * document that can be set as an `<iframe src=...>` directly.
 */

// foliate-js types are not published; locally narrow to what we use.
export interface FoliateSection {
  id?: number | string
  /** linear === 'no' marks non-spine sections (skip them). */
  linear?: string
  load?: () => Promise<string>
  createDocument?: () => Promise<Document>
  size?: number
}

export interface FoliateTocEntry {
  label: string
  href?: string
  subitems?: FoliateTocEntry[]
}

export interface FoliateBook {
  sections: FoliateSection[]
  metadata?: {
    title?: string | { [lang: string]: string }
    author?: string | string[] | { name: string } | Array<{ name: string }>
  }
  toc?: FoliateTocEntry[]
}

/**
 * Load and parse an AZW3 file from raw bytes. Returns the foliate-js book
 * instance plus a filtered list of renderable sections.
 */
export async function parseAzw3(bytes: ArrayBuffer): Promise<{
  book: FoliateBook
  sections: FoliateSection[]
}> {
  // Wrap the ArrayBuffer in a Blob — foliate-js calls `.slice(...).arrayBuffer()`
  // on the input, both of which Blob supports natively.
  const blob = new Blob([bytes]) as Blob & { arrayBuffer: () => Promise<ArrayBuffer> }

  // Dynamic imports keep these heavy modules out of the main bundle.
  // foliate-js ESM exports are mapped via `"./*.js": "./*.js"` in its package.json.
  const [mobiMod, fflateMod] = await Promise.all([
    import('foliate-js/mobi.js') as Promise<{
      MOBI: new (opts: { unzlib: (data: Uint8Array) => Uint8Array }) => {
        open(file: Blob): Promise<FoliateBook>
      }
    }>,
    import('foliate-js/vendor/fflate.js') as Promise<{ unzlibSync: (data: Uint8Array) => Uint8Array }>
  ])

  const mobi = new mobiMod.MOBI({ unzlib: fflateMod.unzlibSync })
  const book = await mobi.open(blob)

  // KF8 emits "linear: no" placeholders for non-spine entries; drop them so
  // chapter navigation only walks loadable sections.
  const sections = (book.sections || []).filter(
    (s) => typeof s?.load === 'function' && s.linear !== 'no'
  )
  return { book, sections }
}

/** Extract plain text paragraphs from a foliate section for TTS. Returns []
 *  on failure so the caller can keep going. */
export async function extractSectionParagraphs(section: FoliateSection): Promise<string[]> {
  try {
    if (typeof section.createDocument !== 'function') return []
    const doc = await section.createDocument()
    const paragraphs: string[] = []
    const nodes = doc.querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, blockquote')
    nodes.forEach((node) => {
      const text = (node.textContent ?? '').trim()
      if (text.length > 0) paragraphs.push(text)
    })
    return paragraphs
  } catch {
    return []
  }
}
