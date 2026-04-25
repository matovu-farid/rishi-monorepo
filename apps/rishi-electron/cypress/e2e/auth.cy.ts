describe("Authentication", () => {
  beforeEach(() => {
    cy.visit("/");
  });

  afterEach(() => {
    cy.clearLocalStorage();
  });

  it("should show sign in button when not authenticated", () => {
    cy.contains("Sign In").should("be.visible");
  });

  it("should show welcome modal on first visit", () => {
    cy.clearLocalStorage();
    cy.visit("/");
    cy.contains("Welcome to Rishi").should("be.visible");
  });

  it("should dismiss welcome modal with Continue Without Signing In", () => {
    cy.clearLocalStorage();
    cy.visit("/");
    cy.contains("Maybe later").click();
    cy.contains("Welcome to Rishi").should("not.exist");
  });

  it("should persist welcome dismissal across reloads", () => {
    cy.clearLocalStorage();
    cy.visit("/");
    cy.contains("Maybe later").click();
    cy.reload();
    cy.contains("Welcome to Rishi").should("not.exist");
  });

  it("should show the welcome modal with sign-in option", () => {
    cy.clearLocalStorage();
    cy.visit("/");
    cy.contains("Welcome to Rishi").should("be.visible");
    cy.contains("Sign in").should("be.visible");
  });

  describe("Auth IPC methods", () => {
    it("should expose getOAuthState for PKCE flow", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("getOAuthState");
        expect(win.electron.getOAuthState).to.be.a("function");
      });
    });

    it("should expose completeAuth for PKCE completion", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("completeAuth");
        expect(win.electron.completeAuth).to.be.a("function");
      });
    });

    it("should expose checkAuthStatus for polling", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("checkAuthStatus");
        expect(win.electron.checkAuthStatus).to.be.a("function");
      });
    });

    it("should expose signout for clearing auth state", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("signout");
        expect(win.electron.signout).to.be.a("function");
      });
    });

    it("should expose refreshAuthToken for token refresh", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("refreshAuthToken");
        expect(win.electron.refreshAuthToken).to.be.a("function");
      });
    });

    it("should expose getUser for fetching user profile", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("getUser");
        expect(win.electron.getUser).to.be.a("function");
      });
    });

    it("should expose onDeepLink for receiving deep link callbacks", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("onDeepLink");
        expect(win.electron.onDeepLink).to.be.a("function");
      });
    });

    it("refreshAuthToken returns null when not authenticated", () => {
      cy.window().then(async (win) => {
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

    it("should expose auth debug methods", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("logAuthDebug");
        expect(win.electron.logAuthDebug).to.be.a("function");
        expect(win.electron).to.have.property("getAuthDebug");
        expect(win.electron.getAuthDebug).to.be.a("function");
      });
    });

    it("should expose openExternal for opening auth URL in system browser", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("openExternal");
        expect(win.electron.openExternal).to.be.a("function");
      });
    });
  });
});
