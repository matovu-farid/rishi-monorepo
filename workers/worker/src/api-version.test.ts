import { describe, expect, it } from "vitest";
import {
  apiVersion,
  apiVersionHeader,
  sharedReadingRoutePrefix,
} from "./api-version";

describe("API version contract", () => {
  it("defines the current version and shared-reading prefix in one place", () => {
    expect(apiVersion).toBe("v1");
    expect(sharedReadingRoutePrefix).toBe("/api/v1/reading-sessions");
    expect(apiVersionHeader).toBe("X-Rishi-API-Version");
  });

});
