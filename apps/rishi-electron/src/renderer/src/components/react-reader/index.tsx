// Core React imports and third-party libraries
import React, { PureComponent } from 'react'
import type { SwipeEventData } from 'react-swipeable'
import { EpubView, type IEpubViewProps } from './epub_viewer'
import type { IEpubViewStyle } from './epub_viewer/style'
import { ReactReaderStyle as defaultStyles, type IReactReaderStyle } from './style'
import type { NavItem, Contents } from 'epubjs'
import type Section from 'epubjs/types/section'
import { SwipeWrapper, NavigationArrows } from './components'
import { ReaderTOC } from '../reader/ReaderTOC'
import { TocItem } from './TocItem'
import type { ParagraphWithCFI } from '../../types'
import { useNavStore } from '../../stores/navStore'

// Search result object containing location and excerpt
type SearchResult = { cfi: string; excerpt: string }

/**
 * Props for ReactReader component
 * Extends EpubViewProps with additional UI and interaction features
 */
export type IReactReaderProps = IEpubViewProps & {
  title?: string
  showToc?: boolean
  readerStyles?: IReactReaderStyle
  epubViewStyles?: IEpubViewStyle
  swipeable?: boolean
  isRTL?: boolean
  pageTurnOnScroll?: boolean
  searchQuery?: string
  contextLength?: number
  onSearchResults?: (results: SearchResult[]) => void
  onPageTextExtracted?: (data: { text: string }) => void
  onPageParagraphsExtracted?: (data: { paragraphs: ParagraphWithCFI[] }) => void
  onNextPageParagraphs?: (data: { paragraphs: ParagraphWithCFI[] }) => void
  onPreviousPageParagraphs?: (data: { paragraphs: ParagraphWithCFI[] }) => void
  bookSyncId?: string
  tocExpanded?: boolean
  onTocExpandedChange?: (expanded: boolean) => void
  hidePrev?: boolean
  onNext?: () => void
  onPrev?: () => void
}

// Component state for ReactReader
type IReactReaderState = {
  isLoaded: boolean
  expandedToc: boolean
  toc: NavItem[]
}

/**
 * ReactReader Component
 * Full-featured EPUB reader with UI controls
 */
export class ReactReader extends PureComponent<IReactReaderProps, IReactReaderState> {
  state: Readonly<IReactReaderState> = {
    isLoaded: false,
    expandedToc: false,
    toc: []
  }

  readerRef = React.createRef<EpubView>()

  constructor(props: IReactReaderProps) {
    super(props)
  }

  toggleToc = () => {
    const { onTocExpandedChange } = this.props
    if (onTocExpandedChange !== undefined) {
      onTocExpandedChange(!this.getExpandedToc())
    } else {
      this.setState({ expandedToc: !this.state.expandedToc })
    }
  }

  getExpandedToc = () => {
    return this.props.tocExpanded ?? this.state.expandedToc
  }

  next = () => {
    if (this.props.onNext) {
      this.props.onNext()
    } else {
      const node = this.readerRef.current
      if (node?.nextPage) {
        node.nextPage()
      }
    }
  }

  prev = () => {
    if (this.props.onPrev) {
      this.props.onPrev()
    } else {
      const node = this.readerRef.current
      if (node?.prevPage) {
        node.prevPage()
      }
    }
  }

  onTocChange = (toc: NavItem[]) => {
    const { tocChanged } = this.props
    this.setState(
      {
        toc: toc
      },
      () => tocChanged?.(toc)
    )
  }

  setLocation = (loc: string) => {
    const send = useNavStore.getState().send
    if (send) {
      send({ type: 'DISPLAY', location: loc })
    }
    const { onTocExpandedChange } = this.props
    if (onTocExpandedChange) {
      onTocExpandedChange(false)
    } else {
      this.setState({ expandedToc: false })
    }
  }

  handleWheel = (event: WheelEvent) => {
    event.preventDefault()

    if (event.deltaY > 0) {
      this.next()
    } else if (event.deltaY < 0) {
      this.prev()
    }
  }

  attachWheelListener = () => {
    if (!this.readerRef.current) return

    const rendition = this.readerRef.current.rendition

    if (rendition) {
      rendition.hooks.content.register((contents: Contents) => {
        const iframeDoc = contents.window.document

        iframeDoc.removeEventListener('wheel', this.handleWheel)
        iframeDoc.addEventListener('wheel', this.handleWheel, {
          passive: false
        })
      })
    }
  }

  searchInBook = async (query?: string) => {
    if (!this.readerRef.current) return
    const rendition = this.readerRef.current?.rendition
    const book = rendition?.book
    if (!book) return

    if (!query) {
      this.props.onSearchResults?.([])
      return
    }

    const results: SearchResult[] = []
    const promises: Promise<void>[] = []

    book.spine.each((item: Section) => {
      if (query === '' || query == null) return
      const promise = (async () => {
        try {
          await item.load(book.load.bind(book))
          const doc = item.document
          const textNodes: Node[] = []
          if (!doc) return

          const treeWalker = doc.createTreeWalker(doc, NodeFilter.SHOW_TEXT)
          let node: Node | null
          while ((node = treeWalker.nextNode())) {
            textNodes.push(node)
          }

          const fullText = textNodes
            .map((n) => n.textContent)
            .join('')
            .toLowerCase()
          const searchQuery = query.toLowerCase()
          let pos = fullText.indexOf(searchQuery)

          while (pos !== -1) {
            let nodeIndex = 0
            let foundOffset = pos

            while (nodeIndex < textNodes.length) {
              const nodeText = textNodes[nodeIndex].textContent ?? ''
              if (foundOffset < nodeText.length) break
              foundOffset -= nodeText.length
              nodeIndex++
            }

            if (nodeIndex < textNodes.length) {
              const range = doc.createRange()
              try {
                range.setStart(textNodes[nodeIndex], foundOffset)
                range.setEnd(textNodes[nodeIndex], foundOffset + searchQuery.length)

                const cfi = item.cfiFromRange(range)

                const excerpt = `${fullText.substring(
                  Math.max(0, pos - (this.props.contextLength ?? 15)),
                  pos + searchQuery.length + (this.props.contextLength ?? 15)
                )}`

                results.push({ cfi, excerpt })
              } catch (e) {
                console.warn('Skipping invalid range:', e)
              }
            }

            pos = fullText.indexOf(searchQuery, pos + 1)
          }

          item.unload()
        } catch (error) {
          console.error('Error searching chapter:', error)
        }
      })()
      promises.push(promise)
    })

    await Promise.all(promises)

    if (query === this.props.searchQuery) {
      this.props.onSearchResults?.(results)
    }
  }

  componentDidUpdate(prevProps: IReactReaderProps) {
    if (prevProps.searchQuery !== this.props.searchQuery) {
      void this.searchInBook(this.props.searchQuery)
    }

    if (this.props.pageTurnOnScroll === true) {
      this.attachWheelListener()
    }
  }

  render() {
    const {
      title,
      showToc = true,
      loadingView,
      errorView,
      readerStyles = defaultStyles,
      locationChanged,
      swipeable,
      epubViewStyles,
      isRTL = false,
      bookSyncId,
      hidePrev = false,
      ...props
    } = this.props
    const { toc } = this.state
    const expandedToc = this.getExpandedToc()
    return (
      <div style={readerStyles.container}>
        {/* Main reader area */}
        <div style={readerStyles.readerArea}>
          <div style={{ ...readerStyles.titleArea, pointerEvents: 'none' }}>{title}</div>

          {/* Swipe gesture wrapper for touch navigation */}
          <SwipeWrapper
            swipeProps={{
              onSwiped: (eventData: SwipeEventData) => {
                const { dir } = eventData
                if (dir === 'Left') {
                  isRTL ? this.prev() : this.next()
                }
                if (dir === 'Right') {
                  isRTL ? this.next() : this.prev()
                }
              },
              onTouchStartOrOnMouseDown: ({ event }) => event.preventDefault(),
              touchEventOptions: { passive: false },
              preventScrollOnSwipe: true,
              trackMouse: true
            }}
            onSwipeLeft={() => (isRTL ? this.prev() : this.next())}
            onSwipeRight={() => (isRTL ? this.next() : this.prev())}
          >
            <div style={readerStyles.reader}>
              <EpubView
                ref={this.readerRef}
                loadingView={
                  loadingView === undefined ? (
                    <div style={readerStyles.loadingView}>Loading...</div>
                  ) : (
                    loadingView
                  )
                }
                errorView={
                  errorView === undefined ? (
                    <div style={readerStyles.errorView}>Error loading book</div>
                  ) : (
                    errorView
                  )
                }
                epubViewStyles={epubViewStyles}
                {...props}
                tocChanged={this.onTocChange}
                locationChanged={locationChanged}
                onPageTextExtracted={this.props.onPageTextExtracted}
                onPageParagraphsExtracted={this.props.onPageParagraphsExtracted}
                onNextPageParagraphs={this.props.onNextPageParagraphs}
                onPreviousPageParagraphs={this.props.onPreviousPageParagraphs}
              />
              {swipeable ? <div style={readerStyles.swipeWrapper} /> : null}
            </div>
          </SwipeWrapper>

          {/* Navigation arrow buttons (RTL-aware) */}
          <NavigationArrows
            onPrev={isRTL ? this.next : this.prev}
            onNext={isRTL ? this.prev : this.next}
            hidePrev={hidePrev}
          />
        </div>

        {/* Unified TOC sidebar using shared ReaderTOC */}
        {showToc && toc ? (
          <ReaderTOC
            open={expandedToc}
            onOpenChange={(open) => {
              if (!open && expandedToc) this.toggleToc()
              if (open && !expandedToc) this.toggleToc()
            }}
            bookSyncId={bookSyncId ?? ''}
            onBookmarkNavigate={(loc) => this.setLocation(loc)}
            tocContent={
              <div className="overflow-y-auto">
                {toc.map((item, i) => (
                  <TocItem
                    key={i}
                    data={item}
                    setLocation={(href: string) => this.setLocation(href)}
                  />
                ))}
              </div>
            }
          />
        ) : null}
      </div>
    )
  }
}
