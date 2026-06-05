import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { PdfNativeReader } from '@/components/pdf/PdfNativeReader'

// react-native-pdf needs to be mocked because it's a native view.
let triggerOnChange: ((payload: string) => void) | null = null

jest.mock('react-native-pdf', () => {
  const React = require('react')
  const { View } = require('react-native')
  return function Pdf(props: any) {
    // Expose onChange so tests can fire iOS-style events.
    triggerOnChange = props.onChange ?? null
    React.useEffect(() => {
      props.onLoadComplete?.(3, props.source.uri, [612, 792], [
        { title: 'Chapter 1', pageIdx: 0 },
        { title: 'Chapter 2', pageIdx: 5 },
      ])
    }, [])
    return <View testID="rn-pdf-mock" />
  }
})

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    View: mk('View'),
    StyleSheet: { absoluteFill: {}, create: (s: Record<string, unknown>) => s },
    Platform: { OS: 'ios' },
    LayoutChangeEvent: {},
  }
})

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

describe('PdfNativeReader', () => {
  it('renders the Pdf view with the book file path', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <PdfNativeReader bookId="b" filePath="/tmp/a.pdf" />,
      )
    })
    const pdfMock = tree.root.findAll(
      (n) => n.props.testID === 'rn-pdf-mock',
    )
    expect(pdfMock.length).toBeGreaterThan(0)
  })

  it('exposes onLoadComplete TOC via onOutline prop', async () => {
    const onOutline = jest.fn()
    await act(async () => {
      TestRenderer.create(
        <PdfNativeReader bookId="b" filePath="/tmp/a.pdf" onOutline={onOutline} />,
      )
    })
    expect(onOutline).toHaveBeenCalledWith([
      { title: 'Chapter 1', pageIdx: 0 },
      { title: 'Chapter 2', pageIdx: 5 },
    ])
  })

  it('calls onTextSelected when iOS textSelected onChange fires', async () => {
    const onTextSelected = jest.fn()
    await act(async () => {
      TestRenderer.create(
        <PdfNativeReader bookId="b" filePath="/tmp/a.pdf" onTextSelected={onTextSelected} />,
      )
    })
    act(() => {
      triggerOnChange?.('textSelected|hello there')
    })
    expect(onTextSelected).toHaveBeenCalledWith('hello there')
  })
})
