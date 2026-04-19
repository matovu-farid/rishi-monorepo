import { describe, it, expect, beforeEach } from "vitest";
import {
  domGet, domContains, domFind, domFirst, domLast, domEq,
  domClick, domType, domClear, domCheck, domSelect,
} from "../../src/commands/dom.js";

describe("DOM query commands", () => {
  beforeEach(() => {
    document.body.textContent = "";
  });

  it("domGet finds elements by selector", () => {
    const d1 = document.createElement("div");
    d1.className = "item";
    d1.textContent = "A";
    const d2 = document.createElement("div");
    d2.className = "item";
    d2.textContent = "B";
    document.body.appendChild(d1);
    document.body.appendChild(d2);
    const result = domGet(".item") as Element[];
    expect(result).toHaveLength(2);
  });

  it("domGet returns empty array when nothing matches", () => {
    const result = domGet(".missing") as Element[];
    expect(result).toHaveLength(0);
  });

  it("domContains finds element by text content", () => {
    const p1 = document.createElement("p");
    p1.textContent = "Hello World";
    const p2 = document.createElement("p");
    p2.textContent = "Other";
    document.body.appendChild(p1);
    document.body.appendChild(p2);
    const result = domContains("Hello World") as Element;
    expect(result).toBeTruthy();
    expect(result.textContent).toBe("Hello World");
  });

  it("domFind scopes query to parent element", () => {
    const divA = document.createElement("div");
    divA.id = "a";
    const spanA = document.createElement("span");
    spanA.className = "x";
    spanA.textContent = "1";
    divA.appendChild(spanA);
    const divB = document.createElement("div");
    divB.id = "b";
    const spanB = document.createElement("span");
    spanB.className = "x";
    spanB.textContent = "2";
    divB.appendChild(spanB);
    document.body.appendChild(divA);
    document.body.appendChild(divB);
    const result = domFind(divA, ".x") as Element[];
    expect(result).toHaveLength(1);
    expect(result[0].textContent).toBe("1");
  });

  it("domFirst returns first element from array", () => {
    const els = [document.createElement("div"), document.createElement("span")];
    els[0].textContent = "first";
    const result = domFirst(els) as Element;
    expect(result.textContent).toBe("first");
  });

  it("domLast returns last element from array", () => {
    const els = [document.createElement("div"), document.createElement("span")];
    els[1].textContent = "last";
    const result = domLast(els) as Element;
    expect(result.textContent).toBe("last");
  });

  it("domEq returns element at index", () => {
    const els = [document.createElement("div"), document.createElement("span"), document.createElement("p")];
    els[1].textContent = "middle";
    const result = domEq(els, 1) as Element;
    expect(result.textContent).toBe("middle");
  });
});

describe("DOM action commands", () => {
  it("domClick dispatches click event", () => {
    const el = document.createElement("button");
    let clicked = false;
    el.addEventListener("click", () => { clicked = true; });
    document.body.appendChild(el);
    domClick(el);
    expect(clicked).toBe(true);
  });

  it("domType sets value and dispatches input event", () => {
    const el = document.createElement("input");
    document.body.appendChild(el);
    let inputFired = false;
    el.addEventListener("input", () => { inputFired = true; });
    domType(el, "hello");
    expect(el.value).toBe("hello");
    expect(inputFired).toBe(true);
  });

  it("domClear empties input value", () => {
    const el = document.createElement("input");
    el.value = "some text";
    document.body.appendChild(el);
    domClear(el);
    expect(el.value).toBe("");
  });

  it("domCheck toggles checkbox", () => {
    const el = document.createElement("input");
    el.type = "checkbox";
    el.checked = false;
    document.body.appendChild(el);
    domCheck(el);
    expect(el.checked).toBe(true);
  });

  it("domSelect sets select value", () => {
    const el = document.createElement("select");
    const opt = document.createElement("option");
    opt.value = "b";
    opt.textContent = "B";
    el.appendChild(opt);
    document.body.appendChild(el);
    domSelect(el, "b");
    expect(el.value).toBe("b");
  });
});
