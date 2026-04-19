import { describe, it, expect } from "vitest";
import { matcherRegistry, applyMatcher } from "../src/assertions/matchers.js";

describe("matcherRegistry", () => {
  it("has built-in matchers registered", () => {
    expect(matcherRegistry.has("exist")).toBe(true);
    expect(matcherRegistry.has("be.visible")).toBe(true);
    expect(matcherRegistry.has("have.text")).toBe(true);
    expect(matcherRegistry.has("have.length")).toBe(true);
    expect(matcherRegistry.has("equal")).toBe(true);
  });

  it("allows registering custom matchers", () => {
    matcherRegistry.set("custom.test", () => ({
      passed: true,
      actual: null,
      expected: null,
    }));
    expect(matcherRegistry.has("custom.test")).toBe(true);
    matcherRegistry.delete("custom.test");
  });
});

describe("applyMatcher", () => {
  it("exist - passes when element is truthy", () => {
    const el = document.createElement("div");
    const result = applyMatcher("exist", el);
    expect(result.passed).toBe(true);
  });

  it("exist - fails when element is null", () => {
    const result = applyMatcher("exist", null);
    expect(result.passed).toBe(false);
  });

  it("have.text - passes on exact textContent match", () => {
    const el = document.createElement("div");
    el.textContent = "Hello";
    const result = applyMatcher("have.text", el, "Hello");
    expect(result.passed).toBe(true);
    expect(result.actual).toBe("Hello");
  });

  it("have.text - fails on mismatch", () => {
    const el = document.createElement("div");
    el.textContent = "World";
    const result = applyMatcher("have.text", el, "Hello");
    expect(result.passed).toBe(false);
    expect(result.actual).toBe("World");
    expect(result.expected).toBe("Hello");
  });

  it("contain.text - passes when textContent includes arg", () => {
    const el = document.createElement("div");
    el.textContent = "Hello World";
    const result = applyMatcher("contain.text", el, "World");
    expect(result.passed).toBe(true);
  });

  it("have.class - passes when element has class", () => {
    const el = document.createElement("div");
    el.classList.add("active");
    const result = applyMatcher("have.class", el, "active");
    expect(result.passed).toBe(true);
  });

  it("have.class - fails when element lacks class", () => {
    const el = document.createElement("div");
    const result = applyMatcher("have.class", el, "active");
    expect(result.passed).toBe(false);
  });

  it("have.attr - passes when attribute matches", () => {
    const el = document.createElement("input");
    el.setAttribute("type", "text");
    const result = applyMatcher("have.attr", el, "type", "text");
    expect(result.passed).toBe(true);
  });

  it("have.length - passes when array length matches", () => {
    const items = [1, 2, 3];
    const result = applyMatcher("have.length", items, 3);
    expect(result.passed).toBe(true);
  });

  it("have.length - fails on mismatch", () => {
    const items = [1, 2];
    const result = applyMatcher("have.length", items, 3);
    expect(result.passed).toBe(false);
    expect(result.actual).toBe(2);
  });

  it("equal - deep equality", () => {
    const result = applyMatcher("equal", { a: 1 }, { a: 1 });
    expect(result.passed).toBe(true);
  });

  it("have.value - checks input value", () => {
    const el = document.createElement("input");
    el.value = "test";
    const result = applyMatcher("have.value", el, "test");
    expect(result.passed).toBe(true);
  });

  it("be.disabled - passes when element is disabled", () => {
    const el = document.createElement("button");
    el.disabled = true;
    const result = applyMatcher("be.disabled", el);
    expect(result.passed).toBe(true);
  });

  it("be.checked - passes when checkbox is checked", () => {
    const el = document.createElement("input");
    el.type = "checkbox";
    el.checked = true;
    const result = applyMatcher("be.checked", el);
    expect(result.passed).toBe(true);
  });

  it("include - passes when value is included", () => {
    const result = applyMatcher("include", [1, 2, 3], 2);
    expect(result.passed).toBe(true);
  });

  it("have.property - passes when object has property", () => {
    const result = applyMatcher("have.property", { name: "test" }, "name");
    expect(result.passed).toBe(true);
  });

  it("have.property - checks value when provided", () => {
    const result = applyMatcher("have.property", { name: "test" }, "name", "test");
    expect(result.passed).toBe(true);
  });
});

describe("negation", () => {
  it("not.exist - passes when element is null", () => {
    const result = applyMatcher("not.exist", null);
    expect(result.passed).toBe(true);
  });

  it("not.have.class - passes when element lacks class", () => {
    const el = document.createElement("div");
    const result = applyMatcher("not.have.class", el, "active");
    expect(result.passed).toBe(true);
  });

  it("not.have.class - fails when element has class", () => {
    const el = document.createElement("div");
    el.classList.add("active");
    const result = applyMatcher("not.have.class", el, "active");
    expect(result.passed).toBe(false);
  });
});
