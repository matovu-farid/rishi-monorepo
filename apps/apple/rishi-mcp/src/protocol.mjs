export const SERVER_INFO = { name: "rishi-apple-mcp", version: "0.1.0" };

const app = {
  type: "object",
  properties: { app: { type: "string", enum: ["catalyst", "iphone17"] } },
  required: ["app"],
  additionalProperties: false,
};

export const TOOLS = [
  { name: "list_app_instances", description: "List running Rishi Apple app instances.", inputSchema: { type: "object", properties: {}, additionalProperties: false } },
  { name: "start_app", description: "Launch one explicit Apple app target; refuses duplicate targets.", inputSchema: app },
  { name: "stop_app", description: "Stop a server-owned Apple app instance.", inputSchema: app },
  { name: "restart_app", description: "Stop and relaunch one target after explicit confirmation.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, confirm: { type: "boolean", const: true } }, required: ["app", "confirm"], additionalProperties: false } },
  { name: "inspect_app_state", description: "Inspect semantic accessibility state without launching the app.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, identifier: { type: "string" }, screenshot: { type: "boolean" } }, required: ["app"], additionalProperties: false } },
  { name: "capture_screenshot", description: "Capture the current app window for test evidence.", inputSchema: app },
  { name: "select_book", description: "Perform a semantic action on a library book. Use select_to_share for the context-menu flow.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, identifier: { type: "string", minLength: 1 }, action: { type: "string", enum: ["open", "select_to_share"] } }, required: ["app", "identifier", "action"], additionalProperties: false } },
  { name: "create_reading_session", description: "Drive the visible shared-reading composer for a selected book.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, bookIdentifier: { type: "string", minLength: 1 } }, required: ["app", "bookIdentifier"], additionalProperties: false } },
  { name: "join_reading_session", description: "Open the app's supported shared-reading session deep link with an explicitly supplied invite token.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, token: { type: "string", minLength: 1 } }, required: ["app", "token"], additionalProperties: false } },
  { name: "wait_for_participant", description: "Poll visible app state for a participant or session condition.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, text: { type: "string", minLength: 1 }, timeoutMs: { type: "integer", minimum: 100, maximum: 120000 } }, required: ["app", "text"], additionalProperties: false } },
  { name: "send_reader_action", description: "Send a bounded semantic reader action.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["catalyst", "iphone17"] }, action: { type: "string", enum: ["next_page", "previous_page", "pause", "resume", "close"] } }, required: ["app", "action"], additionalProperties: false } },
  { name: "memory_snapshot", description: "Report host and matching target process memory.", inputSchema: { type: "object", properties: { app: { type: "string", enum: ["", "catalyst", "iphone17"] } }, additionalProperties: false } },
];

export function jsonRpcError(id, code, message, data = undefined) {
  return { jsonrpc: "2.0", id, error: { code, message, ...(data === undefined ? {} : { data }) } };
}

export function textResult(value) {
  return { content: [{ type: "text", text: JSON.stringify(value) }], structuredContent: value };
}

export function validateArgs(tool, args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("arguments must be an object");
  for (const required of tool.inputSchema.required ?? []) {
    if (!(required in args)) throw new Error(`missing required argument: ${required}`);
  }
  for (const [key, value] of Object.entries(args)) {
    const schema = tool.inputSchema.properties?.[key];
    if (!schema) throw new Error(`unknown argument: ${key}`);
    if (schema.type === "string" && (typeof value !== "string" || value.length < (schema.minLength ?? 0))) throw new Error(`invalid argument: ${key}`);
    if (schema.type === "boolean" && typeof value !== "boolean") throw new Error(`invalid argument: ${key}`);
    if (schema.type === "integer" && (!Number.isInteger(value) || value < schema.minimum || value > schema.maximum)) throw new Error(`invalid argument: ${key}`);
    if (schema.const !== undefined && value !== schema.const) throw new Error(`invalid argument: ${key}`);
    if (schema.enum && !schema.enum.includes(value)) throw new Error(`invalid argument: ${key}`);
  }
}
