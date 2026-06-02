import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SessionEndedKeepBooksDialog } from '../SessionEndedKeepBooksDialog'

const books = [
  { dbBookId: 1, title: 'Foo', fromDisplayName: 'Alice', localPath: '/p/1.epub' },
  { dbBookId: 2, title: 'Bar', fromDisplayName: 'Bob', localPath: '/p/2.pdf' }
]

describe('SessionEndedKeepBooksDialog', () => {
  it('lists every received book with its sender', () => {
    render(<SessionEndedKeepBooksDialog books={books} onKeep={() => {}} onDiscard={() => {}} />)
    expect(screen.getByText('Foo')).toBeInTheDocument()
    expect(screen.getByText(/Alice/)).toBeInTheDocument()
    expect(screen.getByText('Bar')).toBeInTheDocument()
    expect(screen.getByText(/Bob/)).toBeInTheDocument()
  })

  it('fires onKeep when Keep is pressed (default action)', () => {
    const onKeep = vi.fn()
    render(<SessionEndedKeepBooksDialog books={books} onKeep={onKeep} onDiscard={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /keep/i }))
    expect(onKeep).toHaveBeenCalled()
  })

  it('fires onDiscard when Discard is pressed', () => {
    const onDiscard = vi.fn()
    render(<SessionEndedKeepBooksDialog books={books} onKeep={() => {}} onDiscard={onDiscard} />)
    fireEvent.click(screen.getByRole('button', { name: /discard/i }))
    expect(onDiscard).toHaveBeenCalled()
  })
})
