import type { QueuedCommand, AssertionResult, CyConfig } from "./types.js";
import { retry } from "./retry.js";

const DEFAULT_CONFIG: CyConfig = {
  defaultCommandTimeout: 4000,
  execTimeout: 60000,
};

let globalConfig: CyConfig = { ...DEFAULT_CONFIG };

export function getConfig(): CyConfig {
  return globalConfig;
}

export function setConfig(overrides: Partial<CyConfig>): void {
  Object.assign(globalConfig, overrides);
}

export function resetConfig(): void {
  globalConfig = { ...DEFAULT_CONFIG };
}

export interface ChainInstance {
  enqueue(cmd: QueuedCommand): void;
  execute(): Promise<unknown>;
  getAssertions(): AssertionResult[];
}

/**
 * Creates a new command chain. Commands are enqueued and later
 * executed sequentially via execute().
 */
export function createChainable(): ChainInstance {
  const queue: QueuedCommand[] = [];
  const assertions: AssertionResult[] = [];

  return {
    enqueue(cmd: QueuedCommand): void {
      queue.push(cmd);
    },

    async execute(): Promise<unknown> {
      let subject: unknown = undefined;
      let lastQueryIndex = -1;

      for (let i = 0; i < queue.length; i++) {
        const cmd = queue[i];

        if (cmd.type === "query") {
          lastQueryIndex = i;
          subject = await cmd.fn(subject);
        } else if (cmd.type === "action") {
          subject = await cmd.fn(subject);
        } else if (cmd.type === "assertion") {
          const timeout = cmd.timeout ?? globalConfig.defaultCommandTimeout;
          const queryIdx = lastQueryIndex;

          if (queryIdx >= 0) {
            const queryCmd = queue[queryIdx];
            const intermediateCommands = queue.slice(queryIdx + 1, i);

            subject = await retry(
              async () => {
                let s: unknown = await queryCmd.fn(undefined);
                for (const mid of intermediateCommands) {
                  if (mid.type === "query") {
                    s = await mid.fn(s);
                  }
                }
                s = await cmd.fn(s);
                return s;
              },
              { timeout, interval: 50 }
            );
          } else {
            subject = await cmd.fn(subject);
          }

          assertions.push({
            description: cmd.name,
            passed: true,
            expected: undefined,
            actual: subject,
          });
        }
      }

      return subject;
    },

    getAssertions(): AssertionResult[] {
      return assertions;
    },
  };
}
