import { describe, it, expect, beforeEach } from "vitest";
import { useNavStore } from "./navStore";

describe("navStore", () => {
  beforeEach(() => {
    useNavStore.setState({
      navState: "idle",
      send: null,
    });
  });

  it("should start in idle state", () => {
    expect(useNavStore.getState().navState).toBe("idle");
  });

  it("should have null send function initially", () => {
    expect(useNavStore.getState().send).toBeNull();
  });

  it("should set nav state", () => {
    useNavStore.getState().setNavState("navigating");
    expect(useNavStore.getState().navState).toBe("navigating");
  });

  it("should set send function", () => {
    const mockSend = vi.fn();
    useNavStore.getState().setSend(mockSend);
    expect(useNavStore.getState().send).toBe(mockSend);
  });

  it("should allow clearing send function", () => {
    const mockSend = vi.fn();
    useNavStore.getState().setSend(mockSend);
    useNavStore.getState().setSend(null);
    expect(useNavStore.getState().send).toBeNull();
  });
});
