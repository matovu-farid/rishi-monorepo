import type { Book } from '@/lib/api'
import { getBook, updateBookCover } from '@/lib/api'
import { revokeCachedCoverUrl } from '@/components/library/coverCache'

export async function updateStoredCoverImage(book: Book) {
  if (book.coverKind && book.coverKind !== 'fallback') return
  // Opportunistic only: if page 1's canvas is already in the DOM (overscan
  // or the user is near the start), capture it. Never seek the reader to
  // page 1 — that would clobber the user's saved reading position.
  const canvas = document.querySelector<HTMLCanvasElement>('[data-page-number="1"] canvas')
  if (!canvas) return

  const blob = await new Promise<Blob | null>((resolve) => {
    canvas.toBlob(resolve)
  })
  if (!blob) return

  await updateCoverImage(blob, book.id)
}

export async function updateCoverImage(blob: Blob, id: number) {
  const book = await getBook({ bookId: id })
  if (!book) return
  // only update it once
  if (book.version && book.version > 0) return
  if (book.kind !== 'pdf') return
  const cover = Array.from(new Uint8Array(await blob.arrayBuffer()))

  await updateBookCover({ bookId: id, newCover: cover })
  // Drop the cached blob URL for this book so the next library mount
  // refetches the freshly-written bytes via getCover(). Without this the
  // library keeps painting the placeholder until full reload (the cache
  // keys on book.id alone and updateBookCover doesn't bump book.version).
  revokeCachedCoverUrl(id)
}
