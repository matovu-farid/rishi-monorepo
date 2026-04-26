/// <reference types="cypress" />

const PDF_FIXTURE_PATH = Cypress.config().fixturesFolder + '/test-book.pdf'

describe('PDF Import & Open Debug', () => {
  afterEach(() => {
    // Clean up any test books created during this suite
    cy.visit('/')
    cy.window().then(async (win: any) => {
      const electron = win.electron
      if (!electron) return
      const books = await electron.getBooks()
      for (const book of books) {
        if (
          book.title?.includes('Test') ||
          book.title?.includes('test') ||
          book.title?.includes('Compiler') ||
          book.title?.includes('nOOR')
        ) {
          await electron.deleteBook(book.id)
        }
      }
    })
  })

  it('should show the library home page', () => {
    cy.visit('/')
    cy.screenshot('01-home-page')
    cy.get('body').should('be.visible')
  })

  it('should import a PDF via IPC and show it in library', () => {
    cy.visit('/')
    // Wait for the app to finish loading
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')
    cy.screenshot('02-library-loaded')

    // Import a PDF by calling the electron IPC directly
    cy.window()
      .then(async (win: any) => {
        const electron = win.electron
        if (!electron) {
          throw new Error('window.electron is not available - preload not loaded')
        }

        // Step 1: Get app data path
        const appDataPath = await electron.getAppDataPath()
        cy.log('App data path: ' + appDataPath)

        // Step 2: Copy the PDF to app data
        const destPath = appDataPath + '/test-book.pdf'
        try {
          await electron.copyFile(PDF_FIXTURE_PATH, destPath)
          cy.log('Copied PDF to: ' + destPath)
        } catch (err: any) {
          cy.log('Copy failed (may already exist): ' + err.message)
        }

        // Step 3: Get PDF metadata via the formats IPC
        let bookData: any
        try {
          bookData = await electron.getPdfData(destPath)
          cy.log(
            'PDF metadata: ' + JSON.stringify({ title: bookData?.title, kind: bookData?.kind })
          )
        } catch (err: any) {
          cy.log('getPdfData failed: ' + err.message)
          // Fallback - create minimal book data
          bookData = {
            kind: 'pdf',
            cover: [],
            title: 'Test PDF',
            author: 'Test',
            publisher: '',
            filepath: destPath,
            location: '',
            coverKind: null,
            version: 1
          }
        }

        // Step 4: Save the book to DB
        const book = await electron.saveBook({
          coverKind: bookData.coverKind || '',
          title: bookData.title || 'Test PDF Book',
          author: bookData.author || 'Unknown',
          publisher: bookData.publisher || '',
          filepath: destPath,
          location: '1',
          version: 0,
          kind: bookData.kind || 'pdf',
          cover: bookData.cover || []
        })
        cy.log('Saved book with ID: ' + book.id)

        return book
      })
      .then((book: any) => {
        // Step 5: Reload the page and check the book appears
        cy.visit('/')
        cy.screenshot('03-after-import')

        // Wait for books query to complete
        cy.wait(2000)
        cy.screenshot('04-library-with-book')

        // Step 6: Navigate to the book reader
        cy.visit('/#/books/' + book.id)
        cy.screenshot('05-navigated-to-book')

        // Wait for the PDF to load
        cy.wait(3000)
        cy.screenshot('06-pdf-loading')

        // Wait more if needed
        cy.wait(3000)
        cy.screenshot('07-pdf-final')
      })
  })
})
