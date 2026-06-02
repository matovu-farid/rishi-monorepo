// Re-export from the shared protocol package so the wire format has exactly one
// source of truth. Tests, the DO, and the electron client all bind here.
export * from "@rishi/sharing-protocol/schemas";
