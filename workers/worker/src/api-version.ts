/**
 * Version identifiers for contracts consumed by installed clients.
 *
 * Legacy `/api/...` routes are intentionally not represented here: they are
 * frozen and must not be changed to serve a newer contract.
 */
export const apiVersion = "v1" as const;
export const apiVersionHeader = "X-Rishi-API-Version" as const;
export const sharedReadingRoutePrefix = "/api/v1/reading-sessions" as const;
