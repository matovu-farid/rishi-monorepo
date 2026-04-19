export interface TestRunnerResult {
  testId: string;
  status: "passed" | "failed" | "skipped";
  assertions: { description: string; passed: boolean; expected: unknown; actual: unknown }[];
  error: string | null;
  durationMs: number;
}

interface TestCase {
  name: string;
  fn: () => void | Promise<void>;
}

interface DescribeBlock {
  name: string;
  tests: TestCase[];
  beforeEachFns: (() => void | Promise<void>)[];
  afterEachFns: (() => void | Promise<void>)[];
  children: DescribeBlock[];
}

export function createTestRunner() {
  const rootBlocks: DescribeBlock[] = [];
  const blockStack: DescribeBlock[] = [];

  function currentBlock(): DescribeBlock | null {
    return blockStack.length > 0 ? blockStack[blockStack.length - 1] : null;
  }

  function describe(name: string, fn: () => void): void {
    const block: DescribeBlock = {
      name,
      tests: [],
      beforeEachFns: [],
      afterEachFns: [],
      children: [],
    };
    const parent = currentBlock();
    if (parent) {
      parent.children.push(block);
    } else {
      rootBlocks.push(block);
    }
    blockStack.push(block);
    fn();
    blockStack.pop();
  }

  function it(name: string, fn: () => void | Promise<void>): void {
    const block = currentBlock();
    if (!block) throw new Error("it() must be called inside describe()");
    block.tests.push({ name, fn });
  }

  function beforeEach(fn: () => void | Promise<void>): void {
    const block = currentBlock();
    if (!block) throw new Error("beforeEach() must be called inside describe()");
    block.beforeEachFns.push(fn);
  }

  function afterEach(fn: () => void | Promise<void>): void {
    const block = currentBlock();
    if (!block) throw new Error("afterEach() must be called inside describe()");
    block.afterEachFns.push(fn);
  }

  async function runBlock(
    block: DescribeBlock,
    parentPath: string,
    parentBeforeEach: (() => void | Promise<void>)[],
    parentAfterEach: (() => void | Promise<void>)[],
    onResult?: (result: TestRunnerResult) => void
  ): Promise<TestRunnerResult[]> {
    const results: TestRunnerResult[] = [];
    const path = parentPath ? `${parentPath} > ${block.name}` : block.name;
    const allBeforeEach = [...parentBeforeEach, ...block.beforeEachFns];
    const allAfterEach = [...block.afterEachFns, ...parentAfterEach];

    for (const test of block.tests) {
      const testId = `${path} > ${test.name}`;
      const startTime = Date.now();
      let result: TestRunnerResult;

      try {
        for (const hook of allBeforeEach) {
          await hook();
        }
        await test.fn();
        result = {
          testId,
          status: "passed",
          assertions: [],
          error: null,
          durationMs: Date.now() - startTime,
        };
      } catch (err) {
        result = {
          testId,
          status: "failed",
          assertions: [],
          error: err instanceof Error ? err.message : String(err),
          durationMs: Date.now() - startTime,
        };
      } finally {
        for (const hook of allAfterEach) {
          try { await hook(); } catch { /* afterEach errors don't change test status */ }
        }
      }

      results.push(result!);
      onResult?.(result!);
    }

    for (const child of block.children) {
      const childResults = await runBlock(child, path, allBeforeEach, allAfterEach, onResult);
      results.push(...childResults);
    }

    return results;
  }

  async function run(onResult?: (result: TestRunnerResult) => void): Promise<TestRunnerResult[]> {
    const allResults: TestRunnerResult[] = [];
    for (const block of rootBlocks) {
      const results = await runBlock(block, "", [], [], onResult);
      allResults.push(...results);
    }
    return allResults;
  }

  return { describe, it, beforeEach, afterEach, run };
}
