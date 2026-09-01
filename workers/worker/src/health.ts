import { apiVersion, apiVersionHeader } from "./api-version";

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
    [apiVersionHeader]: apiVersion,
    [workerNameHeader]: workerName,
    [workerVersionHeader]: env.CF_VERSION_METADATA?.id ?? "local",
  };
}
