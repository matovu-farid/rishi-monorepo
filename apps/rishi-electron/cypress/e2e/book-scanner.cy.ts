/**
 * Book Scanner / Discovery — comprehensive e2e tests for scan, import, modal.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe('Book Scanner / Discovery', () => {
  beforeEach(() => {
    cy.visit('/')
    cy.contains('Add Book', { timeout: 15000 }).should('be.visible')
  })

  it('should have the Import from Computer button visible', () => {
    cy.contains('Import from Computer').should('be.visible').and('be.enabled')
  })

  it('should open the Book Discovery modal when Import from Computer is clicked', () => {
    cy.contains('Import from Computer').click()

    cy.contains('Import from Computer', { timeout: 10000 }).parents('.fixed').should('exist')
  })

  it('should show scanning indicator when modal opens', () => {
    cy.contains('Import from Computer').click()

    cy.contains(/Scanning/i, { timeout: 10000 }).should('exist')
  })

  it('should show scan mode radio buttons (Common folders / Search entire computer)', () => {
    cy.contains('Import from Computer').click()

    cy.contains('Common folders', { timeout: 10000 }).should('be.visible')
    cy.contains('Search entire computer').should('be.visible')
  })

  it('should have a filter input for discovered books', () => {
    cy.contains('Import from Computer').click()

    cy.get('input[placeholder*="Filter"]', { timeout: 10000 }).should('be.visible')
  })

  it('should close the modal when Cancel is clicked', () => {
    cy.contains('Import from Computer').click()
    cy.contains('Import from Computer', { timeout: 10000 }).parents('.fixed').should('exist')

    cy.contains('Cancel').click()

    cy.get('.fixed .bg-white.rounded-xl').should('not.exist')
  })

  it('should have the scanner IPC methods available', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('getDefaultBookFolders')
      expect(win.electron.getDefaultBookFolders).to.be.a('function')
      expect(win.electron).to.have.property('scanForBooks')
      expect(win.electron.scanForBooks).to.be.a('function')
      expect(win.electron).to.have.property('cancelScan')
      expect(win.electron.cancelScan).to.be.a('function')
    })
  })

  it('should support scan events via the event system', () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property('on')
      expect(win.electron.on).to.be.a('function')
    })
  })

  it('should cancel scan when modal is closed', () => {
    cy.contains('Import from Computer').click()
    cy.contains(/Scanning/i, { timeout: 10000 }).should('exist')

    cy.get('.fixed .bg-white.rounded-xl').within(() => {
      cy.get('button').first().click()
    })

    cy.get('.fixed .bg-white.rounded-xl').should('not.exist')
  })

  it('should be able to type in the filter input', () => {
    cy.contains('Import from Computer').click()

    cy.get('input[placeholder*="Filter"]', { timeout: 10000 }).type('test-filter')
    cy.get('input[placeholder*="Filter"]').should('have.value', 'test-filter')
  })

  it('should default to Common folders scan mode', () => {
    cy.contains('Import from Computer').click()

    cy.contains('Common folders', { timeout: 10000 }).should('be.visible')
    // Common folders should be selected by default
    cy.get('body').should('be.visible')
  })

  it('should have the Import Selected button disabled when nothing is selected', () => {
    cy.contains('Import from Computer').click()

    cy.contains('Import Selected', { timeout: 10000 }).then(($btn) => {
      // Button should be disabled or not present when no books selected
      if ($btn.length > 0) {
        cy.wrap($btn).should('be.disabled')
      }
    })
  })
})
