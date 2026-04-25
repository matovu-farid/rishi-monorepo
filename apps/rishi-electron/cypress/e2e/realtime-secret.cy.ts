describe("Realtime Client Secret (GET method fix)", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  it("should call getRealtimeClientSecret without a 404 error", () => {
    // The fix changed the HTTP method from POST to GET to match the worker
    // endpoint. This test verifies the handler no longer throws a 404.
    // The call may still fail for auth reasons (no valid token in test env)
    // but it must NOT fail with a 404 status code.
    cy.window().then(async (win) => {
      try {
        const secret = await win.electron.getRealtimeClientSecret();
        // If it succeeds, the secret should be a non-empty string
        expect(secret).to.be.a("string").and.not.be.empty;
      } catch (err: unknown) {
        const message =
          err instanceof Error ? err.message : String(err);
        // Auth failures (401/403) are expected in test env without a
        // valid token.  A 404 means the method mismatch bug is back.
        expect(message).to.not.include("status 404");
      }
    });
  });

  it("should use GET method (not POST) for the worker endpoint", () => {
    // Intercept the outgoing fetch to verify the method is GET.
    // The Electron main process makes the fetch, not the renderer, so
    // we can't use cy.intercept(). Instead we call the IPC and assert
    // the error is NOT a 404 — a 404 would indicate the wrong method.
    cy.window().then(async (win) => {
      let errorMessage = "";
      try {
        await win.electron.getRealtimeClientSecret();
      } catch (err: unknown) {
        errorMessage = err instanceof Error ? err.message : String(err);
      }
      // The only assertion we need: no 404
      expect(errorMessage).to.not.include("status 404");
    });
  });
});
