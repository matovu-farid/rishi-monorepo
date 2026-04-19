import { describe, it, cy, beforeEach } from 'tauri-cypress'

describe('Authentication', () => {
  beforeEach(() => {
    cy.mockCommand('check_auth_status', { authenticated: false, user: null })
    cy.visit('/')
  })

  it('shows unauthenticated state when not logged in', () => {
    cy.ipcLog('check_auth_status').should('have.length', 1)
  })

  it('can mock authenticated state', () => {
    cy.mockCommand('check_auth_status', {
      authenticated: true,
      user: { id: 'user-1', email: 'test@example.com', name: 'Test User' }
    })
    cy.visit('/')
    cy.ipcLog('check_auth_status').should('have.length', 1)
    cy.ipcLog('check_auth_status').first().should('have.property', 'mocked', true)
  })
})
