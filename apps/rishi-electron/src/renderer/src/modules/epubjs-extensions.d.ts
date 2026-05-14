import type { Contents } from 'epubjs'
import type Section from 'epubjs/types/section'
import type { SpineItem as _SpineItem } from 'epubjs/types/section'
import type View from 'epubjs/types/managers/view'
import type Layout from 'epubjs/types/layout'
import type Manager from 'epubjs/types/managers/manager'
import type Mapping from 'epubjs/types/mapping'
import type _Rendition from 'epubjs/types/rendition'
import type Annotations from 'epubjs/types/annotations'
import type { EpubCFI } from 'epubjs'

declare module 'epubjs/types/section' {
  export interface SpineItem {
    load(request: (url: string) => Promise<unknown>): Promise<Section>
    index: number
    cfiBase: string
    next(): SpineItem | null
    prev(): SpineItem | null
  }

  export interface Spine {
    spineItems: SpineItem[]
  }

  export default interface Section {
    pages?: number[]
    totalPages?: number
    mapping?: {
      start: string
      end: string
    }
    document?: Document
    index: number
    load(request?: (url: string) => Promise<unknown>): Promise<Section>
    next(): SpineItem | null
    prev(): SpineItem | null
  }
}

declare module 'epubjs/types/managers/view' {
  export interface ViewPosition {
    left: number
    width: number
    right: number
  }

  // `contents`, `section`, and `element` are assigned during view
  // construction in epub.js but may be `undefined` before the view has
  // finished mounting (e.g. during initial render or after destroy).
  // Marking them optional matches runtime reality.
  export default interface View {
    contents?: Contents
    section?: Section
    index: number
    position(): ViewPosition
    element?: HTMLDivElement
  }
}

declare module 'epubjs/types/annotations' {
  export default interface Annotations {
    _annotations: Record<string, unknown>
    highlight(
      cfiRange: string | EpubCFI,
      data?: Record<string, unknown>,
      cb?: () => void,
      className?: string,
      styles?: Record<string, unknown>
    ): unknown
    remove(cfiRange: string | EpubCFI, type: string): void
  }
}

declare module 'epubjs/types/locations' {
  export default interface Locations {
    /**
     * Internal array of generated CFI strings, one per location.
     * Reaching into the private surface is the only way to read the
     * raw count without round-tripping through `length()` which can
     * lie before generate() resolves.
     */
    _locations: string[]
  }
}

declare module 'epubjs/types/layout' {
  export default interface Layout {
    pageWidth: number
    width: number
    height: number
  }
}

declare module 'epubjs/types/managers/manager' {
  import type { SpineItem } from 'epubjs/types/section'

  export default interface Manager {
    views: View[] & {
      find: ({ index }: { index: number }) => View | undefined
    }
    layout: Layout
    currentLocation(): Section[]
    mapping: Mapping
    visible(): View[]
    add(section: Section | SpineItem, forceRight: boolean): Promise<View>
    container: HTMLElement
    clear(): void
    updateLayout(): void
    settings: {
      axis: 'horizontal' | 'vertical'
      fullsize?: boolean
      direction?: 'rtl' | 'ltr'
      [key: string]: unknown
    }
  }
}

declare module 'epubjs/types/rendition' {
  import type { Book } from 'epubjs'

  export default interface Rendition {
    manager: Manager
    annotations: Annotations
    book: Book
    settings: {
      ignoreClass: string
      [key: string]: unknown
    }
    /**
     * The current displayed location. `undefined` until the first
     * `relocated` event fires — call sites must handle the optional case.
     * Upstream types declare this as non-optional; we narrow it here so
     * the optional-chain pattern in renderers is type-correct.
     */
    location?: Location
  }
}

declare module 'epubjs/types/mapping' {
  export default interface Mapping {
    page(
      contents: Contents,
      cfiBase: string,
      start: number,
      end: number
    ): { start: string; end: string } | null
  }
}

declare module 'epubjs' {
  import type { SpineItem, Spine } from 'epubjs/types/section'
  import type { NavItem } from 'epubjs'

  // Augment the Book interface to include loaded.spine with Spine type
  export interface Book {
    loaded: {
      spine: Promise<Spine>
      navigation: Promise<{ toc: NavItem[] }>
    }
    spine: {
      each: (callback: (item: SpineItem) => void) => void
    }
    load: (url: string) => Promise<unknown>
    destroy: () => void
  }

  // Upstream types declare `toRange` as returning `Range`, but the
  // implementation returns `null` when the CFI cannot be resolved against
  // the supplied document (e.g. document not yet attached, mismatched
  // section). Reflect that in the type so call sites can guard.
  export interface EpubCFI {
    toRange(_doc?: Document, ignoreClass?: string): Range | null
  }
}
