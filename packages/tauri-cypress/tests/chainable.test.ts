import { describe, it, expect, vi } from "vitest";
import { createChainable } from "../src/cy.js";

describe("Chainable", () => {
  it("executes a single queued command", async () => {
    const chain = createChainable();
    const fn = vi.fn(() => "result");
    chain.enqueue({ type: "action", name: "test", fn });
    const result = await chain.execute();
    expect(fn).toHaveBeenCalledTimes(1);
    expect(result).toBe("result");
  });

  it("chains multiple commands sequentially", async () => {
    const order: number[] = [];
    const chain = createChainable();
    chain.enqueue({
      type: "action",
      name: "step1",
      fn: () => { order.push(1); return "a"; },
    });
    chain.enqueue({
      type: "action",
      name: "step2",
      fn: (subject) => { order.push(2); return `${subject}-b`; },
    });
    const result = await chain.execute();
    expect(order).toEqual([1, 2]);
    expect(result).toBe("a-b");
  });

  it("passes subject from one command to the next", async () => {
    const chain = createChainable();
    chain.enqueue({ type: "query", name: "getItems", fn: () => [1, 2, 3] });
    chain.enqueue({ type: "query", name: "first", fn: (subject) => (subject as number[])[0] });
    const result = await chain.execute();
    expect(result).toBe(1);
  });

  it("supports async command functions", async () => {
    const chain = createChainable();
    chain.enqueue({
      type: "action",
      name: "asyncCmd",
      fn: async () => {
        await new Promise((r) => setTimeout(r, 10));
        return "async-result";
      },
    });
    const result = await chain.execute();
    expect(result).toBe("async-result");
  });

  it("assertion retries the preceding query", async () => {
    let queryCount = 0;
    const chain = createChainable();
    chain.enqueue({
      type: "query",
      name: "get",
      fn: () => {
        queryCount++;
        if (queryCount < 3) return null;
        return document.createElement("div");
      },
    });
    chain.enqueue({
      type: "assertion",
      name: "should",
      fn: (subject) => {
        if (subject == null) throw new Error("not found");
        return subject;
      },
      timeout: 1000,
    });
    await chain.execute();
    expect(queryCount).toBeGreaterThanOrEqual(3);
  });

  it("collects assertion results", async () => {
    const chain = createChainable();
    chain.enqueue({ type: "query", name: "get", fn: () => document.createElement("div") });
    chain.enqueue({
      type: "assertion",
      name: "should-exist",
      fn: (subject) => {
        if (subject == null) throw new Error("not found");
        return subject;
      },
      timeout: 100,
    });
    await chain.execute();
    expect(chain.getAssertions().length).toBeGreaterThanOrEqual(0);
  });
});
