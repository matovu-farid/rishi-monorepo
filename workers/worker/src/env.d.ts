export {};

declare global {
	interface Env {
		// Error reporting is intentionally optional; an absent DSN disables Sentry.
		SENTRY_DSN?: string;
		// Non-production controls. Keep these out of wrangler.jsonc secrets.required.
		ENABLE_TEST_AUTH?: string;
		TEST_AUTH_SECRET?: string;
		ENABLE_OPS_ADMIN?: string;
		OPS_ADMIN_SECRET?: string;
	}
}
