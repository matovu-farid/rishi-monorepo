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
 *
 * Each section is returned to the renderer whole; the renderer applies
 * viewport-snapped CSS column pagination to the iframe document (see
 * `reader-styles.ts` + `Azw3View.tsx`). The legacy word-count pagination
 * helper (`paginateSection`) is still exported for unit tests and is
 * available for callers that want explicit per-page section objects.
 */

// foliate-js types are not published; locally narrow to what we use.
export interface FoliateSection {
  id?: number | string
  /** linear === 'no' marks non-spine sections (skip them). */
  linear?: string
  load?: () => Promise<string>
  createDocument?: () => Promise<Document>
  size?: number
  /**
   * Synthetic flag set on virtual pages produced by `paginateSection`. Used by
   * the consumer to skip per-page work (e.g. embedding) and instead operate on
   * the parent section once. Undefined for native foliate sections.
   */
  virtualGroupId?: string
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
  /** KF8 books store the cover in EXTH metadata, not as a section. Foliate
   *  exposes it via this method when available. */
  getCover?: () => Promise<Blob | undefined>
}

/**
 * Build a synthetic first section whose body is just an `<img>` tag pointing
 * at the cover image's object URL. Exported so it can be unit-tested without
 * spinning up a real MOBI parser.
 */
export function makeCoverSection(coverBlob: Blob): FoliateSection {
  let cachedUrl: string | null = null
  let cachedDoc: Document | null = null

  const buildHtml = (imgUrl: string): string =>
    `<!DOCTYPE html><html><head><meta charset="utf-8"/><title>Cover</title>` +
    `<style>html,body{margin:0;padding:0;}` +
    `body{display:flex;align-items:center;justify-content:center;` +
    `min-height:100vh;background:transparent;}` +
    `img{max-width:100%;max-height:100vh;height:auto;display:block;}` +
    `</style></head><body><img src="${imgUrl}" alt="Cover"/></body></html>`

  return {
    id: 'azw3-cover',
    virtualGroupId: 'azw3-cover',
    load: async (): Promise<string> => {
      if (cachedUrl) return cachedUrl
      const imgUrl = URL.createObjectURL(coverBlob)
      const html = buildHtml(imgUrl)
      cachedUrl = URL.createObjectURL(new Blob([html], { type: 'text/html' }))
      return cachedUrl
    },
    createDocument: async (): Promise<Document> => {
      if (cachedDoc) return cachedDoc
      const imgUrl = URL.createObjectURL(coverBlob)
      cachedDoc = new DOMParser().parseFromString(buildHtml(imgUrl), 'text/html')
      return cachedDoc
    }
  }
}

/** Default words-per-virtual-page when synthesizing pagination. */
export const WORDS_PER_PAGE = 400

/**
 * Load and parse an AZW3 file from raw bytes. Returns the foliate-js book
 * instance plus a filtered list of renderable sections.
 *
 * Each section is returned whole — the renderer loads the full chapter into
 * a single iframe and uses CSS column pagination (driven by
 * `reader-styles.ts`) to paginate it horizontally across the viewport. The
 * renderer is also responsible for calling {@link stripKindleResourceLinks}
 * on the loaded document before rendering (foliate rewrites most kindle:
 * URLs, but some legacy `<link>` references slip through).
 *
 * `opts.wordsPerPage` is kept for backward compatibility with callers (and
 * tests) that still want the legacy word-count pagination; it is no longer
 * used here.
 */
export async function parseAzw3(
  bytes: ArrayBuffer,
  _opts: { wordsPerPage?: number } = {}
): Promise<{ book: FoliateBook; sections: FoliateSection[] }> {
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
  const filtered = (book.sections || []).filter(
    (s) => typeof s?.load === 'function' && s.linear !== 'no'
  )

  // Return each section whole — the renderer column-paginates inside the
  // iframe using viewport-snapped CSS columns. Previously we synthesized
  // virtual word-count pages here; that responsibility now lives in the
  // renderer's iframe load handler.
  const bodySections: FoliateSection[] = filtered

  // KF8 books carry the cover in EXTH metadata, not as a renderable section.
  // Prepend a synthetic cover page so the reader's page 1 matches what other
  // viewers (GroupDocs, Kindle) show. Best-effort: if the file has no cover
  // or foliate throws, just skip — body pages still render.
  const coverBlob = await book.getCover?.().catch(() => undefined)
  const sections = coverBlob ? [makeCoverSection(coverBlob), ...bodySections] : bodySections
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

/**
 * Fetch the section's blob URL produced by `section.load()` and parse the
 * served HTML back into a Document. This sidesteps a foliate-js quirk where
 * the KF8 `createDocument` always parses as XHTML — and on malformed publisher
 * markup that drops the body content — while `loadSection` falls back to HTML.
 */
export async function loadSectionDocument(section: FoliateSection): Promise<Document> {
  if (typeof section.load !== 'function') throw new Error('section has no load()')
  const url = await section.load()
  const res = await fetch(url)
  const text = await res.text()
  const contentType = res.headers.get('content-type') || 'application/xhtml+xml'
  const baseType = (contentType.split(';')[0] || '').trim() as DOMParserSupportedType
  const parser = new DOMParser()
  // Prefer the served content-type; fall back to text/html if XHTML parsing
  // would yield a parsererror (matches foliate's own behaviour).
  let doc = parser.parseFromString(
    text,
    baseType === 'text/html' ? 'text/html' : 'application/xhtml+xml'
  )
  if (doc.querySelector('parsererror') || !doc.documentElement) {
    doc = parser.parseFromString(text, 'text/html')
  }
  return doc
}

/**
 * Remove `<link>` and `<img>` elements whose URLs reference Kindle-internal
 * schemes (`kindle:flow:`, `kindle:embed:`, `kindle:pos:`). These would
 * trigger CSP fetch errors in the iframe without contributing to render —
 * foliate already rewrites them on the section blob path, but legacy
 * stylesheet links sometimes survive. Exported for testing.
 */
export function stripKindleResourceLinks(doc: Document): number {
  let removed = 0
  const candidates = doc.querySelectorAll<HTMLElement>('link[href], img[src]')
  for (const el of Array.from(candidates)) {
    const attr = el.tagName.toLowerCase() === 'link' ? 'href' : 'src'
    const value = el.getAttribute(attr) ?? ''
    if (value.startsWith('kindle:')) {
      el.remove()
      removed += 1
    }
  }
  return removed
}

/** Count whitespace-delimited words in a node's text content. */
function countWords(node: Node): number {
  const text = (node.textContent ?? '').trim()
  if (text.length === 0) return 0
  return text.split(/\s+/).filter(Boolean).length
}

/**
 * Decide the MIME type to serialize a foliate-parsed `Document` back to. The
 * foliate KF8 loader defaults to `application/xhtml+xml` and falls back to
 * `text/html` when XHTML parsing fails. We mirror that by checking the
 * document's own `contentType`, falling back to namespace presence.
 */
function pickDocumentType(doc: Document): string {
  const ct = doc.contentType
  if (ct === 'text/html' || ct === 'application/xhtml+xml') return ct
  // Foliate's parsed XHTML doc has an XHTML namespace on the documentElement;
  // an HTML-parsed doc has `null` for `namespaceURI` on documents created via
  // text/html, but the DOMParser actually sets the XHTML namespace there too.
  // The safe default that matches foliate is application/xhtml+xml.
  return 'application/xhtml+xml'
}

/**
 * Split a single foliate `FoliateSection` into a list of virtual sections, each
 * carrying ~`wordsPerPage` words of body content. Each virtual section keeps
 * the source section's `<html>`/`<head>` (so stylesheet links, embedded styles,
 * and font references continue to apply) and gets its own per-page `<body>`.
 *
 * Returns `[]` if the section has neither `load` nor `createDocument`, the
 * parsed doc has no body, or the body is empty.
 */
export async function paginateSection(
  section: FoliateSection,
  wordsPerPage: number
): Promise<FoliateSection[]> {
  // Prefer the section's *loaded* HTML (via `load()`'s blob URL) over its
  // `createDocument()` output: foliate's KF8 loader falls back to text/html
  // when XHTML parsing trips over malformed publisher markup, but
  // `createDocument` always uses XHTML mode, so it can lose the bulk of the
  // body content. Re-parsing the load blob gives us the same document the
  // reader iframe sees.
  let sourceDoc: Document | null = null
  if (typeof section.load === 'function') {
    sourceDoc = await loadSectionDocument(section).catch(() => null)
  }
  if (!sourceDoc && typeof section.createDocument === 'function') {
    sourceDoc = await section.createDocument().catch(() => null)
  }
  if (!sourceDoc) return []
  // Drop Kindle-internal resource links that the browser can't fetch
  // (`kindle:flow:`, `kindle:embed:`, `kindle:pos:`). Foliate rewrites these
  // when serving section blobs, but stylesheet `<link>` tags slip through and
  // produce CSP errors in the iframe.
  stripKindleResourceLinks(sourceDoc)

  // For XHTML documents `doc.body` returns the HTML-namespaced body, which is
  // null for KF8's serialized output (foliate uses the XHTML namespace). Fall
  // back to a tag-name lookup so we find the body either way.
  const body =
    sourceDoc.body ??
    (sourceDoc.getElementsByTagName('body')[0] as HTMLBodyElement | undefined) ??
    null
  if (!body || body.children.length === 0) return []

  // Pick the deepest container that holds the actual flow of content. Some
  // publishers wrap the entire book in a single `<div>` (or even nested
  // `<div>`s) inside `<body>`, which would otherwise produce a single bucket.
  // Drill in past single-element wrappers until we reach a node with multiple
  // children, or hit something other than a generic block container.
  // `wrapperDepth` records how many levels deep the flow container sits below
  // `<body>` so buildDocument can navigate the cloned body the same way.
  let flow: Element = body
  let wrapperDepth = 0
  while (flow.children.length === 1) {
    const only = flow.children[0]
    const tag = only.tagName.toLowerCase()
    if (tag !== 'div' && tag !== 'section' && tag !== 'article' && tag !== 'main') break
    wrapperDepth += 1
    flow = only
  }
  if (flow.children.length === 0) return []

  const mimeType = pickDocumentType(sourceDoc)
  const serializer = new XMLSerializer()

  // Group flow children into buckets of ~wordsPerPage words.
  // Big single elements (e.g. a single long <pre> block) get their own page
  // even if they exceed the threshold — avoids splitting elements mid-flow
  // and prevents infinite loops on unusual structures.
  const buckets: Element[][] = []
  let current: Element[] = []
  let currentWords = 0

  for (const child of Array.from(flow.children)) {
    const w = countWords(child)
    if (current.length > 0 && currentWords + w > wordsPerPage) {
      buckets.push(current)
      current = []
      currentWords = 0
    }
    current.push(child)
    currentWords += w
    // If this single element already exceeds the threshold by itself, close
    // its bucket here so it becomes its own page.
    if (currentWords >= wordsPerPage) {
      buckets.push(current)
      current = []
      currentWords = 0
    }
  }
  if (current.length > 0) buckets.push(current)

  if (buckets.length === 0) return []
  if (buckets.length === 1) {
    // Only one virtual page would be produced — defer to the original section
    // so its existing blob URL cache is reused.
    return [section]
  }

  // Tag every virtual page with the same group id so consumers can dedupe.
  const groupId = `azw3-virtual-${Math.random().toString(36).slice(2, 10)}`

  // Pre-clone the document skeleton (everything except the flow container's
  // children) ONCE so each virtual page only has to clone its own elements,
  // not the whole 340KB book. Per-page `buildDocument` deep-clones this
  // skeleton (cheap, small DOM) and injects the page elements at the end of
  // the wrapper chain.
  const skeleton = buildSkeleton(sourceDoc, wrapperDepth)

  return buckets.map((elements, index) =>
    makeVirtualSection({
      skeleton,
      elements,
      index,
      mimeType,
      serializer,
      groupId
    })
  )
}

/**
 * Returns a deep clone of the source documentElement with the flow container's
 * children stripped. Stored as a template so per-page `buildDocument` only
 * needs to deep-clone this slim skeleton plus its own page elements.
 */
function buildSkeleton(sourceDoc: Document, wrapperDepth: number): Element {
  const cloned = sourceDoc.documentElement.cloneNode(true) as Element
  const flow = findFlow(cloned, wrapperDepth)
  while (flow.firstChild) flow.removeChild(flow.firstChild)
  return cloned
}

/**
 * Walk down `wrapperDepth` single-child wrappers below the cloned `<body>`,
 * returning the deepest container — the spot where the page's elements go.
 */
function findFlow(html: Element, wrapperDepth: number): Element {
  const body = (html.getElementsByTagName('body')[0] as Element | undefined) ?? html
  let flow: Element = body
  for (let i = 0; i < wrapperDepth; i++) {
    const next = flow.children[0]
    if (!next) break
    flow = next
  }
  return flow
}

/**
 * On a freshly-cloned skeleton, locate the empty wrapper (the flow container
 * whose children were stripped in `buildSkeleton`). We don't need wrapperDepth
 * at call time — the empty wrapper is the first descendant of `<body>` with
 * zero children.
 */
function findEmptyFlow(html: Element): Element {
  const body = (html.getElementsByTagName('body')[0] as Element | undefined) ?? html
  let flow: Element = body
  while (flow.children.length === 1) {
    flow = flow.children[0]
  }
  return flow
}

interface VirtualSectionArgs {
  /** Pre-cloned `<html>` subtree with the flow container's children stripped. */
  skeleton: Element
  elements: Element[]
  index: number
  mimeType: string
  serializer: XMLSerializer
  /** Shared id across pages from the same source section. */
  groupId: string
}

/**
 * Build a `FoliateSection` whose `load()` lazily serializes a virtual document
 * containing only the elements assigned to this page. The blob URL is cached
 * so repeated chapter navigation doesn't reallocate.
 */
function makeVirtualSection(args: VirtualSectionArgs): FoliateSection {
  const { skeleton, elements, index, mimeType, serializer, groupId } = args

  let cachedUrl: string | null = null
  let pageDoc: Document | null = null

  const buildDocument = (): Document => {
    // Clone the pre-built skeleton (cheap — its <body> already has the flow
    // container with no children) and inject this page's elements into the
    // deepest stripped wrapper.
    const clonedHtml = skeleton.cloneNode(true) as Element
    const flow = findEmptyFlow(clonedHtml)
    for (const el of elements) flow.appendChild(el.cloneNode(true))

    const fresh = skeleton.ownerDocument!.implementation.createDocument(
      clonedHtml.namespaceURI,
      clonedHtml.localName,
      null
    )
    fresh.replaceChild(clonedHtml, fresh.documentElement)
    return fresh
  }

  return {
    id: `virt-${groupId}-${index}`,
    virtualGroupId: groupId,
    load: async (): Promise<string> => {
      if (cachedUrl) return cachedUrl
      if (!pageDoc) pageDoc = buildDocument()
      const serialized = serializer.serializeToString(pageDoc)
      cachedUrl = URL.createObjectURL(new Blob([serialized], { type: mimeType }))
      return cachedUrl
    },
    createDocument: async (): Promise<Document> => {
      if (!pageDoc) pageDoc = buildDocument()
      return pageDoc
    }
  }
}
