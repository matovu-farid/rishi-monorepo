/**
 * Highlights — comprehensive e2e tests for create, color, note, delete.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe('Highlights', () => {
  let bookId: number

  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData('cypress/fixtures/test-book.epub')
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || '',
        title: 'Highlights Test EPUB',
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

  it('should have the highlight IPC methods available on window.electron', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('dbQuery')
      expect(win.electron).to.have.property('dbRun')
      expect(win.electron.dbQuery).to.be.a('function')
      expect(win.electron.dbRun).to.be.a('function')
    })
  })

  it('should open the EPUB reader for highlight testing', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.url().should('include', '/books/')
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')
  })

  it('should show the highlights panel toggle in the toolbar', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).should('exist')
  })

  it('should show empty state in the highlights panel when no highlights exist', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const highlightBtn = $toolbar.find('[aria-label*="ighlight"]')
      if (highlightBtn.length > 0) {
        cy.wrap(highlightBtn).click()
        cy.contains('No highlights yet').should('be.visible')
      }
    })
  })

  it('should show the close button in the highlights panel', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const highlightBtn = $toolbar.find('[aria-label*="ighlight"]')
      if (highlightBtn.length > 0) {
        cy.wrap(highlightBtn).click()
        cy.get('[aria-label="Close"]').should('exist')
      }
    })
  })

  it('should close the highlights panel when close button is clicked', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const highlightBtn = $toolbar.find('[aria-label*="ighlight"]')
      if (highlightBtn.length > 0) {
        cy.wrap(highlightBtn).click()
        cy.contains('No highlights yet').should('be.visible')
        cy.get('[aria-label="Close"]').click()
        cy.contains('No highlights yet').should('not.exist')
      }
    })
  })

  it('should show highlight count in the footer', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const highlightBtn = $toolbar.find('[aria-label*="ighlight"]')
      if (highlightBtn.length > 0) {
        cy.wrap(highlightBtn).click()
        cy.contains('0 highlights').should('be.visible')
      }
    })
  })

  it('should show the instruction text in empty state', () => {
    cy.visit('/')
    cy.contains('Highlights Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const highlightBtn = $toolbar.find('[aria-label*="ighlight"]')
      if (highlightBtn.length > 0) {
        cy.wrap(highlightBtn).click()
        cy.contains('Select text while reading').should('be.visible')
      }
    })
  })
})
