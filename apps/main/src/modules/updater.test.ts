import { describe, it, expect } from "vitest";
import { renderStatus, type UpdateStatus } from "./updater";

describe("renderStatus", () => {
  it("returns null for idle", () => {
    expect(renderStatus({ kind: "idle" })).toBeNull();
  });

  it("describes the checking state", () => {
    expect(renderStatus({ kind: "checking" })).toBe("Checking for updates…");
  });

  it("shows percentage while downloading when total is known", () => {
    const s: UpdateStatus = { kind: "downloading", downloaded: 25, total: 100 };
    expect(renderStatus(s)).toBe("Downloading… 25%");
  });

  it("floors fractional percentages while downloading", () => {
    const s: UpdateStatus = { kind: "downloading", downloaded: 33, total: 100 };
    expect(renderStatus(s)).toBe("Downloading… 33%");
    const s2: UpdateStatus = { kind: "downloading", downloaded: 1, total: 3 };
    expect(renderStatus(s2)).toBe("Downloading… 33%");
  });

  it("reports 0% when total is unknown", () => {
    const s: UpdateStatus = { kind: "downloading", downloaded: 500, total: 0 };
    expect(renderStatus(s)).toBe("Downloading… 0%");
  });

  it("describes the installing state", () => {
    expect(renderStatus({ kind: "installing" })).toBe("Installing…");
  });

  it("describes the error state", () => {
    expect(renderStatus({ kind: "error", message: "boom" })).toBe(
      "Update failed. See console for details."
    );
  });
});
