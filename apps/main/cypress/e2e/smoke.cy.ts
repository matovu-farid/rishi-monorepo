import { describe, it, cy, beforeEach, afterEach } from 'tauri-cypress'

describe('Rishi App Smoke Test', () => {
  beforeEach(() => {
    cy.visit('/')
  })

  it('app loads and shows the main UI', () => {
    cy.get('#root').should('exist')
    cy.get('#root').should('be.visible')
  })

  it('can navigate the app shell', () => {
    cy.get('#root').should('exist')
    cy.wait(500)
    cy.screenshot('app-loaded')
  })
})
