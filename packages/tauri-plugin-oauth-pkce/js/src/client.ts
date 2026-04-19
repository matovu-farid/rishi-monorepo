import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  getState,
  completeAuth,
  checkAuthStatus,
  signOut as signOutCmd,
  getToken as getTokenCmd,
  getUser as getUserCmd,
  type AuthCompleteResponse,
} from "./commands";

const MAX_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 1500;

export interface OAuthClientConfig {
  /** URL to open in the browser for authentication.
   * `state` and `code_challenge` will be appended as query params. */
  loginUrl: string;
}

type EventMap = {
  success: AuthCompleteResponse;
  error: { message: string; code?: string };
};

type EventHandler<K extends keyof EventMap> = (data: EventMap[K]) => void;

/**
 * Framework-agnostic OAuth client that orchestrates the full PKCE flow:
 * generates state, opens browser, listens for deep-link callback,
 * exchanges token with retry/backoff, and emits success/error events.
 */
export class OAuthClient {
  private config: OAuthClientConfig;
  private listeners: { [K in keyof EventMap]?: EventHandler<K>[] } = {};
  private pendingState: { state: string; codeChallenge: string } | null = null;
  private unlistenDeepLink: (() => void) | null = null;

  constructor(config: OAuthClientConfig) {
    this.config = config;
  }

  /** Register an event handler. */
  on<K extends keyof EventMap>(event: K, handler: EventHandler<K>): void {
    if (!this.listeners[event]) {
      this.listeners[event] = [];
    }
    this.listeners[event]!.push(handler);
  }

  /** Remove an event handler. */
  off<K extends keyof EventMap>(event: K, handler: EventHandler<K>): void {
    const list = this.listeners[event];
    if (list) {
      this.listeners[event] = list.filter((h) => h !== handler) as typeof list;
    }
  }

  private emit<K extends keyof EventMap>(event: K, data: EventMap[K]): void {
    const list = this.listeners[event];
    if (list) {
      for (const handler of list) {
        handler(data);
      }
    }
  }

  /**
   * Start the OAuth flow:
   * 1. Generate PKCE state
   * 2. Register deep-link listener
   * 3. Open browser with login URL
   */
  async startFlow(): Promise<void> {
    const result = await getState();
    this.pendingState = result;

    // Register deep-link listener before opening browser
    await this.registerDeepLinkListener();

    const separator = this.config.loginUrl.includes("?") ? "&" : "?";
    const url =
      this.config.loginUrl +
      separator +
      `state=${encodeURIComponent(result.state)}` +
      `&code_challenge=${encodeURIComponent(result.codeChallenge)}`;

    await openUrl(url);
  }

  private async registerDeepLinkListener(): Promise<void> {
    // Clean up any previous listener
    this.cleanupDeepLinkListener();

    const unlisten = await onOpenUrl(async (urls) => {
      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          this.emit("error", { message: "Malformed callback URL", code: "MALFORMED_URL" });
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) {
          this.emit("error", { message: "Missing state parameter", code: "MISSING_STATE" });
          continue;
        }

        // Validate state matches if we have a pending flow
        if (this.pendingState && callbackState !== this.pendingState.state) {
          this.emit("error", { message: "State mismatch", code: "STATE_MISMATCH" });
          continue;
        }

        await this.exchangeWithRetry(callbackState);
      }
    });

    this.unlistenDeepLink = unlisten;
  }

  private async exchangeWithRetry(state: string): Promise<void> {
    let lastError: unknown = null;

    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        const result = await completeAuth(state);
        this.pendingState = null;
        this.cleanupDeepLinkListener();
        this.emit("success", result);
        return;
      } catch (error) {
        lastError = error;
        const errMsg = String(error);

        // Terminal failures — stop retrying
        if (
          errMsg.includes("already used") ||
          errMsg.includes("permanently failed") ||
          errMsg.includes("Max retries")
        ) {
          break;
        }

        if (attempt < MAX_RETRIES) {
          const is409 = errMsg.includes("409") || errMsg.includes("in progress");
          const delay = is409
            ? BASE_RETRY_DELAY_MS * 3
            : BASE_RETRY_DELAY_MS * attempt;

          // Check status if endpoint is configured
          try {
            const status = await checkAuthStatus(state);
            if (status.status === "not_found" || status.status === "completed") {
              break;
            }
          } catch {
            // Status check failed — continue with retry
          }

          await new Promise((r) => setTimeout(r, delay));
        }
      }
    }

    this.pendingState = null;
    this.cleanupDeepLinkListener();
    this.emit("error", {
      message: describeError(lastError),
      code: "AUTH_FAILED",
    });
  }

  private cleanupDeepLinkListener(): void {
    if (this.unlistenDeepLink) {
      this.unlistenDeepLink();
      this.unlistenDeepLink = null;
    }
  }

  /** Get the auth token from the OS keychain. Throws if expired or missing. */
  async getToken(): Promise<string> {
    return getTokenCmd();
  }

  /** Get the cached user from the Tauri store. */
  async getUser(): Promise<Record<string, unknown>> {
    return getUserCmd();
  }

  /** Sign out: clear keychain, optionally revoke token server-side. */
  async signOut(): Promise<void> {
    this.pendingState = null;
    this.cleanupDeepLinkListener();
    return signOutCmd();
  }
}

/** Extract a user-friendly message from an error. */
function describeError(err: unknown): string {
  if (!err) return "Unknown error";
  const raw = String(err);
  const match = raw.match(/"error"\s*:\s*"([^"]+)"/);
  if (match) return match[1];
  if (raw.includes("PKCE")) return "PKCE verification failed. Please sign in again.";
  if (raw.includes("state not found")) return "Sign-in session expired. Please try again.";
  if (raw.includes("already used")) return "This sign-in link was already used.";
  const trimmed = raw.replace(/^.*?:\s*/, "").slice(0, 200);
  return trimmed || raw.slice(0, 200);
}
