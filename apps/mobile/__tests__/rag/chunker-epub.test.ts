/**
 * EPUB chunker tests (CG17 — corrupt EPUB handling).
 *
 * `apps/mobile/lib/rag/chunker.ts::extractEpubText` opens an EPUB with
 * JSZip, reads `META-INF/container.xml` for the rootfile pointer, then
 * walks the OPF spine. Three corrupt-file branches log a `console.warn`
 * and return `[]`:
 *
 *   1. Missing `META-INF/container.xml` — early exit.
 *   2. `container.xml` present but missing a `<rootfile full-path="…">`
 *      attribute — early exit.
 *   3. OPF rootfile path present but the referenced file is missing.
 *
 * Behaviour today is "warn and degrade" — `getChunks('book.epub', 'epub')`
 * returns `[]` instead of throwing. These tests pin that contract so a
 * future refactor doesn't silently switch to throwing (which would
 * crash the import flow on malformed EPUBs).
 *
 * Why JSZip is used directly: the chunker imports the real library at
 * runtime (`await import('jszip')`). We build a real zip in-memory per
 * test, base64-encode it, and feed it through the mocked
 * `expo-file-system.readAsStringAsync`.
 */

import JSZip from 'jszip'

// ── expo-file-system mock — returns a per-test base64 fixture ───────────────
const FIXTURE_KEY = '__epub_fixture__'

jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn(async () => {
    const fixture = (global as { [k: string]: unknown })[FIXTURE_KEY]
    if (typeof fixture !== 'string') {
      throw new Error('No EPUB fixture set; tests must seed __epub_fixture__')
    }
    return fixture
  }),
  EncodingType: { Base64: 'base64' },
}))

jest.mock('expo-crypto', () => ({
  randomUUID: () => 'uuid-not-expected-here',
}))

import { getChunks, resetExtractors } from '@/lib/rag/chunker'

async function buildEpubBase64(zipBuilder: (zip: JSZip) => void): Promise<string> {
  const zip = new JSZip()
  zipBuilder(zip)
  const bytes = (await zip.generateAsync({ type: 'uint8array' })) as Uint8Array
  return Buffer.from(bytes).toString('base64')
}

function silenceWarn(): jest.SpyInstance {
  return jest.spyOn(console, 'warn').mockImplementation(() => {})
}

describe('chunker -> EPUB (CG17: corrupt-file branches)', () => {
  let warnSpy: jest.SpyInstance

  beforeEach(() => {
    resetExtractors()
    warnSpy = silenceWarn()
  })

  afterEach(() => {
    warnSpy.mockRestore()
    delete (global as { [k: string]: unknown })[FIXTURE_KEY]
  })

  it('returns [] for an EPUB missing META-INF/container.xml', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        // Bundle real-looking content but DELIBERATELY omit container.xml.
        zip.file('content.opf', '<package><metadata></metadata></package>')
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-corrupt-1')
    expect(chunks).toEqual([])
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('Missing META-INF/container.xml'),
    )
  })

  it('returns [] for an EPUB whose container.xml lacks a rootfile path', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        zip.file(
          'META-INF/container.xml',
          // Valid XML but with NO rootfile/full-path attribute.
          '<?xml version="1.0"?><container><rootfiles></rootfiles></container>',
        )
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-corrupt-2')
    expect(chunks).toEqual([])
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('Could not find rootfile path'),
    )
  })

  it('returns [] for an EPUB whose container.xml points at a missing OPF file', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        zip.file(
          'META-INF/container.xml',
          '<?xml version="1.0"?><container><rootfiles>' +
            '<rootfile full-path="OEBPS/content.opf"/>' +
            '</rootfiles></container>',
        )
        // No OEBPS/content.opf added.
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-corrupt-3')
    expect(chunks).toEqual([])
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('Could not read OPF file'),
      expect.anything(),
    )
  })

  // H3-02: some EPUB publishers (Sigil-generated, Smashwords) emit
  // spine hrefs that begin with `/` to mean "root of the zip". The
  // shared epub-cover extractor handles this; the chunker did not.
  // Result: spine items get appended to opfDir, the file lookup fails,
  // and the entire book yields zero chunks even though the file is
  // perfectly readable.
  it('returns chunks for an EPUB whose manifest hrefs are absolute (start with /)', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        zip.file(
          'META-INF/container.xml',
          '<?xml version="1.0"?><container><rootfiles>' +
            '<rootfile full-path="OEBPS/content.opf"/>' +
            '</rootfiles></container>',
        )
        zip.file(
          'OEBPS/content.opf',
          // Note: href starts with `/` — root of the zip.
          '<?xml version="1.0"?><package>' +
            '<manifest><item id="c1" href="/OEBPS/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>' +
            '<spine><itemref idref="c1"/></spine>' +
            '</package>',
        )
        zip.file(
          'OEBPS/ch1.xhtml',
          '<html><body><h1>Absolute Href Chapter</h1>' +
            '<p>The text inside an absolute-href EPUB must still chunk. ' +
            'It survives the resolve step because absolute hrefs are root-anchored.</p>' +
            '</body></html>',
        )
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-abs-href')
    expect(chunks.length).toBeGreaterThan(0)
    expect(chunks[0].chapter).toBe('Absolute Href Chapter')
    const joined = chunks.map((c) => c.text).join(' ')
    expect(joined).toContain('absolute-href EPUB')
  })

  // H3-05: extractEpubText's manifest regex required `id` to appear
  // BEFORE `href`. Calibre / Sigil / older editors emit manifest items
  // with `href` before `id`, which made these items invisible to the
  // chunker — the spine referenced them but the lookup map was empty,
  // and `manifestItems.get(idref)` returned undefined for every item.
  // Result: zero chunks for an otherwise valid book.
  it('returns chunks when manifest items have href BEFORE id', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        zip.file(
          'META-INF/container.xml',
          '<?xml version="1.0"?><container><rootfiles>' +
            '<rootfile full-path="OEBPS/content.opf"/>' +
            '</rootfiles></container>',
        )
        zip.file(
          'OEBPS/content.opf',
          // href BEFORE id — order Calibre uses.
          '<?xml version="1.0"?><package>' +
            '<manifest><item href="ch1.xhtml" id="c1" media-type="application/xhtml+xml"/></manifest>' +
            '<spine><itemref idref="c1"/></spine>' +
            '</package>',
        )
        zip.file(
          'OEBPS/ch1.xhtml',
          '<html><body><h1>Calibre Ordering</h1>' +
            '<p>An EPUB whose manifest items put href before id must still chunk. ' +
            'The OPF spec is order-agnostic — the manifest reader must match it.</p>' +
            '</body></html>',
        )
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-href-first')
    expect(chunks.length).toBeGreaterThan(0)
    expect(chunks[0].chapter).toBe('Calibre Ordering')
    const joined = chunks.map((c) => c.text).join(' ')
    expect(joined).toContain('order-agnostic')
  })

  // H3-07: spine items with `../` segments resolved to non-existent
  // paths under the OPF dir; the chunker silently skipped them and
  // emitted zero chunks. KF8 conversions and Sigil templates sometimes
  // place chapters in a sibling directory of the OPF (e.g. OPS dir at
  // root, references like ../Text/ch1.xhtml).
  it('returns chunks for an EPUB with parent ../ segments in spine hrefs', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        zip.file(
          'META-INF/container.xml',
          '<?xml version="1.0"?><container><rootfiles>' +
            '<rootfile full-path="OEBPS/content.opf"/>' +
            '</rootfiles></container>',
        )
        zip.file(
          'OEBPS/content.opf',
          // Chapter sits at Text/ch1.xhtml at the zip root, referenced
          // with ../Text/ch1.xhtml relative to OEBPS/.
          '<?xml version="1.0"?><package>' +
            '<manifest><item id="c1" href="../Text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>' +
            '<spine><itemref idref="c1"/></spine>' +
            '</package>',
        )
        zip.file(
          'Text/ch1.xhtml',
          '<html><body><h1>Parent Segment Chapter</h1>' +
            '<p>The chunker must normalize parent segments to find chapters ' +
            'placed in sibling directories of the OPF.</p>' +
            '</body></html>',
        )
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-parent-segments')
    expect(chunks.length).toBeGreaterThan(0)
    expect(chunks[0].chapter).toBe('Parent Segment Chapter')
    const joined = chunks.map((c) => c.text).join(' ')
    expect(joined).toContain('sibling directories')
  })

  it('returns chunks for a well-formed EPUB (positive control for the same wiring)', async () => {
    ;(global as { [k: string]: unknown })[FIXTURE_KEY] = await buildEpubBase64(
      (zip) => {
        zip.file(
          'META-INF/container.xml',
          '<?xml version="1.0"?><container><rootfiles>' +
            '<rootfile full-path="OEBPS/content.opf"/>' +
            '</rootfiles></container>',
        )
        zip.file(
          'OEBPS/content.opf',
          // Minimum viable OPF: one manifest item, one spine ref.
          '<?xml version="1.0"?><package>' +
            '<manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>' +
            '<spine><itemref idref="c1"/></spine>' +
            '</package>',
        )
        zip.file(
          'OEBPS/ch1.xhtml',
          '<html><body><h1>Chapter One</h1>' +
            '<p>The cat sat on the mat. ' +
            'It was big and quiet. ' +
            'It watched the world go by very carefully and patiently.</p>' +
            '<p>Then the dog ran past. ' +
            'It looked at the cat. ' +
            'They stared at each other for a long quiet patient moment.</p>' +
            '</body></html>',
        )
      },
    )

    const chunks = await getChunks('/fake/book.epub', 'epub', 'book-ok-1')
    expect(chunks.length).toBeGreaterThan(0)
    // Chapter label derived from <h1>.
    expect(chunks[0].chapter).toBe('Chapter One')
    // The body text reached the output.
    const joined = chunks.map((c) => c.text).join(' ')
    expect(joined).toContain('cat sat on the mat')
    expect(joined).toContain('dog ran past')
  })
})
