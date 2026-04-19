// apps/main/src/machines/playerMachine.test.ts
import { describe, it, expect } from "vitest";
import { createActor } from "xstate";
import { playerMachine } from "./playerMachine";

const fakeParagraphs = [
  { index: "1", text: "Hello world." },
  { index: "2", text: "Second paragraph." },
];

describe("playerMachine", () => {
  it("starts in idle state", () => {
    const actor = createActor(playerMachine);
    actor.start();
    expect(actor.getSnapshot().value).toBe("idle");
    actor.stop();
  });

  it("idle → INITIALIZE → stopped", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    expect(actor.getSnapshot().value).toBe("stopped");
    expect(actor.getSnapshot().context.bookId).toBe("1");
    actor.stop();
  });

  it("stopped → PLAY with paragraphs → loading", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    expect(actor.getSnapshot().value).toBe("loading");
    actor.stop();
  });

  it("stopped → PLAY without paragraphs → waitingForParagraphs", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PLAY" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    actor.stop();
  });

  it("loading → AUDIO_LOADED → playing", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    expect(actor.getSnapshot().value).toBe("playing");
    actor.stop();
  });

  it("playing → PAUSE → paused.clean", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PAUSE" });
    expect(actor.getSnapshot().value).toEqual({ paused: "clean" });
    actor.stop();
  });

  it("paused.clean → RESUME → playing", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PAUSE" });
    actor.send({ type: "RESUME" });
    expect(actor.getSnapshot().value).toBe("playing");
    actor.stop();
  });

  it("paused.clean → PARAGRAPHS_UPDATED → paused.stale", () => {
    const newParagraphs = [{ index: "3", text: "New page." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PAUSE" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: newParagraphs });
    expect(actor.getSnapshot().value).toEqual({ paused: "stale" });
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    actor.stop();
  });

  it("paused.stale → RESUME → loading (fresh play from new page)", () => {
    const newParagraphs = [{ index: "3", text: "New page." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PAUSE" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: newParagraphs });
    actor.send({ type: "RESUME" });
    expect(actor.getSnapshot().value).toBe("loading");
    actor.stop();
  });

  it("playing → AUDIO_ENDED with more paragraphs → loading (advances index)", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    actor.send({ type: "AUDIO_ENDED" });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1);
    actor.stop();
  });

  it("playing → AUDIO_ENDED at last paragraph → waitingForParagraphs", () => {
    const single = [{ index: "1", text: "Only paragraph." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: single });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "AUDIO_ENDED" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    actor.stop();
  });

  it("waitingForParagraphs → PARAGRAPHS_UPDATED → loading", () => {
    const single = [{ index: "1", text: "Only." }];
    const nextPage = [{ index: "2", text: "Next page." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: single });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "AUDIO_ENDED" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: nextPage });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    actor.stop();
  });

  it("loading → AUDIO_ERROR increments retryCount", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_ERROR", error: "network" });
    expect(actor.getSnapshot().context.retryCount).toBe(1);
    expect(actor.getSnapshot().value).toBe("loading");
    actor.stop();
  });

  it("loading → 3 AUDIO_ERRORs → error state", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_ERROR", error: "fail1" });
    actor.send({ type: "AUDIO_ERROR", error: "fail2" });
    actor.send({ type: "AUDIO_ERROR", error: "fail3" });
    expect(actor.getSnapshot().value).toBe("error");
    actor.stop();
  });

  it("playing → STOP → stopped", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "STOP" });
    expect(actor.getSnapshot().value).toBe("stopped");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    actor.stop();
  });

  it("CLEANUP from any state → idle", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "CLEANUP" });
    expect(actor.getSnapshot().value).toBe("idle");
    expect(actor.getSnapshot().context.bookId).toBe("");
    actor.stop();
  });

  it("playing → NEXT → loading with advanced index", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "NEXT" });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1);
    expect(actor.getSnapshot().context.direction).toBe("forward");
    actor.stop();
  });

  it("playing → PREV → loading with retreated index", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "NEXT" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PREV" });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    expect(actor.getSnapshot().context.direction).toBe("backward");
    actor.stop();
  });

  it("playing → PARAGRAPHS_UPDATED → loading (page changed while playing)", () => {
    const newParagraphs = [{ index: "5", text: "Different page." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: newParagraphs });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    actor.stop();
  });

  it("playing → PREV at first paragraph → waitingForParagraphs (direction backward)", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    // Already at index 0 — pressing PREV should go to previous page
    actor.send({ type: "PREV" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    expect(actor.getSnapshot().context.direction).toBe("backward");
    actor.stop();
  });

  it("playing → NEXT at last paragraph → waitingForParagraphs (direction forward)", () => {
    const single = [{ index: "1", text: "Only paragraph." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: single });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "NEXT" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    expect(actor.getSnapshot().context.direction).toBe("forward");
    actor.stop();
  });

  // --- Regression tests: NEXT/PREV in paused state ---

  it("paused.clean → NEXT → loading", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PAUSE" });
    expect(actor.getSnapshot().value).toEqual({ paused: "clean" });
    actor.send({ type: "NEXT" });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1);
    actor.stop();
  });

  it("paused.clean → PREV at first paragraph → waitingForParagraphs", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_LOADED" });
    actor.send({ type: "PAUSE" });
    actor.send({ type: "PREV" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    expect(actor.getSnapshot().context.direction).toBe("backward");
    actor.stop();
  });

  // --- Regression tests: NEXT/PREV in stopped state ---

  it("stopped → NEXT → loading", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "NEXT" });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1);
    actor.stop();
  });

  it("stopped → PREV at first paragraph → waitingForParagraphs", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PREV" });
    expect(actor.getSnapshot().value).toBe("waitingForParagraphs");
    expect(actor.getSnapshot().context.direction).toBe("backward");
    actor.stop();
  });

  // --- Regression tests: PREV in error state ---

  it("error → PREV → loading", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    actor.send({ type: "AUDIO_ERROR", error: "fail1" });
    actor.send({ type: "AUDIO_ERROR", error: "fail2" });
    actor.send({ type: "AUDIO_ERROR", error: "fail3" });
    expect(actor.getSnapshot().value).toBe("error");
    // Advance to index 1 first
    actor.send({ type: "NEXT" });
    actor.send({ type: "AUDIO_ERROR", error: "fail4" });
    actor.send({ type: "AUDIO_ERROR", error: "fail5" });
    actor.send({ type: "AUDIO_ERROR", error: "fail6" });
    expect(actor.getSnapshot().value).toBe("error");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1);
    // Now PREV should go back to index 0
    actor.send({ type: "PREV" });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    expect(actor.getSnapshot().context.errors).toEqual([]);
    actor.stop();
  });

  // --- Regression test: PAUSE during loading ---

  it("loading → PAUSE → paused.clean", () => {
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    expect(actor.getSnapshot().value).toBe("loading");
    actor.send({ type: "PAUSE" });
    expect(actor.getSnapshot().value).toEqual({ paused: "clean" });
    actor.stop();
  });

  // --- Regression test: PARAGRAPHS_UPDATED during loading ---

  it("loading → PARAGRAPHS_UPDATED → loading (restarts with new paragraphs)", () => {
    const newParagraphs = [{ index: "5", text: "New page." }];
    const actor = createActor(playerMachine);
    actor.start();
    actor.send({ type: "INITIALIZE", bookId: "1" });
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: fakeParagraphs });
    actor.send({ type: "PLAY" });
    expect(actor.getSnapshot().value).toBe("loading");
    actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: newParagraphs });
    expect(actor.getSnapshot().value).toBe("loading");
    expect(actor.getSnapshot().context.currentParagraphs).toEqual(newParagraphs);
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0);
    actor.stop();
  });
});
