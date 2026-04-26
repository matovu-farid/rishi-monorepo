/**
 * File Import — comprehensive e2e tests for dialog, validation, metadata extraction.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe('File Import', () => {
  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')
  })

  afterEach(() => {
    cy.window().then(async (win) => {
      try {
        const books = await win.electron.getBooks()
        for (const book of books) {
          if (
            book.title?.includes('Import') ||
            book.title?.includes('Test') ||
            book.filepath?.includes('test-book')
          ) {
            await win.electron.deleteBook(book.id)
          }
        }
      } catch {
        // Best-effort cleanup
      }
    })
  })

  it('should have the Add Book button', () => {
    cy.contains('Add Book').should('be.visible').and('be.enabled')
  })

  it('should have the showOpenDialog IPC method for file picking', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('showOpenDialog')
      expect(win.electron.showOpenDialog).to.be.a('function')
    })
  })

  it('should have the checkFileSize IPC method for size validation', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('checkFileSize')
      expect(win.electron.checkFileSize).to.be.a('function')
    })
  })

  it('should validate file size and return ok for test fixtures', () => {
    cy.window().then(async (win) => {
      const result = await win.electron.checkFileSize('cypress/fixtures/test-book.pdf', 'pdf')
      expect(['ok', 'warn']).to.include(result)
    })
  })

  it('should extract PDF metadata via getPdfData', () => {
    cy.window().then(async (win) => {
      const data = await win.electron.getPdfData('cypress/fixtures/test-book.pdf')
      expect(data).to.have.property('kind', 'pdf')
      expect(data).to.have.property('filepath')
      expect(data).to.have.property('cover').that.is.an('array')
    })
  })

  it('should extract EPUB metadata via getBookData', () => {
    cy.window().then(async (win) => {
      const data = await win.electron.getBookData('cypress/fixtures/test-book.epub')
      expect(data).to.have.property('kind', 'epub')
      expect(data).to.have.property('filepath')
      expect(data).to.have.property('cover').that.is.an('array')
    })
  })

  it('should copy file to app data directory via copyFile', () => {
    cy.window().then(async (win) => {
      const appDataPath = await win.electron.getAppDataPath()
      expect(appDataPath).to.be.a('string').and.not.be.empty

      await win.electron.copyFile(
        'cypress/fixtures/test-book.pdf',
        appDataPath + '/import-test.pdf'
      )
      const exists = await win.electron.exists(appDataPath + '/import-test.pdf')
      expect(exists).to.be.true

      await win.electron.removeFile(appDataPath + '/import-test.pdf')
    })
  })

  it('should save an imported book to the database', () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData('cypress/fixtures/test-book.pdf')
      const book = await win.electron.saveBook({
        coverKind: pdfData.coverKind || '',
        title: 'Import Test Book',
        author: 'Test Author',
        publisher: '',
        filepath: 'cypress/fixtures/test-book.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: pdfData.cover || []
      })

      expect(book).to.have.property('id').that.is.a('number')
      expect(book).to.have.property('title', 'Import Test Book')
      expect(book).to.have.property('kind', 'pdf')
    })
  })

  it('should show the imported book in the library after save', () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData('cypress/fixtures/test-book.pdf')
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || '',
        title: 'Import Visible Test',
        author: 'Test Author',
        publisher: '',
        filepath: 'cypress/fixtures/test-book.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: pdfData.cover || []
      })
    })

    cy.visit('/')
    cy.contains('Import Visible Test', { timeout: 10000 }).should('be.visible')
  })

  it('should support drag and drop hints in the empty library', () => {
    cy.contains('drag and drop').should('be.visible')
  })

  it('should have the getAppDataPath IPC method for determining storage location', () => {
    cy.window().then(async (win) => {
      const appPath = await win.electron.getAppDataPath()
      expect(appPath).to.be.a('string')
      expect(appPath.length).to.be.greaterThan(0)
    })
  })

  it('should have the MOBI data extraction IPC methods', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('getMobiData')
      expect(win.electron.getMobiData).to.be.a('function')
    })
  })

  it('should have the DJVU data extraction IPC methods', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('getDjvuData')
      expect(win.electron.getDjvuData).to.be.a('function')
    })
  })

  it('should have the exists IPC method for checking file presence', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('exists')
      expect(win.electron.exists).to.be.a('function')
    })
  })
})
