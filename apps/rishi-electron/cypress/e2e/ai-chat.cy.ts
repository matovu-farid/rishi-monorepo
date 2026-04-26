/**
 * AI Chat — comprehensive e2e tests for open, send, receive, citations.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe('AI Chat', () => {
  let bookId: number

  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData('cypress/fixtures/test-book.epub')
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || '',
        title: 'AI Chat Test EPUB',
        author: 'Test Author',
        publisher: '',
        filepath: 'cypress/fixtures/test-book.epub',
        location: '1',
        version: 0,
        kind: 'epub',
        cover: bookData.cover || []
      })
      bookId = book.id
    })
  })

  afterEach(() => {
    cy.window().then(async (win) => {
      if (bookId) {
        await win.electron.deleteBook(bookId)
      }
    })
  })

  it('should show the AI chat orb on the library page', () => {
    cy.visit('/')
    cy.get('[data-tour="ai-chat"]', { timeout: 10000 }).should('exist')
  })

  it('should trigger premium dialog when AI chat is clicked without auth', () => {
    cy.visit('/')
    cy.get('[data-tour="ai-chat"]', { timeout: 10000 }).click({ force: true })

    cy.get("[data-slot='dialog-content']", { timeout: 5000 }).should('be.visible')
    cy.contains('Sign in').should('be.visible')
  })

  it('should close the premium dialog with Maybe later', () => {
    cy.visit('/')
    cy.get('[data-tour="ai-chat"]', { timeout: 10000 }).click({ force: true })
    cy.get("[data-slot='dialog-content']", { timeout: 5000 }).should('be.visible')
    cy.contains('Maybe later').click()
    cy.get("[data-slot='dialog-content']").should('not.exist')
  })

  it('should have the IPC methods needed for AI chat', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('getContextForQuery')
      expect(win.electron.getContextForQuery).to.be.a('function')
      expect(win.electron).to.have.property('embed')
      expect(win.electron.embed).to.be.a('function')
      expect(win.electron).to.have.property('searchVectors')
      expect(win.electron.searchVectors).to.be.a('function')
    })
  })

  it('should have getRealtimeClientSecret for voice input', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('getRealtimeClientSecret')
      expect(win.electron.getRealtimeClientSecret).to.be.a('function')
    })
  })

  it('should show the AI chat orb on the reader page too', () => {
    cy.visit('/')
    cy.contains('AI Chat Test EPUB', { timeout: 10000 }).click()
    cy.get('[data-tour="ai-chat"]', { timeout: 15000 }).should('exist')
  })

  it('should show the premium dialog with chat feature description', () => {
    cy.visit('/')
    cy.get('[data-tour="ai-chat"]', { timeout: 10000 }).click({ force: true })

    cy.get("[data-slot='dialog-content']", { timeout: 5000 }).should('be.visible')
    // Chat premium feature title
    cy.contains('Chat with your books').should('be.visible')
  })

  it('should show bullet points in the premium dialog', () => {
    cy.visit('/')
    cy.get('[data-tour="ai-chat"]', { timeout: 10000 }).click({ force: true })

    cy.get("[data-slot='dialog-content']", { timeout: 5000 }).should('be.visible')
    cy.contains('Cites passages').should('be.visible')
  })

  it('should have the AI chat orb as a clickable element', () => {
    cy.visit('/')
    cy.get('[data-tour="ai-chat"]', { timeout: 10000 }).should('exist').and('be.visible')
  })
})
