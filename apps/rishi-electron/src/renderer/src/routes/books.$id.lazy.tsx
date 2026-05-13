import Loader from '@/components/Loader'
import { useQuery } from '@tanstack/react-query'
import { createLazyFileRoute } from '@tanstack/react-router'
import React, { useEffect } from 'react'
import { usePdfStore, BookNavigationState } from '@/stores/pdfStore'
import { useEpubStore } from '@/stores/epubStore'
import { usePageTracker } from '@/modules/epub-page-tracker'
import { getBook, convertFileSrc } from '@/lib/api'

// Lazy-loaded format viewers
const PdfView = React.lazy(() => import('@/components/pdf/PdfView'))
const EpubView = React.lazy(() => import('@/components/epub/EpubView'))
const MobiView = React.lazy(() => import('@/components/mobi/MobiView'))
const Azw3View = React.lazy(() => import('@/components/azw3/Azw3View'))

export const Route = createLazyFileRoute('/books/$id')({
  component: () => <BookView />
})

function BookView(): React.JSX.Element {
  const { id } = Route.useParams() as { id: string }
  const setBook = usePdfStore((s) => s.setBook)

  const {
    isPending,
    error,
    data: book,
    isError
  } = useQuery({
    queryKey: ['book', id],
    queryFn: async () => {
      const book = await getBook({ bookId: Number(id) })
      if (!book) throw new Error('Book not found')
      setBook(book)
      return book
    },
    // Keep the metadata around so reopening within a session is instant.
    // Bound by gcTime so unused entries eventually drop.
    staleTime: Infinity,
    gcTime: 5 * 60 * 1000
  })

  const setBookNavigationState = usePdfStore((s) => s.setBookNavigationState)
  useEffect(() => {
    return () => {
      setBookNavigationState(BookNavigationState.Idle)
      setBook(null)
      useEpubStore.getState().reset()
      usePageTracker.getState().reset()
    }
  }, [])

  if (isError) {
    return <div className="w-full h-full place-items-center grid">{error.message}</div>
  }
  if (isPending) {
    return (
      <div className="w-full h-screen place-items-center grid">
        <Loader />
      </div>
    )
  }

  return (
    <React.Suspense
      fallback={
        <div className="w-full h-screen grid place-items-center">
          <Loader />
        </div>
      }
    >
      {book?.kind === 'pdf' && (
        <PdfView filepath={convertFileSrc(book.filepath)} key={book.id.toString()} book={book} />
      )}
      {book?.kind === 'epub' && <EpubView key={book.id} book={book} />}
      {book?.kind === 'mobi' && <MobiView key={book.id} book={book} />}
      {book?.kind === 'azw3' && <Azw3View key={book.id} book={book} />}
    </React.Suspense>
  )
}
