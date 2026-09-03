export type TurnIceServer = {
  urls: string[];
  username?: string;
  credential?: string;
};

const ALLOWED_PORTS = new Set([80, 3478, 443, 5349]);

function allowedURL(value: string): boolean {
  try {
    const url = new URL(value);
    if (!(url.protocol === "stun:" || url.protocol === "turn:" || url.protocol === "turns:")) return false;
    const port = url.port ? Number(url.port) : url.protocol === "turns:" ? 5349 : 3478;
    return ALLOWED_PORTS.has(port);
  } catch {
    return false;
  }
}

function filterIceServers(value: unknown): TurnIceServer[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    if (!entry || typeof entry !== "object") return [];
    const item = entry as { urls?: unknown; username?: unknown; credential?: unknown };
    const urls = (Array.isArray(item.urls) ? item.urls : [item.urls]).filter((url): url is string => typeof url === "string" && allowedURL(url));
    if (urls.length === 0) return [];
    return [{ urls, ...(typeof item.username === "string" ? { username: item.username } : {}), ...(typeof item.credential === "string" ? { credential: item.credential } : {}) }];
  });
}

export async function generateTurnIceServers(env: { TURN_KEY_ID?: string; TURN_API_TOKEN?: string }, ttlSeconds = 3600): Promise<TurnIceServer[]> {
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
    // Direct peer connections can still succeed through Cloudflare's public
    // STUN endpoint. Relay credentials remain preferred when configured, but
    // their absence must not disable the mesh entirely.
    return [{ urls: ["stun:stun.cloudflare.com:3478"] }];
  }
  const response = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`, {
    method: "POST",
    headers: { authorization: `Bearer ${env.TURN_API_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ ttl: Math.max(60, Math.min(ttlSeconds, 86_400)) }),
  });
  if (!response.ok) throw new Error("TURN_UNAVAILABLE");
  const body = await response.json() as { iceServers?: unknown };
  const iceServers = filterIceServers(body.iceServers);
  if (iceServers.length === 0) throw new Error("TURN_UNAVAILABLE");
  return iceServers;
}
