const apiVersionHeader = "X-Rishi-API-Version" as const;
export const workerNameHeader = "X-Rishi-Worker-Name" as const;
export const workerVersionHeader = "X-Rishi-Worker-Version" as const;

type VersionEnvironment = {
  CF_VERSION_METADATA?: { id?: string };
};

export function workerMetadataHeaders(
  env: VersionEnvironment,
  workerName: string,
): Record<string, string> {
  return {
    [apiVersionHeader]: "v1",
    [workerNameHeader]: workerName,
    [workerVersionHeader]: env.CF_VERSION_METADATA?.id ?? "local",
  };
}
