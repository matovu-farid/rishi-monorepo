export function navVisit(path: string): void {
  window.location.href = path;
}

export function navReload(): void {
  window.location.reload();
}

export function navUrl(): string {
  return window.location.href;
}

export function navHash(): string {
  return window.location.hash;
}

export function navGo(direction: "back" | "forward"): void {
  if (direction === "back") {
    window.history.back();
  } else {
    window.history.forward();
  }
}
