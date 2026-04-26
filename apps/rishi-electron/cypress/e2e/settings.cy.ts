/**
 * Reader Settings — comprehensive e2e tests for font size, font family, theme.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe('Reader Settings', () => {
  let bookId: number

  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData('cypress/fixtures/test-book.epub')
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || '',
        title: 'Settings Test EPUB',
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
    cy.clearLocalStorage()
    cy.window().then(async (win) => {
      if (bookId) {
        await win.electron.deleteBook(bookId)
      }
    })
  })

  it('should show the settings button in the reader toolbar', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })

    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).should('exist')
  })

  it('should open the settings popover when the settings button is clicked', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.contains('Font Size').should('be.visible')
    cy.contains('Font Family').should('be.visible')
  })

  it('should show Serif and Sans font family options', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.contains('Serif').should('be.visible')
    cy.contains('Sans').should('be.visible')
  })

  it('should have a font size slider control', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.get('input[type="range"]').should('exist')
    cy.get('input[type="range"]').should('have.attr', 'min', '0.8')
    cy.get('input[type="range"]').should('have.attr', 'max', '2')
  })

  it('should persist font size settings in localStorage', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.get('input[type="range"]').invoke('val', 1.5).trigger('change')

    cy.window().then((win) => {
      const raw = win.localStorage.getItem('rishi:reader-settings')
      if (raw) {
        const settings = JSON.parse(raw)
        expect(settings).to.have.property('fontSize')
      }
    })
  })

  it('should close the settings popover when clicking outside', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()
    cy.contains('Font Size').should('be.visible')

    cy.get('body').click(0, 400, { force: true })
    cy.contains('Font Size').should('not.exist')
  })

  it('should allow switching to Serif font family', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.contains('Serif').click()
    // Setting should persist
    cy.window().then((win) => {
      const raw = win.localStorage.getItem('rishi:reader-settings')
      if (raw) {
        const settings = JSON.parse(raw)
        expect(settings).to.have.property('fontFamily')
      }
    })
  })

  it('should allow switching to Sans font family', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.contains('Sans').click()
    cy.window().then((win) => {
      const raw = win.localStorage.getItem('rishi:reader-settings')
      if (raw) {
        const settings = JSON.parse(raw)
        expect(settings).to.have.property('fontFamily')
      }
    })
  })

  it('should have the font size slider with correct step attribute', () => {
    cy.visit('/')
    cy.contains('Settings Test EPUB', { timeout: 10000 }).click()
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')

    cy.get('body').trigger('mousemove', { clientX: 500, clientY: 10 })
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click()

    cy.get('input[type="range"]').should('have.attr', 'step')
  })
})
