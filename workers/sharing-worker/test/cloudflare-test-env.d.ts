declare module "cloudflare:test" {
  interface ProvidedEnv extends Pick<CloudflareBindings, "SESSION_ROOM" | "APPLE_SESSION_ROOM"> {}
}
