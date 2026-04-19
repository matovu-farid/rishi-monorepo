export function domGet(selector: string): Element[] {
  return Array.from(document.querySelectorAll(selector));
}

export function domContains(text: string): Element | null {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
  let node = walker.nextNode();
  while (node) {
    const el = node as Element;
    if (el.textContent?.trim() === text.trim()) {
      return el;
    }
    node = walker.nextNode();
  }
  return null;
}

export function domFind(parent: Element, selector: string): Element[] {
  return Array.from(parent.querySelectorAll(selector));
}

export function domFirst(elements: Element[]): Element {
  if (elements.length === 0) throw new Error("cy.first() requires at least one element");
  return elements[0];
}

export function domLast(elements: Element[]): Element {
  if (elements.length === 0) throw new Error("cy.last() requires at least one element");
  return elements[elements.length - 1];
}

export function domEq(elements: Element[], index: number): Element {
  if (index < 0 || index >= elements.length) {
    throw new Error(`cy.eq(${index}): index out of bounds (${elements.length} elements)`);
  }
  return elements[index];
}

export function domClick(el: Element): Element {
  el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  return el;
}

export function domType(el: Element, text: string): Element {
  const input = el as HTMLInputElement;
  input.value = text;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

export function domClear(el: Element): Element {
  const input = el as HTMLInputElement;
  input.value = "";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

export function domCheck(el: Element): Element {
  const input = el as HTMLInputElement;
  input.checked = !input.checked;
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

export function domSelect(el: Element, value: string): Element {
  const select = el as HTMLSelectElement;
  select.value = value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}
