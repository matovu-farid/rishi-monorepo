describe("Premium Feature Dialog", () => {
  beforeEach(() => {
    cy.visit("/");
  });

  it("should show premium dialog when triggering a premium feature without auth", () => {
    // Attempt to use a premium feature (TTS or AI Chat)
    // The dialog should appear prompting sign-in
    cy.get("[data-testid='premium-dialog']").should("not.exist");

    // Trigger TTS which requires auth
    cy.get("[data-tour='ai-chat']").click({ force: true });

    // Verify dialog appears with expected content
    cy.get("[data-slot='dialog-content']").should("be.visible");
  });

  it("should show feature-specific content in the dialog", () => {
    // When the premium dialog is shown for TTS, it should display TTS-specific content
    cy.get("[data-tour='ai-chat']").click({ force: true });

    cy.get("[data-slot='dialog-content']").within(() => {
      // Should show a title, description, and sign-in button
      cy.get("[data-slot='dialog-title']").should("exist");
      cy.get("[data-slot='dialog-description']").should("exist");
      cy.contains("Sign in").should("be.visible");
      cy.contains("Maybe later").should("be.visible");
    });
  });

  it("should close the dialog when 'Maybe later' is clicked", () => {
    cy.get("[data-tour='ai-chat']").click({ force: true });

    cy.get("[data-slot='dialog-content']").should("be.visible");
    cy.contains("Maybe later").click();
    cy.get("[data-slot='dialog-content']").should("not.exist");
  });
});
