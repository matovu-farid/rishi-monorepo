import React from 'react'
import TestRenderer from 'react-test-renderer'
import { AndroidSelectionOverlay } from '@/components/pdf/AndroidSelectionOverlay'

// Mock react-native
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

// Mock react-native-gesture-handler — provide stub components
jest.mock('react-native-gesture-handler', () => {
  const React = require('react')
  const mk = (name: string) =>
    ({ children, onHandlerStateChange, onGestureEvent, onEnded, ...rest }: any) =>
      React.createElement(name, rest, children)
  return {
    LongPressGestureHandler: mk('LongPressGestureHandler'),
    PanGestureHandler: mk('PanGestureHandler'),
    State: { ACTIVE: 4 },
  }
})

// Mock coord-transform
jest.mock('@/components/pdf/coord-transform', () => ({
  pdfRectToScreen: (rect: any) => ({
    left: rect.x,
    top: rect.y,
    width: rect.w,
    height: rect.h,
  }),
  screenPointToPdf: (point: any) => point,
}))

const pageSize = { widthPts: 612, heightPts: 792 }
const viewport = { widthPx: 612, heightPx: 792, scale: 1 }
const words = [
  { idx: 0, text: 'Hello', x: 72, y: 720, w: 40, h: 12 },
  { idx: 1, text: 'world', x: 120, y: 720, w: 40, h: 12 },
]

describe('AndroidSelectionOverlay', () => {
  it('renders without crashing when words are provided', () => {
    let tree: any
    TestRenderer.act(() => {
      tree = TestRenderer.create(
        <AndroidSelectionOverlay
          pageSize={pageSize}
          viewport={viewport}
          words={words}
          onTextSelected={jest.fn()}
        />,
      )
    })
    expect(tree).toBeTruthy()
  })

  it('renders no selection rects initially (no gesture active)', () => {
    let tree: any
    TestRenderer.act(() => {
      tree = TestRenderer.create(
        <AndroidSelectionOverlay
          pageSize={pageSize}
          viewport={viewport}
          words={words}
          onTextSelected={jest.fn()}
        />,
      )
    })
    const rects = tree.root
      .findAllByProps({ testID: 'android-selection-rect' })
      .filter((n: any) => typeof n.type === 'string')
    expect(rects).toHaveLength(0)
  })

  it('renders without crashing when words list is empty', () => {
    let tree: any
    TestRenderer.act(() => {
      tree = TestRenderer.create(
        <AndroidSelectionOverlay
          pageSize={pageSize}
          viewport={viewport}
          words={[]}
          onTextSelected={jest.fn()}
        />,
      )
    })
    const rects = tree.root
      .findAllByProps({ testID: 'android-selection-rect' })
      .filter((n: any) => typeof n.type === 'string')
    expect(rects).toHaveLength(0)
  })
})
