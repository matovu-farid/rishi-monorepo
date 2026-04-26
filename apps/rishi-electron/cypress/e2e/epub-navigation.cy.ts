import path from 'path'

const FIXTURES_DIR = path.resolve(__dirname, '../fixtures')
const EPUB_PATH = path.join(FIXTURES_DIR, 'test-book.epub')

describe('EPUB Navigation Components', () => {
  let bookId: number

  beforeEach(() => {
    // Import a test EPUB so the reader has a book to display
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH)
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || '',
        title: bookData.title || 'Navigation Test EPUB',
        author: bookData.author || 'Test Author',
        publisher: bookData.publisher || '',
        filepath: EPUB_PATH,
        location: '1',
        version: 0,
        kind: bookData.kind || 'epub',
        cover: bookData.cover || []
      })
      bookId = book.id
    })
  })

  afterEach(() => {
    // Clean up the test book
    cy.window().then(async (win) => {
      if (bookId) {
        await win.electron.deleteBook(bookId)
      }
    })
  })

  it('should render navigation arrow buttons in the EPUB reader', () => {
    cy.visit('/')
    // Click on the imported book to open the reader
    cy.contains('Navigation Test EPUB', { timeout: 10000 }).click()

    // Wait for the reader to load
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')
  })

  it('should navigate forward when the next arrow is clicked', () => {
    cy.visit('/')
    cy.contains('Navigation Test EPUB', { timeout: 10000 }).click()

    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should('be.visible')
    cy.get('[aria-label="Next page"]').click()

    // The reader should still be visible after navigation
    cy.get('[aria-label="Next page"]').should('be.visible')
  })

  it('should show the TOC toggle button in the toolbar', () => {
    cy.visit('/')
    cy.contains('Navigation Test EPUB', { timeout: 10000 }).click()

    // The TOC toggle button should be present
    cy.get('[aria-label="Toggle table of contents"]', { timeout: 15000 }).should('be.visible')
  })

  it('should open and close the table of contents', () => {
    cy.visit('/')
    cy.contains('Navigation Test EPUB', { timeout: 10000 }).click()

    // Open the TOC
    cy.get('[aria-label="Toggle table of contents"]', { timeout: 15000 }).click()

    // The "Table of Contents" heading should appear
    cy.contains('Table of Contents', { timeout: 5000 }).should('be.visible')

    // Click the TOC toggle again to close
    cy.get('[aria-label="Toggle table of contents"]').click()

    // The TOC heading should disappear (allow animation time)
    cy.contains('Table of Contents').should('not.exist')
  })
})
