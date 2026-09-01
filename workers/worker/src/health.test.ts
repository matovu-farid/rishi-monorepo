import { describe, expect, it } from "vitest";
import {
  workerMetadataHeaders,
  workerNameHeader,
  workerVersionHeader,
} from "./health";

describe("Worker health metadata", () => {
  it("identifies the API revision, worker, and local version", () => {
    expect(workerMetadataHeaders({}, "rishi-worker")).toEqual({
      "X-Rishi-API-Version": "v1",
      [workerNameHeader]: "rishi-worker",
      [workerVersionHeader]: "local",
    });
  });

  it("uses the Cloudflare version id when deployed", () => {
    expect(workerMetadataHeaders({ CF_VERSION_METADATA: { id: "version-123" } }, "rishi-worker")[workerVersionHeader])
      .toBe("version-123");
  });
});
