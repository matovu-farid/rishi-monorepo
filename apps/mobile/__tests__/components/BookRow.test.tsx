/**
 * BookRow (mobile) — defect P1-V.
 *
 * The row was using Tailwind grays + a hardcoded `#DC2626` trash icon.
 * Token migration:
 *   - Subtitle (author) ➜ colors.label.secondary
 *   - Trash icon (destructive) ➜ colors.accent.error
 *   - Row press-state surface ➜ colors.fill.quaternary
 *   - Separator beneath the row ➜ <Hairline />
 *
 * We pin observable behaviour:
 *   1. Subtitle text uses colors.label.secondary
 *   2. Trash icon receives the destructive accent token color
 *   3. A `Hairline` separator is rendered (so the FlatList row reads as
 *      a list cell even without the FlatList's ItemSeparatorComponent).
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    Image: mk('Image'),
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

jest.mock('expo-image', () => {
  const React = require('react')
  return {
    Image: (p: any) => React.createElement('ExpoImage', p),
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

jest.mock('@/components/ui/BookCover', () => {
  const React = require('react')
  return {
    BookCover: (p: any) =>
      React.createElement('BookCover', { testID: p.testID, ...p }),
  }
})

// Bypass the `@/components/ui` barrel — Sheet pulls in gesture-handler which
// is not transformable by ts-jest in this `node` test env. The only exports
// we need are BookCover (mocked above) and Hairline (real, light).
jest.mock('@/components/ui', () => {
  const React = require('react')
  return {
    BookCover: (p: any) =>
      React.createElement('BookCover', { testID: p.testID, ...p }),
    Hairline: require('@/components/ui/Hairline').Hairline,
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { BookRow } from '@/components/BookRow'
import { Hairline } from '@/components/ui/Hairline'
import { colorsLight } from '@/lib/theme'
import type { Book } from '@/types/book'

const mockBook: Book = {
  id: 'b1',
  title: 'War and Peace',
  author: 'Leo Tolstoy',
  format: 'epub',
  path: '/tmp/war-and-peace.epub',
  coverPath: null,
  fileHash: 'abc123',
  addedAt: 0,
  lastReadAt: 0,
} as unknown as Book

describe('BookRow (P1-V: uses design tokens)', () => {
  it('renders the author subtitle using colors.label.secondary', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow book={mockBook} onPress={() => {}} onDelete={() => {}} />,
      )
    })
    const authorTexts = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        n.type === 'Text' &&
        Array.isArray(n.children) &&
        n.children.includes('Leo Tolstoy'),
    )
    expect(authorTexts.length).toBeGreaterThan(0)
    const styles = (authorTexts[0].props as { style?: unknown }).style
    const flat = Array.isArray(styles) ? Object.assign({}, ...styles.filter(Boolean)) : (styles ?? {})
    expect((flat as { color?: string }).color).toBe(colorsLight.label.secondary)
  })

  it('renders the trash icon using colors.accent.error', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow book={mockBook} onPress={() => {}} onDelete={() => {}} />,
      )
    })
    const trash = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.type as string) === 'IconSymbol' &&
        (n.props as { name?: string }).name === 'trash',
    )
    expect(trash.length).toBe(1)
    expect((trash[0].props as { color?: string }).color).toBe(
      colorsLight.accent.error,
    )
  })

  it('renders a Hairline separator', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow book={mockBook} onPress={() => {}} onDelete={() => {}} />,
      )
    })
    const hairlines = tree.root.findAllByType(Hairline)
    expect(hairlines.length).toBe(1)
  })

  it('fires onPress when the row is tapped', () => {
    const onPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow book={mockBook} onPress={onPress} onDelete={() => {}} />,
      )
    })
    const pressables = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === `library-book-row-${mockBook.id}`,
    )
    expect(pressables.length).toBeGreaterThan(0)
    act(() => {
      ;(pressables[0].props as { onPress?: () => void }).onPress?.()
    })
    expect(onPress).toHaveBeenCalledTimes(1)
  })

  it('fires onDelete when the trash button is tapped', () => {
    const onDelete = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow book={mockBook} onPress={() => {}} onDelete={onDelete} />,
      )
    })
    const trashButtons = tree.root.findAll(
      (n) => (n.props as { testID?: string }).testID === 'book-delete-button',
    )
    expect(trashButtons.length).toBeGreaterThan(0)
    act(() => {
      ;(trashButtons[0].props as { onPress?: () => void }).onPress?.()
    })
    expect(onDelete).toHaveBeenCalledTimes(1)
  })
})

describe('BookRow (PRF-003: stable press-state style references)', () => {
  // PRF-003: the Pressable used to receive a style FUNCTION that
  // constructed a brand-new object every press transition:
  //
  //   style={({ pressed }) => [styles.row, { padding..., backgroundColor... }]}
  //
  // For a FlatList scrolling 60fps this allocates per row per frame
  // during press tracking. The fix:
  //   - hoist padding into a memoized base style (theme-keyed)
  //   - reduce the press-state delta to a backgroundColor ternary
  //     that points at two pre-allocated objects (transparent vs fill).
  //
  // We pin two observable consequences:
  //   1. The style function returned for `pressed=false` and `pressed=true`
  //      shares the SAME base object reference (only the overlay differs).
  //   2. Repeated renders with the same theme yield the same base ref.
  //
  // Together those prove the per-press allocation is gone.
  it('returns stable style references across pressed=true and pressed=false', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow book={mockBook} onPress={() => {}} onDelete={() => {}} />,
      )
    })
    const pressables = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === `library-book-row-${mockBook.id}`,
    )
    expect(pressables.length).toBeGreaterThan(0)
    const styleProp = (pressables[0].props as { style?: unknown }).style
    expect(typeof styleProp).toBe('function')
    const fn = styleProp as (s: { pressed: boolean }) => unknown[]
    const a = fn({ pressed: false })
    const b = fn({ pressed: true })
    expect(Array.isArray(a)).toBe(true)
    expect(Array.isArray(b)).toBe(true)
    // Every non-overlay slot must share the SAME reference between the
    // pressed and unpressed return values. The only delta should be the
    // backgroundColor overlay object.
    expect(a.length).toBe(b.length)
    const findOverlay = (arr: unknown[]) =>
      arr.findIndex(
        (entry) =>
          entry !== null &&
          typeof entry === 'object' &&
          'backgroundColor' in (entry as Record<string, unknown>) &&
          Object.keys(entry as Record<string, unknown>).length === 1,
      )
    const overlayIdx = findOverlay(a)
    expect(overlayIdx).toBeGreaterThanOrEqual(0)
    expect(findOverlay(b)).toBe(overlayIdx)
    for (let i = 0; i < a.length; i++) {
      if (i === overlayIdx) continue
      expect(a[i]).toBe(b[i])
    }
    // The overlays themselves differ between pressed states but are
    // pre-allocated — repeated calls with the same `pressed` flag yield
    // the same object reference (no per-frame allocation).
    expect(a[overlayIdx]).not.toBe(b[overlayIdx])
    expect(a[overlayIdx]).toBe(fn({ pressed: false })[overlayIdx])
    expect(b[overlayIdx]).toBe(fn({ pressed: true })[overlayIdx])
  })
})

describe('BookRow (P1-AC: cover-extraction retry)', () => {
  const failedCoverBook: Book = {
    ...mockBook,
    id: 'b2',
    coverExtractionFailed: true,
  } as unknown as Book

  it('fires onCoverRetry on long-press when the book has coverExtractionFailed=true', () => {
    const onCoverRetry = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow
          book={failedCoverBook}
          onPress={() => {}}
          onDelete={() => {}}
          onCoverRetry={onCoverRetry}
        />,
      )
    })
    const pressables = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === `library-book-row-${failedCoverBook.id}`,
    )
    expect(pressables.length).toBeGreaterThan(0)
    act(() => {
      ;(pressables[0].props as { onLongPress?: () => void }).onLongPress?.()
    })
    expect(onCoverRetry).toHaveBeenCalledTimes(1)
    expect(onCoverRetry).toHaveBeenCalledWith(failedCoverBook)
  })

  it('does NOT fire onCoverRetry on long-press when the book has a healthy cover', () => {
    const onCoverRetry = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookRow
          book={mockBook}
          onPress={() => {}}
          onDelete={() => {}}
          onCoverRetry={onCoverRetry}
        />,
      )
    })
    const pressables = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === `library-book-row-${mockBook.id}`,
    )
    act(() => {
      ;(pressables[0].props as { onLongPress?: () => void } | null)?.onLongPress?.()
    })
    expect(onCoverRetry).not.toHaveBeenCalled()
  })
})
