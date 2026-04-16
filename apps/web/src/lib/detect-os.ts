export type DetectedOs = "mac" | "windows" | "linux" | "mobile" | "unknown";

export function detectOs(headers: Headers): DetectedOs {
  const ua = headers.get("user-agent") ?? "";

  // 1. Mobile UAs win, even if sec-ch-ua-platform says "Android"
  if (/android|iphone|ipad|ipod/i.test(ua)) {
    return "mobile";
  }

  // 2. sec-ch-ua-platform (quotes included in the header value)
  const rawPlatform = headers.get("sec-ch-ua-platform");
  if (rawPlatform) {
    const platform = rawPlatform.replace(/^"|"$/g, "");
    if (platform === "macOS") return "mac";
    if (platform === "Windows") return "windows";
    if (platform === "Linux") return "linux";
    if (platform === "Android" || platform === "iOS") return "mobile";
  }

  // 3. UA fallback
  if (/Mac OS X|Macintosh/i.test(ua)) return "mac";
  if (/Windows NT/i.test(ua)) return "windows";
  if (/Linux/i.test(ua)) return "linux";

  return "unknown";
}
