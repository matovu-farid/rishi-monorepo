import test from "node:test";
import assert from "node:assert/strict";
import { createToolHandlers, bookReadinessIdentifier } from "../src/app-tools.mjs";

test("book readiness ignores the optional accessibility index", () => {
  assert.equal(bookReadinessIdentifier("library-book-cell#0"), "library-book-cell");
  assert.equal(bookReadinessIdentifier("library-book-cell"), "library-book-cell");
});

test("select_book uses semantic context action for share selection", async () => {
  const calls = [];
  const driver = { clickIdentifier: async (...args) => calls.push(args) };
  const handlers = createToolHandlers({ driver, registry: {}, memory: async () => ({}) });
  await handlers.select_book({ app: "catalyst", identifier: "library-book-cell", action: "select_to_share" });
  assert.deepEqual(calls, [["catalyst", "library-book-cell", "context_menu"]]);
});

test("reader actions map to visible labels", async () => {
  const calls = [];
  const driver = { clickText: async (...args) => calls.push(args) };
  const handlers = createToolHandlers({ driver, registry: {}, memory: async () => ({}) });
  await handlers.send_reader_action({ app: "catalyst", action: "next_page" });
  assert.deepEqual(calls, [["catalyst", "Next page"]]);
});

test("read_app_logs delegates to the target driver with a bounded limit", async () => {
  const calls = [];
  const driver = { logs: async (...args) => { calls.push(args); return { entries: [] }; } };
  const handlers = createToolHandlers({ driver, registry: {}, memory: async () => ({}) });
  await handlers.read_app_logs({ app: "iphone17", limit: 25 });
  assert.deepEqual(calls, [["iphone17", 25]]);
});

test("creating a reading session follows the selection and composer UI", async () => {
  const calls = [];
  const driver = {
    clickIdentifier: async (...args) => calls.push(["identifier", ...args]),
    clickText: async (...args) => calls.push(["text", ...args]),
    state: async () => ({ accessibility: { tree: "library-book-cell https://rishi.fidexa.org/sharing/session?token=abc" } }),
  };
  const handlers = createToolHandlers({ driver, registry: {}, memory: async () => ({}) });
  await handlers.create_reading_session({ app: "catalyst", bookIdentifier: "library-book-cell#0" });
  assert.deepEqual(calls, [
    ["identifier", "catalyst", "library-book-cell#0", "context_menu"],
    ["text", "catalyst", "Select to Share"],
    ["text", "catalyst", "Start reading"],
    ["text", "catalyst", "Create reading link"],
  ]);
});

test("joining a reading session opens the app's supported session deep link", async () => {
  const calls = [];
  const driver = { openURL: async (...args) => calls.push(args) };
  const handlers = createToolHandlers({ driver, registry: {}, memory: async () => ({}) });
  await handlers.join_reading_session({ app: "iphone17", token: "invite token/+" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "iphone17");
  assert.equal(calls[0][1], "rishi://sharing/session?token=invite+token%2F%2B");
});
