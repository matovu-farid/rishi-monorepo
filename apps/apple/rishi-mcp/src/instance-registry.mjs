import { memorySnapshot } from "./memory.mjs";

export const ErrorCodes = {
  INSTANCE_NOT_FOUND: "INSTANCE_NOT_FOUND",
  INSTANCE_ALREADY_RUNNING: "INSTANCE_ALREADY_RUNNING",
  DRIVER_UNAVAILABLE: "DRIVER_UNAVAILABLE",
  ACTION_NOT_SUPPORTED: "ACTION_NOT_SUPPORTED",
  STATE_CHANGED: "STATE_CHANGED",
  WAIT_TIMEOUT: "WAIT_TIMEOUT",
};

export class RegistryError extends Error {
  constructor(code, message, data = {}) { super(message); this.code = code; this.data = data; }
}

export class InstanceRegistry {
  #driver;
  #memory;
  #instances = new Map();
  #starting = new Set();
  constructor(driver, memory = memorySnapshot) { this.#driver = driver; this.#memory = memory; }

  async list() {
    const apps = await this.#driver.listApps();
    return Promise.all(apps.filter((app) => /rishi/i.test(`${app.id} ${app.displayName ?? ""}`) && app.isRunning !== false && app.windows?.length).map(async (app) => ({ ...app, owned: [...this.#instances.values()].some((i) => i.app === app.id), memory: await this.#memory(app.id) })));
  }

  async start(app) {
    if (this.#instances.has(app) || this.#starting.has(app)) throw new RegistryError(ErrorCodes.INSTANCE_ALREADY_RUNNING, `target already owned: ${app}`, { app });
    this.#starting.add(app);
    try {
      const existing = (await this.#driver.listApps()).find((candidate) => candidate.id === app && candidate.isRunning !== false && candidate.windows?.length);
      if (existing) throw new RegistryError(ErrorCodes.INSTANCE_ALREADY_RUNNING, `target already running: ${app}`, { app, existing });
      await this.#driver.launch(app);
      const instance = { id: `${app}:${Date.now()}`, app, owned: true };
      this.#instances.set(app, instance);
      return { ...instance, memory: await this.#memory(app) };
    } finally {
      this.#starting.delete(app);
    }
  }

  async stop(app) {
    const instance = this.#instances.get(app);
    if (!instance) return { app, stopped: false, reason: "not_owned" };
    await this.#driver.terminate(app);
    this.#instances.delete(app);
    return { ...instance, stopped: true, memory: await this.#memory(app) };
  }

  async restart(app) {
    const owned = this.#instances.has(app);
    if (owned) await this.stop(app);
    else {
      const existing = (await this.#driver.listApps()).find((candidate) => candidate.id === app && candidate.isRunning !== false && candidate.windows?.length);
      if (existing) throw new RegistryError(ErrorCodes.INSTANCE_ALREADY_RUNNING, `refusing to restart unowned target: ${app}`, { app });
    }
    return this.start(app);
  }

  async cleanup() { for (const app of [...this.#instances.keys()]) await this.stop(app); }
}
