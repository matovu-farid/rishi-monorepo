/**
 * Type-level tests for `TtsIpcChannels` (T-P1.4 / DRY-002).
 *
 * Asserts that the shared port has an optional `linkOrCopyFile` channel
 * so electron can supply a hardlink-preferring implementation without
 * forcing mobile to add a copy alias.
 */
import { describe, it, expectTypeOf } from "vitest";
import type { TtsIpcChannels } from "./types";

describe("TtsIpcChannels — linkOrCopyFile is an optional port", () => {
  it("declares linkOrCopyFile?: (src, dest) => Promise<void>", () => {
    // The signature must match copyFile (string, string) → Promise<void>
    // and MUST be optional so the legacy mobile ports remain assignable.
    expectTypeOf<TtsIpcChannels["linkOrCopyFile"]>().toEqualTypeOf<
      ((src: string, dest: string) => Promise<void>) | undefined
    >();
  });

  it("keeps copyFile mandatory (fallback path)", () => {
    expectTypeOf<TtsIpcChannels["copyFile"]>().toEqualTypeOf<
      (src: string, dest: string) => Promise<void>
    >();
  });

  it("accepts an implementation that omits linkOrCopyFile (mobile)", () => {
    // The legacy 9-method port must still satisfy TtsIpcChannels — confirms
    // the new field is truly optional, not a breaking change.
    const legacy = {} as Omit<TtsIpcChannels, "linkOrCopyFile">;
    expectTypeOf(legacy).toExtend<TtsIpcChannels>();
  });
});
