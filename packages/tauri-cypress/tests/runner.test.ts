import { describe as desc, it as test, expect, vi } from "vitest";
import { createTestRunner, type TestRunnerResult } from "../src/runner.js";

desc("TestRunner", () => {
  test("runs a single test and reports passed", async () => {
    const runner = createTestRunner();
    runner.describe("Suite", () => {
      runner.it("passes", () => {});
    });
    const suiteResults = await runner.run();
    expect(suiteResults).toHaveLength(1);
    expect(suiteResults[0].testId).toBe("Suite > passes");
    expect(suiteResults[0].status).toBe("passed");
  });

  test("reports failed test with error", async () => {
    const runner = createTestRunner();
    runner.describe("Suite", () => {
      runner.it("fails", () => { throw new Error("boom"); });
    });
    const results = await runner.run();
    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("failed");
    expect(results[0].error).toBe("boom");
  });

  test("runs beforeEach before each test", async () => {
    const runner = createTestRunner();
    const order: string[] = [];
    runner.describe("Suite", () => {
      runner.beforeEach(() => { order.push("before"); });
      runner.it("test1", () => { order.push("test1"); });
      runner.it("test2", () => { order.push("test2"); });
    });
    await runner.run();
    expect(order).toEqual(["before", "test1", "before", "test2"]);
  });

  test("runs afterEach after each test", async () => {
    const runner = createTestRunner();
    const order: string[] = [];
    runner.describe("Suite", () => {
      runner.afterEach(() => { order.push("after"); });
      runner.it("test1", () => { order.push("test1"); });
      runner.it("test2", () => { order.push("test2"); });
    });
    await runner.run();
    expect(order).toEqual(["test1", "after", "test2", "after"]);
  });

  test("supports nested describe blocks", async () => {
    const runner = createTestRunner();
    runner.describe("Outer", () => {
      runner.describe("Inner", () => {
        runner.it("nested test", () => {});
      });
    });
    const results = await runner.run();
    expect(results).toHaveLength(1);
    expect(results[0].testId).toBe("Outer > Inner > nested test");
    expect(results[0].status).toBe("passed");
  });

  test("supports async test functions", async () => {
    const runner = createTestRunner();
    runner.describe("Async", () => {
      runner.it("async test", async () => {
        await new Promise((r) => setTimeout(r, 10));
      });
    });
    const results = await runner.run();
    expect(results[0].status).toBe("passed");
  });

  test("measures duration_ms", async () => {
    const runner = createTestRunner();
    runner.describe("Timed", () => {
      runner.it("takes time", async () => {
        await new Promise((r) => setTimeout(r, 20));
      });
    });
    const results = await runner.run();
    expect(results[0].durationMs).toBeGreaterThanOrEqual(15);
  });

  test("calls onResult callback for each test", async () => {
    const runner = createTestRunner();
    const reported: TestRunnerResult[] = [];
    runner.describe("Suite", () => {
      runner.it("a", () => {});
      runner.it("b", () => {});
    });
    await runner.run((result) => { reported.push(result); });
    expect(reported).toHaveLength(2);
  });
});
