import path from 'path'

// Absolute paths to the test fixture files
const FIXTURES_DIR = path.resolve(__dirname, '../fixtures')
const PDF_PATH = path.join(FIXTURES_DIR, 'test-book.pdf')
const EPUB_PATH = path.join(FIXTURES_DIR, 'test-book.epub')

describe('Book Import Integration Flow', () => {
  beforeEach(() => {
    cy.visit('/')
    // Wait for the app to fully load
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')
  })

  afterEach(() => {
    // Clean up any test books left behind by a failing test
    cy.window().then(async (win) => {
      const books = await win.electron.getBooks()
      for (const book of books) {
        if (
          book.title?.includes('Test') ||
          book.title?.includes('PDF Book') ||
          book.title?.includes('EPUB Book') ||
          book.filepath === PDF_PATH ||
          book.filepath === EPUB_PATH
        ) {
          await win.electron.deleteBook(book.id)
        }
      }
    })
  })

  it('should import a PDF, auto-navigate to reader, then delete it', () => {
    // The "Add Book" button triggers a native file dialog.
    // For integration testing, we directly invoke the IPC to import,
    // simulating what happens after the dialog returns a file path.

    // Step 1: Trigger import via the renderer's importBook function
    cy.window()
      .then((win) => {
        // Copy the file to app data via IPC, then save the book
        return win.electron.copyFile(PDF_PATH, '').then(async () => {
          const bookData = await win.electron.getPdfData(PDF_PATH)
          const book = await win.electron.saveBook({
            coverKind: bookData.coverKind || '',
            title: bookData.title || 'Test PDF Book',
            author: bookData.author || 'Test Author',
            publisher: bookData.publisher || '',
            filepath: PDF_PATH,
            location: '1',
            version: 0,
            kind: bookData.kind || 'pdf',
            cover: bookData.cover || []
          })
          return book
        })
      })
      .then((book) => {
        // Step 2: Verify the book appears in the library after refresh
        cy.visit('/')
        cy.contains('Test PDF Book', { timeout: 10000 }).should('be.visible')

        // Step 3: Click the book to open it
        cy.contains('Test PDF Book').click()

        // Step 4: Verify we're in the reader view
        cy.url().should('include', '/books/')

        // Step 5: Go back to library
        cy.visit('/')
        cy.contains('Test PDF Book', { timeout: 10000 }).should('be.visible')

        // Step 6: Delete the book via right-click context menu
        cy.contains('Test PDF Book').rightclick()
        cy.contains('Delete').click()

        // Step 7: Verify book is gone
        cy.contains('Test PDF Book').should('not.exist')
      })
  })

  it('should import an EPUB, auto-navigate to reader, then delete it', () => {
    cy.window()
      .then((win) => {
        return win.electron.copyFile(EPUB_PATH, '').then(async () => {
          const bookData = await win.electron.getBookData(EPUB_PATH)
          const book = await win.electron.saveBook({
            coverKind: bookData.coverKind || '',
            title: bookData.title || 'Test EPUB Book',
            author: bookData.author || 'Test Author',
            publisher: bookData.publisher || '',
            filepath: EPUB_PATH,
            location: '1',
            version: 0,
            kind: bookData.kind || 'epub',
            cover: bookData.cover || []
          })
          return book
        })
      })
      .then(() => {
        cy.visit('/')
        cy.contains('Test EPUB Book', { timeout: 10000 }).should('be.visible')

        // Open the book
        cy.contains('Test EPUB Book').click()
        cy.url().should('include', '/books/')

        // Go back and delete
        cy.visit('/')
        cy.contains('Test EPUB Book', { timeout: 10000 }).should('be.visible')
        cy.contains('Test EPUB Book').rightclick()
        cy.contains('Delete').click()
        cy.contains('Test EPUB Book').should('not.exist')
      })
  })

  it('should show the correct book count after importing multiple books', () => {
    // Import both books
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH)
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || '',
        title: pdfData.title || 'PDF Book',
        author: pdfData.author || '',
        publisher: '',
        filepath: PDF_PATH,
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: pdfData.cover || []
      })

      const epubData = await win.electron.getBookData(EPUB_PATH)
      await win.electron.saveBook({
        coverKind: epubData.coverKind || '',
        title: epubData.title || 'EPUB Book',
        author: epubData.author || '',
        publisher: '',
        filepath: EPUB_PATH,
        location: '1',
        version: 0,
        kind: 'epub',
        cover: epubData.cover || []
      })
    })

    // Reload and verify both appear
    cy.visit('/')
    cy.get('[data-tour="book-grid"]', { timeout: 10000 }).should('be.visible')
    // Should have at least 2 book cards
    cy.get('[data-tour="book-grid"] > div').should('have.length.at.least', 2)
  })
})
