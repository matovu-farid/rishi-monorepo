import type { MatcherFn } from "../types.js";

export const matcherRegistry = new Map<string, MatcherFn>();

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a == null || b == null) return false;
  if (typeof a !== typeof b) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((val, i) => deepEqual(val, b[i]));
  }
  if (typeof a === "object" && typeof b === "object") {
    const aObj = a as Record<string, unknown>;
    const bObj = b as Record<string, unknown>;
    const aKeys = Object.keys(aObj);
    const bKeys = Object.keys(bObj);
    if (aKeys.length !== bKeys.length) return false;
    return aKeys.every((key) => deepEqual(aObj[key], bObj[key]));
  }
  return false;
}

matcherRegistry.set("exist", (subject) => ({
  passed: subject != null,
  actual: subject,
  expected: "to exist",
}));

matcherRegistry.set("be.visible", (subject) => {
  const el = subject as HTMLElement;
  if (!el || !el.getClientRects) {
    return { passed: false, actual: null, expected: "to be visible" };
  }
  const style = window.getComputedStyle(el);
  const visible =
    style.display !== "none" &&
    style.visibility !== "hidden" &&
    el.getClientRects().length > 0;
  return {
    passed: visible,
    actual: visible ? "visible" : "hidden",
    expected: "visible",
  };
});

matcherRegistry.set("be.hidden", (subject) => {
  const visibleResult = matcherRegistry.get("be.visible")!(subject);
  return {
    passed: !visibleResult.passed,
    actual: visibleResult.actual,
    expected: "hidden",
  };
});

matcherRegistry.set("be.disabled", (subject) => {
  const el = subject as HTMLButtonElement;
  return { passed: el?.disabled === true, actual: el?.disabled, expected: true };
});

matcherRegistry.set("be.enabled", (subject) => {
  const el = subject as HTMLButtonElement;
  return {
    passed: el?.disabled === false,
    actual: !el?.disabled,
    expected: true,
  };
});

matcherRegistry.set("be.checked", (subject) => {
  const el = subject as HTMLInputElement;
  return { passed: el?.checked === true, actual: el?.checked, expected: true };
});

matcherRegistry.set("have.text", (subject, expected) => {
  const el = subject as HTMLElement;
  const actual = el?.textContent ?? "";
  return { passed: actual === expected, actual, expected };
});

matcherRegistry.set("contain.text", (subject, expected) => {
  const el = subject as HTMLElement;
  const actual = el?.textContent ?? "";
  return {
    passed: actual.includes(expected as string),
    actual,
    expected,
  };
});

matcherRegistry.set("have.value", (subject, expected) => {
  const el = subject as HTMLInputElement;
  const actual = el?.value;
  return { passed: actual === expected, actual, expected };
});

matcherRegistry.set("have.class", (subject, className) => {
  const el = subject as HTMLElement;
  const has = el?.classList?.contains(className as string) ?? false;
  return { passed: has, actual: el?.className, expected: className };
});

matcherRegistry.set("have.attr", (subject, attrName, attrValue) => {
  const el = subject as HTMLElement;
  const actual = el?.getAttribute(attrName as string);
  if (attrValue === undefined) {
    return {
      passed: actual !== null,
      actual,
      expected: `attribute ${attrName}`,
    };
  }
  return { passed: actual === attrValue, actual, expected: attrValue };
});

matcherRegistry.set("have.css", (subject, prop, value) => {
  const el = subject as HTMLElement;
  const actual = window.getComputedStyle(el).getPropertyValue(prop as string);
  return { passed: actual === value, actual, expected: value };
});

matcherRegistry.set("have.length", (subject, expected) => {
  const arr = subject as unknown[];
  const actual = arr?.length ?? 0;
  return { passed: actual === expected, actual, expected };
});

matcherRegistry.set("include", (subject, value) => {
  if (Array.isArray(subject)) {
    const found = subject.some((item) => deepEqual(item, value));
    return { passed: found, actual: subject, expected: value };
  }
  if (typeof subject === "string") {
    const found = subject.includes(value as string);
    return { passed: found, actual: subject, expected: value };
  }
  return { passed: false, actual: subject, expected: value };
});

matcherRegistry.set("equal", (subject, expected) => ({
  passed: deepEqual(subject, expected),
  actual: subject,
  expected,
}));

matcherRegistry.set("have.property", (subject, prop, value) => {
  const obj = subject as Record<string, unknown>;
  const has = obj != null && (prop as string) in obj;
  if (!has) {
    return { passed: false, actual: undefined, expected: prop };
  }
  if (value === undefined) {
    return { passed: true, actual: obj[prop as string], expected: prop };
  }
  const actual = obj[prop as string];
  return { passed: deepEqual(actual, value), actual, expected: value };
});

export function applyMatcher(
  matcherStr: string,
  subject: unknown,
  ...args: unknown[]
): { passed: boolean; actual: unknown; expected: unknown } {
  const negated = matcherStr.startsWith("not.");
  const key = negated ? matcherStr.slice(4) : matcherStr;
  const matcher = matcherRegistry.get(key);
  if (!matcher) {
    throw new Error(`tauri-cypress: unknown matcher "${key}"`);
  }
  const result = matcher(subject, ...args);
  if (negated) {
    return { ...result, passed: !result.passed };
  }
  return result;
}
