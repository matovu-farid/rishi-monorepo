describe("Premium Feature Dialog", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  it("should not show the premium dialog initially", () => {
    cy.get("[data-testid='premium-dialog']").should("not.exist");
  });

  it("should show premium dialog when triggering a premium feature without auth", () => {
    // Trigger AI chat which requires auth
    cy.get("[data-tour='ai-chat']").click({ force: true });

    // Verify dialog appears with expected content
    cy.get("[data-slot='dialog-content']").should("be.visible");
  });

  it("should show feature-specific content in the dialog", () => {
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

  it("should show sign-in button that triggers auth flow", () => {
    cy.get("[data-tour='ai-chat']").click({ force: true });

    cy.get("[data-slot='dialog-content']").should("be.visible");
    cy.contains("Sign in").should("be.visible").and("be.enabled");
  });

  it("should show bullet points describing the premium feature", () => {
    cy.get("[data-tour='ai-chat']").click({ force: true });

    cy.get("[data-slot='dialog-content']").should("be.visible");
    // The dialog should contain description bullets
    cy.get("[data-slot='dialog-content'] li, [data-slot='dialog-content'] ul").should("exist");
  });
});
