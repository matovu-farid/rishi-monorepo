import React from 'react'
import TestRenderer from 'react-test-renderer'
import { HighlightOverlay } from '@/components/pdf/HighlightOverlay'

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    View: mk('View'),
    StyleSheet: { absoluteFill: {}, create: (s: Record<string, unknown>) => s },
  }
})

describe('HighlightOverlay', () => {
  it('renders one View per rect across all matching page highlights', () => {
    let tree: any
    TestRenderer.act(() => {
      tree = TestRenderer.create(
        <HighlightOverlay
          page={1}
          pageSize={{ widthPts: 612, heightPts: 792 }}
          viewport={{ widthPx: 612, heightPx: 792, scale: 1 }}
          highlights={[
            {
              id: 'h1',
              page: 1,
              color: 'yellow',
              rects: [
                { x: 72, y: 720, w: 50, h: 12 },
                { x: 130, y: 720, w: 40, h: 12 },
              ],
            },
            {
              id: 'h2',
              page: 2,            // off-page, ignored
              color: 'pink',
              rects: [{ x: 0, y: 0, w: 10, h: 10 }],
            },
          ]}
        />,
      )
    })
    // findAllByProps traverses all nodes; filter to string-type (host) nodes only
    // to avoid double-counting forwardRef wrappers from the react-native mock.
    const matches = tree.root
      .findAllByProps({ testID: 'highlight-rect' })
      .filter((n: any) => typeof n.type === 'string')
    expect(matches).toHaveLength(2)
  })

  it('renders nothing when there are no matching highlights', () => {
    let tree: any
    TestRenderer.act(() => {
      tree = TestRenderer.create(
        <HighlightOverlay
          page={1}
          pageSize={{ widthPts: 612, heightPts: 792 }}
          viewport={{ widthPx: 612, heightPx: 792, scale: 1 }}
          highlights={[]}
        />,
      )
    })
    const matches = tree.root
      .findAllByProps({ testID: 'highlight-rect' })
      .filter((n: any) => typeof n.type === 'string')
    expect(matches).toHaveLength(0)
  })
})
