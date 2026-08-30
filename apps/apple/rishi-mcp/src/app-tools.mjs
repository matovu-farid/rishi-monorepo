import { ErrorCodes, RegistryError } from "./instance-registry.mjs";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function inviteFromState(result) {
  const visible = result.accessibility?.tree ?? "";
  const candidate = visible.match(/https?:\/\/[^\s'"<>]+/i)?.[0]?.replace(/[),.;]+$/, "") ?? null;
  try { return candidate ? new URL(candidate).toString() : null; } catch { return null; }
}

export function createToolHandlers({ driver, registry, memory }) {
  const state = (app, screenshot = false) => driver.state(app, screenshot).catch((error) => { throw new RegistryError(error.code ?? ErrorCodes.STATE_CHANGED, error.message); });
  return {
    list_app_instances: () => registry.list(),
    start_app: ({ app }) => registry.start(app),
    stop_app: ({ app }) => registry.stop(app),
    restart_app: ({ app }) => registry.restart(app),
    inspect_app_state: async ({ app, identifier, screenshot = false }) => {
      const result = await state(app, screenshot);
      if (identifier && !(result.accessibility?.tree ?? "").includes(identifier)) throw new RegistryError(ErrorCodes.ACTION_NOT_SUPPORTED, `semantic identifier not found: ${identifier}`);
      return { app, state: result.accessibility ?? null, screenshots: result.screenshots ?? [] };
    },
    capture_screenshot: async ({ app }) => {
      const result = await state(app, true);
      return { app, screenshots: result.screenshots ?? [] };
    },
    select_book: async ({ app, identifier, action }) => driver.clickIdentifier(app, identifier, action === "select_to_share" ? "context_menu" : "open"),
    create_reading_session: async ({ app, bookIdentifier }) => {
      await driver.clickIdentifier(app, bookIdentifier, "context_menu");
      await driver.clickText(app, "Select to Share");
      await driver.clickText(app, "Start reading");
      await driver.clickText(app, "Create reading link");
      const deadline = Date.now() + 30000;
      let result = await state(app);
      let invite = inviteFromState(result);
      while (!invite && Date.now() < deadline) {
        await sleep(250);
        result = await state(app);
        invite = inviteFromState(result);
      }
      if (!invite) throw new RegistryError(ErrorCodes.WAIT_TIMEOUT, "reading link did not become visible", { app, bookIdentifier });
      return { app, bookIdentifier, invite, state: result.accessibility ?? null };
    },
    join_reading_session: async ({ app, token }) => {
      const url = new URL("rishi://sharing/session");
      url.searchParams.set("token", token);
      await driver.openURL(app, url.toString());
      return { app, submitted: true };
    },
    wait_for_participant: async ({ app, text, timeoutMs = 30000 }) => {
      const started = Date.now();
      while (Date.now() - started < timeoutMs) {
        const result = await state(app);
        if ((result.accessibility?.tree ?? "").toLowerCase().includes(text.toLowerCase())) return { app, matched: true, elapsedMs: Date.now() - started, state: result.accessibility ?? null };
        await sleep(250);
      }
      throw new RegistryError(ErrorCodes.WAIT_TIMEOUT, `text not visible before timeout: ${text}`, { app, timeoutMs, memory: await memory(app) });
    },
    send_reader_action: async ({ app, action }) => {
      const labels = { next_page: "Next page", previous_page: "Previous page", pause: "Pause", resume: "Play", close: "Close" };
      return driver.clickText(app, labels[action]);
    },
    memory_snapshot: ({ app = "" }) => memory(app),
  };
}
