/**
 * Library (Home Page) — comprehensive e2e tests.
 *
 * NOTE: Do NOT import `path` or use `__dirname` — they are Node.js APIs
 * unavailable in the Cypress browser context.
 */

const seedElectron = (overrides = {}) => {
  cy.window().then((win) => {
    const defaults = {
      getBooks: cy.stub().resolves([]),
      getBook: cy.stub().resolves(null),
      saveBook: cy.stub().resolves({ id: 1 }),
      deleteBook: cy.stub().resolves(undefined),
      getPdfData: cy.stub().resolves({
        kind: 'pdf',
        filepath: '/mock/test.pdf',
        cover: [],
        coverKind: '',
        title: 'Mock PDF',
        author: 'Mock Author',
        publisher: ''
      }),
      getBookData: cy.stub().resolves({
        kind: 'epub',
        filepath: '/mock/test.epub',
        cover: [],
        coverKind: '',
        title: 'Mock EPUB',
        author: 'Mock Author',
        publisher: ''
      }),
      updateBookLocation: cy.stub().resolves(undefined),
      getAppDataPath: cy.stub().resolves('/tmp/test-app-data'),
      showOpenDialog: cy.stub().resolves({ filePaths: [] }),
      getDefaultBookFolders: cy.stub().resolves([]),
      scanForBooks: cy.stub().resolves(0),
      cancelScan: cy.stub().resolves(undefined),
      getAuthToken: cy.stub().resolves(null),
      getStoreValue: cy.stub().resolves(null),
      setStoreValue: cy.stub().resolves(undefined),
      on: cy.stub().returns(() => {}),
      once: cy.stub(),
      send: cy.stub(),
      dbQuery: cy.stub().resolves([]),
      dbRun: cy.stub().resolves({ changes: 0, lastInsertRowid: 0 }),
      isDev: cy.stub().resolves(true),
      getDevBypassSecret: cy.stub().resolves('test-secret'),
      checkFileSize: cy.stub().resolves('ok'),
      readFile: cy.stub().resolves(new ArrayBuffer(0)),
      writeFile: cy.stub().resolves(undefined),
      exists: cy.stub().resolves(false),
      mkdir: cy.stub().resolves(undefined),
      readDir: cy.stub().resolves([]),
      removeFile: cy.stub().resolves(undefined),
      getDirSize: cy.stub().resolves(0),
      getCacheFileStats: cy.stub().resolves([]),
      processJob: cy.stub().resolves(undefined),
      copyFile: cy.stub().resolves(undefined),
      getAllPageDataByBookId: cy.stub().resolves([]),
      embed: cy.stub().resolves([]),
      searchVectors: cy.stub().resolves([]),
      getRealtimeClientSecret: cy.stub().resolves('test-key'),
      openExternal: cy.stub().resolves(undefined),
      getOAuthState: cy.stub().resolves({ state: 's', codeChallenge: 'c' }),
      getUserFromStore: cy.stub().resolves(null),
      saveUserToStore: cy.stub().resolves(undefined),
      saveAuthToken: cy.stub().resolves(undefined),
      clearAuth: cy.stub().resolves(undefined),
      dumpError: cy.stub().resolves(undefined),
      getOsInfo: cy.stub().resolves({ platform: 'darwin', arch: 'arm64', version: '25.0' })
    }
    ;(win as any).electron = { ...defaults, ...overrides }
  })
}

describe('Library (Home Page)', () => {
  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')
  })

  afterEach(() => {
    cy.window().then(async (win) => {
      try {
        const books = await win.electron.getBooks()
        for (const book of books) {
          if (book.title?.includes('Test') || book.title?.includes('Library')) {
            await win.electron.deleteBook(book.id)
          }
        }
      } catch {
        // Cleanup best-effort
      }
    })
  })

  it('should load and display the library UI', () => {
    cy.get('body').should('be.visible')
    cy.contains('Add Book').should('be.visible')
    cy.contains('Import from Computer').should('be.visible')
  })

  it('should show empty state when no books are present', () => {
    cy.contains('No books yet').should('be.visible')
    cy.contains('drag and drop').should('be.visible')
  })

  it('should show search input in the library header', () => {
    cy.get('input[placeholder*="Search"]').should('be.visible')
  })

  it('should filter books by search query without crashing', () => {
    cy.get('input[placeholder*="Search"]').type('nonexistent')
    cy.get('input[placeholder*="Search"]').should('have.value', 'nonexistent')
  })

  it('should display book cards with title and author after import', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Test Book',
        author: 'Test Author',
        publisher: '',
        filepath: '/mock/test.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
    })

    cy.visit('/')
    cy.contains('Library Test Book', { timeout: 10000 }).should('be.visible')
    cy.contains('Test Author').should('be.visible')
  })

  it('should navigate to the reader when clicking a book card', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Navigate Test',
        author: 'Test Author',
        publisher: '',
        filepath: '/mock/test.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
    })

    cy.visit('/')
    cy.contains('Library Navigate Test', { timeout: 10000 }).click()
    cy.url().should('include', '/books/')
  })

  it('should delete a book via right-click context menu', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Delete Test',
        author: 'Test Author',
        publisher: '',
        filepath: '/mock/test.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
    })

    cy.visit('/')
    cy.contains('Library Delete Test', { timeout: 10000 }).should('be.visible')
    cy.contains('Library Delete Test').rightclick()
    cy.contains('Delete').should('be.visible')
    cy.contains('Delete').click()
    cy.contains('Library Delete Test').should('not.exist')
  })

  it('should show the context menu with Delete option on right-click and dismiss it', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Context Menu Test',
        author: 'Test Author',
        publisher: '',
        filepath: '/mock/test.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
    })

    cy.visit('/')
    cy.contains('Library Context Menu Test', { timeout: 10000 }).rightclick()
    cy.contains('Delete').should('be.visible')
    // Clicking elsewhere should dismiss the menu
    cy.get('body').click()
    cy.contains('Delete').should('not.exist')
  })

  it('should filter books by title using the search field', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Alpha Book',
        author: 'Author A',
        publisher: '',
        filepath: '/mock/alpha.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Beta Book',
        author: 'Author B',
        publisher: '',
        filepath: '/mock/beta.epub',
        location: '1',
        version: 0,
        kind: 'epub',
        cover: []
      })
    })

    cy.visit('/')
    cy.contains('Library Alpha Book', { timeout: 10000 }).should('be.visible')
    cy.contains('Library Beta Book').should('be.visible')

    cy.get('input[placeholder*="Search"]').type('Alpha')
    cy.contains('Library Alpha Book').should('be.visible')
    cy.contains('Library Beta Book').should('not.exist')

    cy.get('input[placeholder*="Search"]').clear()
    cy.contains('Library Alpha Book').should('be.visible')
    cy.contains('Library Beta Book').should('be.visible')
  })

  it('should show the book grid with data-tour attribute', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library Grid Test',
        author: 'Test',
        publisher: '',
        filepath: '/mock/grid.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
    })

    cy.visit('/')
    cy.get('[data-tour="book-grid"]', { timeout: 10000 }).should('be.visible')
    cy.get('[data-tour="book-grid"] > div').should('have.length.at.least', 1)
  })

  it('should clear the search field and show all books again', () => {
    cy.window().then(async (win) => {
      await win.electron.saveBook({
        coverKind: '',
        title: 'Library ClearSearch Test',
        author: 'Test',
        publisher: '',
        filepath: '/mock/clear.pdf',
        location: '1',
        version: 0,
        kind: 'pdf',
        cover: []
      })
    })

    cy.visit('/')
    cy.contains('Library ClearSearch Test', { timeout: 10000 }).should('be.visible')
    cy.get('input[placeholder*="Search"]').type('ZZZ_NO_MATCH')
    cy.contains('Library ClearSearch Test').should('not.exist')
    cy.get('input[placeholder*="Search"]').clear()
    cy.contains('Library ClearSearch Test').should('be.visible')
  })

  it('should show the Add Book button as enabled', () => {
    cy.contains('Add Book').should('be.visible').and('be.enabled')
  })

  it('should show the Import from Computer button as enabled', () => {
    cy.contains('Import from Computer').should('be.visible').and('be.enabled')
  })
})
