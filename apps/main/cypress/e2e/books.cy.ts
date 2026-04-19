import { describe, it, cy, beforeEach } from 'tauri-cypress'

describe('Book Management', () => {
  beforeEach(() => {
    cy.mockCommand('get_books', [
      { id: 'book-1', title: 'Test Book', author: 'Test Author', format: 'epub', path: '/test.epub' }
    ])
    cy.visit('/')
  })

  it('displays books from the backend', () => {
    cy.ipcLog('get_books').should('have.length', 1)
    cy.ipcLog('get_books').first().should('have.property', 'mocked', true)
  })

  it('can mock the search_vectors command', () => {
    cy.interceptCommand('search_vectors', (args) => {
      return { results: [{ id: 'vec-1', score: 0.95 }] }
    })
    cy.invoke('search_vectors', { query: 'test', book_id: 'book-1', top_k: 5 })
    cy.ipcLog('search_vectors').should('have.length', 1)
  })

  it('captures IPC traffic for get_book_data', () => {
    cy.mockCommand('get_book_data', {
      title: 'Mocked Book',
      chapters: [{ title: 'Chapter 1', content: '<p>Hello</p>' }]
    })
    cy.invoke('get_book_data', { path: '/test.epub' })
    cy.ipcLog('get_book_data').first().should('have.property', 'mocked', true)
  })
})
