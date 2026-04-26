/**
 * Text-to-Speech Controls — comprehensive e2e tests for play/pause, next/prev, stop.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe('Text-to-Speech Controls', () => {
  let bookId: number

  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData('cypress/fixtures/test-book.epub')
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || '',
        title: 'TTS Test EPUB',
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

  it('should show the TTS orb when a book is open', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).should('be.visible')
  })

  it('should expand TTS controls when the orb is clicked', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()

    cy.get('[aria-label="Play"]', { timeout: 5000 }).should('be.visible')
    cy.get('[aria-label="Previous"]').should('be.visible')
    cy.get('[aria-label="Next"]').should('be.visible')
    cy.get('[aria-label="Stop"]').should('be.visible')
  })

  it('should have Previous and Next navigation buttons', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()

    cy.get('[aria-label="Previous"]').should('exist')
    cy.get('[aria-label="Next"]').should('exist')
  })

  it('should disable Stop button when not playing', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()

    cy.get('[aria-label="Stop"]').should('be.disabled')
  })

  it('should show Play button as enabled when stopped', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()

    cy.get('[aria-label="Play"]').should('not.be.disabled')
  })

  it('should allow clicking Play to trigger premium dialog when not authenticated', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()

    cy.get('[aria-label="Play"]').click()
    // Should show the premium feature dialog since user is not authenticated
    cy.get("[data-slot='dialog-content']", { timeout: 5000 }).should('be.visible')
    cy.contains('Sign in').should('be.visible')
  })

  it('should dismiss the premium dialog with Maybe later', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()
    cy.get('[aria-label="Play"]').click()

    cy.get("[data-slot='dialog-content']", { timeout: 5000 }).should('be.visible')
    cy.contains('Maybe later').click()
    cy.get("[data-slot='dialog-content']").should('not.exist')
  })

  it('should have the TTS cache IPC methods available', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('readDir')
      expect(win.electron).to.have.property('removeFile')
      expect(win.electron).to.have.property('getDirSize')
      expect(win.electron).to.have.property('getCacheFileStats')
      expect(win.electron).to.have.property('writeFile')
      expect(win.electron).to.have.property('readFile')
      expect(win.electron).to.have.property('exists')
      expect(win.electron).to.have.property('mkdir')
      expect(win.electron).to.have.property('getAppDataPath')
    })
  })

  it('should have the processJob IPC method available', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('processJob')
      expect(win.electron.processJob).to.be.a('function')
    })
  })

  it('should show the TTS orb as a fixed element at bottom-right', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).should(
      'have.css',
      'position',
      'fixed'
    )
  })

  it('should keep TTS controls visible after expanding and hovering', () => {
    cy.visit('/')
    cy.contains('TTS Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click()

    // Hover over the expanded controls to keep them visible
    cy.get('[aria-label="TTS controls"]').trigger('mouseenter')
    cy.get('[aria-label="Play"]').should('be.visible')
    cy.get('[aria-label="TTS controls"]').trigger('mouseleave')
  })
})
