describe("Auth Token Refresh", () => {
  beforeEach(() => {
    cy.visit("/");
  });

  it("should expose refreshAuthToken on the electron API", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("refreshAuthToken");
      expect(win.electron.refreshAuthToken).to.be.a("function");
    });
  });

  it("should expose getUser on the electron API", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getUser");
      expect(win.electron.getUser).to.be.a("function");
    });
  });

  it("should expose logAuthDebug on the electron API", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("logAuthDebug");
      expect(win.electron.logAuthDebug).to.be.a("function");
    });
  });

  it("should expose getAuthDebug on the electron API", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getAuthDebug");
      expect(win.electron.getAuthDebug).to.be.a("function");
    });
  });

  it("refreshAuthToken returns null when not authenticated", () => {
    cy.window().then(async (win) => {
      // When there's no stored token, refresh should return null
      const result = await win.electron.refreshAuthToken();
      expect(result).to.be.null;
    });
  });

  it("getUser rejects with error when not authenticated", () => {
    cy.window().then((win) => {
      win.electron.getUser("test_user").then(
        () => {
          throw new Error("Expected getUser to reject");
        },
        (err: Error) => {
          expect(err.message).to.include("Not authenticated");
        }
      );
    });
  });
});
