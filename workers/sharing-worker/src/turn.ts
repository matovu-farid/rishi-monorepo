import { Effect } from "effect";
import { SharingDiagnostics, SharingHttpClient, TurnCredentialProvider, makeSharingWorkerLayer } from "./session-sharing-effect";
import { SharingDependencyFailure, TurnUnavailableFailure } from "./session-sharing-errors";

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

export function generateTurnIceServersEffect(
  env: { TURN_KEY_ID?: string; TURN_API_TOKEN?: string },
  ttlSeconds = 3600,
  correlationId?: string,
): Effect.Effect<TurnIceServer[], TurnUnavailableFailure, TurnCredentialProvider | SharingHttpClient | SharingDiagnostics> {
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
    // Direct peer connections can still succeed through Cloudflare's public
    // STUN endpoint. Relay credentials remain preferred when configured, but
    // their absence must not disable the mesh entirely.
    return Effect.succeed([{ urls: ["stun:stun.cloudflare.com:3478"] }]);
  }
  return Effect.gen(function* () {
    const provider = yield* TurnCredentialProvider;
    const diagnostics = yield* SharingDiagnostics;
    const reportFailure = (status?: number) => diagnostics.emit({
      event: "sharing.turn.provider_failure",
      ...(correlationId ? { correlationId } : {}),
      operation: "turn.credentials",
      stage: "turn.credentials",
      outcome: "error",
      code: "TURN_UNAVAILABLE",
      ...(status === undefined ? {} : { status }),
    });
    const response = yield* provider.issue({
      keyId: env.TURN_KEY_ID!,
      apiToken: env.TURN_API_TOKEN!,
      ttlSeconds: Math.max(60, Math.min(ttlSeconds, 86_400)),
    }).pipe(
      Effect.tapError(() => reportFailure()),
      Effect.catchTag("SharingDependencyFailure", (failure: SharingDependencyFailure) =>
        Effect.fail(new TurnUnavailableFailure(failure)),
      ),
    );
    if (!response.ok) {
      yield* reportFailure(response.status);
      return yield* Effect.fail(new TurnUnavailableFailure());
    }
    const body = yield* Effect.tryPromise({
      try: () => response.json() as Promise<{ iceServers?: unknown }>,
      catch: (cause) => cause,
    }).pipe(
      Effect.tapError(() => reportFailure(response.status)),
      Effect.catchAll((cause) => Effect.fail(new TurnUnavailableFailure(cause))),
    );
    const iceServers = filterIceServers(body.iceServers);
    if (iceServers.length === 0) {
      yield* reportFailure(response.status);
      return yield* Effect.fail(new TurnUnavailableFailure());
    }
    return iceServers;
  });
}

export async function generateTurnIceServers(
  env: { TURN_KEY_ID?: string; TURN_API_TOKEN?: string; fetcher?: typeof fetch },
  ttlSeconds = 3600,
  correlationId?: string,
): Promise<TurnIceServer[]> {
  return Effect.runPromise(Effect.provide(
    generateTurnIceServersEffect(env, ttlSeconds, correlationId),
    makeSharingWorkerLayer({ AUTH_BASE_URL: "", ...env }, env.fetcher),
  ));
}
