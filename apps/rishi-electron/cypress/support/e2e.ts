// Cypress E2E support file
// Add custom commands and global hooks here

Cypress.on("uncaught:exception", (_err) => {
  // Prevent Cypress from failing tests on uncaught exceptions
  return false;
});
