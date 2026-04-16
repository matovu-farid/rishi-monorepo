# Auto-Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the already-bootstrapped `tauri-plugin-updater` into a user-visible flow: silent update check on app startup, manual "Check for Updates" popover on the library page, native OS confirmation dialogs, automatic relaunch after install.

**Architecture:** Desktop-only feature. One core module (`updater.ts`) owns all state and IPC; a hook (`useStartupUpdateCheck`) triggers the silent path; a popover component (`UpdateMenu`) triggers the manual path and shows live status. Native OS dialogs (`ask`/`message` from `tauri-plugin-dialog`) are the only user-facing prompts. Relaunch uses a newly-added `tauri-plugin-process`.

**Tech Stack:** Tauri v2, React 19, Jotai (existing `customStore`), Radix UI Popover (existing), lucide-react, vitest + happy-dom (existing). Rust side: `tauri-plugin-process` v2 (new) alongside existing `tauri-plugin-updater` / `tauri-plugin-dialog`.

**Spec:** `docs/superpowers/specs/2026-04-16-auto-updater-design.md`

---

## File Structure

**New files:**
- `apps/main/src/modules/updater.ts` — core flow, status atom, pure helpers
- `apps/main/src/modules/updater.test.ts` — unit tests for pure helpers
- `apps/main/src/hooks/useStartupUpdateCheck.ts` — one-line hook
- `apps/main/src/components/UpdateMenu.tsx` — library-page settings popover

**Modified files:**
- `apps/main/src-tauri/Cargo.toml` — add `tauri-plugin-process = "2"`
- `apps/main/src-tauri/src/lib.rs` — register `tauri_plugin_process::init()`
- `apps/main/src-tauri/capabilities/desktop.json` — add `process:default`
- `apps/main/package.json` — add `@tauri-apps/plugin-process`
- `apps/main/src/routes/__root.tsx` — call `useStartupUpdateCheck()`
- `apps/main/src/routes/index.lazy.tsx` — render `<UpdateMenu />` top-right

---

## Task 1: Add `tauri-plugin-process` Rust dependency

**Files:**
- Modify: `apps/main/src-tauri/Cargo.toml` — lines 78–79 region

- [ ] **Step 1: Open the file and locate the existing desktop-only target section**

The section currently reads:
```toml
[target.'cfg(not(any(target_os = "android", target_os = "ios")))'.dependencies]
tauri-plugin-updater = "2"
```

- [ ] **Step 2: Add the process plugin under the same target gate**

Replace the block above with:

```toml
[target.'cfg(not(any(target_os = "android", target_os = "ios")))'.dependencies]
tauri-plugin-updater = "2"
tauri-plugin-process = "2"
```

- [ ] **Step 3: Verify Cargo picks up the new dep**

Run: `cd apps/main/src-tauri && cargo check`
Expected: compiles without errors; `Cargo.lock` now contains a `tauri-plugin-process` entry.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/Cargo.toml apps/main/src-tauri/Cargo.lock
git commit -m "feat(updater): add tauri-plugin-process dependency for relaunch"
```

---

## Task 2: Register `tauri-plugin-process` in the Tauri builder

**Files:**
- Modify: `apps/main/src-tauri/src/lib.rs:51–62` (plugin registration chain)

- [ ] **Step 1: Read the current registration chain**

Current form (lines 51–62):

```rust
tauri::Builder::default()
    .plugin(tauri_plugin_updater::Builder::new().build())
    .plugin(tauri_plugin_sentry::init(&client))
    .plugin(tauri_plugin_sql::Builder::new().build())
    .plugin(tauri_plugin_deep_link::init())
    .plugin(tauri_plugin_store::Builder::new().build())
    .plugin(tauri_plugin_http::init())
    .plugin(tauri_plugin_fs::init())
    .plugin(tauri_plugin_dialog::init())
    .plugin(tauri_plugin_opener::init())
    .plugin(tauri_plugin_os::init())
    .plugin(tauri_plugin_mic_recorder::init())
```

Note: `tauri_plugin_updater` is already registered unconditionally even though its crate dep is target-gated. The same pattern works for `tauri_plugin_process` (the crate is simply not in the dependency tree on mobile, so the code never compiles there — but we reach `lib.rs` on desktop builds only for these plugin chain lines when we're building desktop). Since mobile builds go through `mobile_entry_point` and this `run()` function is shared, we must add a matching `#[cfg]` gate around the `.plugin(tauri_plugin_process::init())` call.

Actually look at the existing `.plugin(tauri_plugin_updater::...)` — it is NOT cfg-gated despite being a target-gated crate. This works because Cargo's target-gated deps still get their `extern crate` generated on target; on mobile this line would fail to compile. That means **mobile builds are already broken if they go through this `run()`**. The existing code relies on mobile builds using a different entry path. To match the existing pattern exactly, register `tauri_plugin_process` the same way (no `cfg` gate at the call site).

- [ ] **Step 2: Insert the new plugin registration after `tauri_plugin_updater`**

Change lines 51–53 from:

```rust
tauri::Builder::default()
    .plugin(tauri_plugin_updater::Builder::new().build())
    .plugin(tauri_plugin_sentry::init(&client))
```

to:

```rust
tauri::Builder::default()
    .plugin(tauri_plugin_updater::Builder::new().build())
    .plugin(tauri_plugin_process::init())
    .plugin(tauri_plugin_sentry::init(&client))
```

- [ ] **Step 3: Verify it compiles**

Run: `cd apps/main/src-tauri && cargo check`
Expected: compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/lib.rs
git commit -m "feat(updater): register tauri-plugin-process in builder"
```

---

## Task 3: Add `process:default` capability permission

**Files:**
- Modify: `apps/main/src-tauri/capabilities/desktop.json`

- [ ] **Step 1: Read the current file**

It reads:

```json
{
  "identifier": "desktop-capability",
  "platforms": ["macOS", "windows", "linux"],
  "windows": ["main"],
  "permissions": ["updater:default"]
}
```

- [ ] **Step 2: Add `process:default` to the permissions array**

Replace the file contents with:

```json
{
  "identifier": "desktop-capability",
  "platforms": ["macOS", "windows", "linux"],
  "windows": ["main"],
  "permissions": ["updater:default", "process:default"]
}
```

- [ ] **Step 3: Verify the capability is valid**

Run: `cd apps/main && bun tauri info`
Expected: command runs without schema errors reported for `desktop.json`. (If `bun tauri info` is unavailable, skip — the real verification is the build in Task 10.)

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/capabilities/desktop.json
git commit -m "feat(updater): grant process:default capability for relaunch"
```

---

## Task 4: Add `@tauri-apps/plugin-process` npm package

**Files:**
- Modify: `apps/main/package.json` — `dependencies` block

- [ ] **Step 1: Install the package**

Run: `cd apps/main && bun add @tauri-apps/plugin-process@~2`
Expected: `package.json` gains `"@tauri-apps/plugin-process": "~2"` under `dependencies`, and `bun.lockb`/`package-lock.json` is updated.

- [ ] **Step 2: Verify the dependency is present**

Run: `grep '@tauri-apps/plugin-process' apps/main/package.json`
Expected output: a line showing the dependency, e.g. `"@tauri-apps/plugin-process": "~2",`

- [ ] **Step 3: Commit**

```bash
git add apps/main/package.json apps/main/bun.lockb apps/main/package-lock.json
git commit -m "feat(updater): add @tauri-apps/plugin-process npm dependency"
```

(If `bun.lockb` does not exist in the repo, only add `package.json` and `package-lock.json`.)

---

## Task 5: Create the status types + pure `renderStatus` helper (TDD)

**Files:**
- Create: `apps/main/src/modules/updater.ts`
- Create: `apps/main/src/modules/updater.test.ts`

This task establishes the public types and a pure helper that formats the status line for the UI. The helper is the only purely-testable part of the module; the rest is IPC orchestration and is verified manually in Task 10.

- [ ] **Step 1: Write the failing test**

Create `apps/main/src/modules/updater.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { renderStatus, type UpdateStatus } from "./updater";

describe("renderStatus", () => {
  it("returns null for idle", () => {
    expect(renderStatus({ kind: "idle" })).toBeNull();
  });

  it("describes the checking state", () => {
    expect(renderStatus({ kind: "checking" })).toBe("Checking for updates…");
  });

  it("shows percentage while downloading when total is known", () => {
    const s: UpdateStatus = { kind: "downloading", downloaded: 25, total: 100 };
    expect(renderStatus(s)).toBe("Downloading… 25%");
  });

  it("floors fractional percentages while downloading", () => {
    const s: UpdateStatus = { kind: "downloading", downloaded: 33, total: 100 };
    expect(renderStatus(s)).toBe("Downloading… 33%");
    const s2: UpdateStatus = { kind: "downloading", downloaded: 1, total: 3 };
    expect(renderStatus(s2)).toBe("Downloading… 33%");
  });

  it("reports 0% when total is unknown", () => {
    const s: UpdateStatus = { kind: "downloading", downloaded: 500, total: 0 };
    expect(renderStatus(s)).toBe("Downloading… 0%");
  });

  it("describes the installing state", () => {
    expect(renderStatus({ kind: "installing" })).toBe("Installing…");
  });

  it("describes the error state", () => {
    expect(renderStatus({ kind: "error", message: "boom" })).toBe(
      "Update failed. See console for details."
    );
  });
});
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `cd apps/main && npx vitest run src/modules/updater.test.ts`
Expected: FAIL — `Cannot find module './updater'`.

- [ ] **Step 3: Create the module with types and helper**

Create `apps/main/src/modules/updater.ts`:

```ts
import { atom } from "jotai";

export type UpdateStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "downloading"; downloaded: number; total: number }
  | { kind: "installing" }
  | { kind: "error"; message: string };

export const updateStatusAtom = atom<UpdateStatus>({ kind: "idle" });

export function renderStatus(status: UpdateStatus): string | null {
  switch (status.kind) {
    case "idle":
      return null;
    case "checking":
      return "Checking for updates…";
    case "downloading": {
      const pct = status.total > 0
        ? Math.floor((status.downloaded / status.total) * 100)
        : 0;
      return `Downloading… ${pct}%`;
    }
    case "installing":
      return "Installing…";
    case "error":
      return "Update failed. See console for details.";
  }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd apps/main && npx vitest run src/modules/updater.test.ts`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/modules/updater.ts apps/main/src/modules/updater.test.ts
git commit -m "feat(updater): add status types and renderStatus helper"
```

---

## Task 6: Implement `checkForUpdates` orchestration

**Files:**
- Modify: `apps/main/src/modules/updater.ts`

This is the integration layer. It cannot be unit-tested without mocking four Tauri plugins plus the jotai store — not worth the scaffolding for an eight-case flow. It is verified manually in Task 10, which covers every branch.

- [ ] **Step 1: Append the imports needed for orchestration**

At the **top** of `apps/main/src/modules/updater.ts`, add these imports above the existing `import { atom } from "jotai";` line:

```ts
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { ask, message } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import { getVersion } from "@tauri-apps/api/app";
import { customStore } from "@/stores/jotai";
```

The final import section should read:

```ts
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { ask, message } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import { getVersion } from "@tauri-apps/api/app";
import { atom } from "jotai";
import { customStore } from "@/stores/jotai";
```

- [ ] **Step 2: Append the orchestration function to the bottom of the file**

Add below the `renderStatus` function:

```ts
let checkInFlight = false;

export async function checkForUpdates(opts: { silent: boolean }): Promise<void> {
  if (checkInFlight) return;

  // Defense-in-depth: plugin-process / plugin-updater aren't bundled for mobile.
  // apps/mobile doesn't import this module today, but the guard prevents
  // crashes if that ever changes (e.g., via a shared packages/ layer).
  const p = await platform();
  if (p !== "macos" && p !== "windows" && p !== "linux") return;

  checkInFlight = true;
  customStore.set(updateStatusAtom, { kind: "checking" });

  try {
    const update: Update | null = await check();

    if (!update) {
      customStore.set(updateStatusAtom, { kind: "idle" });
      if (!opts.silent) {
        const v = await getVersion();
        await message(`You're on the latest version (v${v}).`, {
          title: "No updates available",
          kind: "info",
        });
      }
      return;
    }

    const accepted = await ask(
      `Rishi v${update.version} is available. Install and restart now?`,
      {
        title: "Update available",
        kind: "info",
        okLabel: "Install",
        cancelLabel: "Later",
      }
    );
    if (!accepted) {
      customStore.set(updateStatusAtom, { kind: "idle" });
      return;
    }

    let downloaded = 0;
    let total = 0;
    await update.downloadAndInstall((event) => {
      switch (event.event) {
        case "Started":
          total = event.data.contentLength ?? 0;
          customStore.set(updateStatusAtom, {
            kind: "downloading",
            downloaded: 0,
            total,
          });
          break;
        case "Progress":
          downloaded += event.data.chunkLength;
          customStore.set(updateStatusAtom, {
            kind: "downloading",
            downloaded,
            total,
          });
          break;
        case "Finished":
          customStore.set(updateStatusAtom, { kind: "installing" });
          break;
      }
    });

    await relaunch();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn("[updater] failed:", msg);
    if (opts.silent) {
      // Silent mode: reset to idle so the popover doesn't persistently show
      // "Update failed" for a check the user never initiated.
      customStore.set(updateStatusAtom, { kind: "idle" });
    } else {
      customStore.set(updateStatusAtom, { kind: "error", message: msg });
      await message(
        "Unable to check for updates. Please check your connection.",
        { title: "Update check failed", kind: "error" }
      );
    }
  } finally {
    checkInFlight = false;
  }
}
```

- [ ] **Step 3: Verify the module type-checks and the existing test still passes**

Run: `cd apps/main && npx vitest run src/modules/updater.test.ts`
Expected: PASS (7 tests, same as Task 5).

Run: `cd apps/main && npx tsc --noEmit -p .`
Expected: no errors touching `src/modules/updater.ts`. (Pre-existing repo errors in unrelated files are acceptable; only new errors introduced here would be a problem.)

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/modules/updater.ts
git commit -m "feat(updater): add checkForUpdates orchestration"
```

---

## Task 7: Create `useStartupUpdateCheck` hook

**Files:**
- Create: `apps/main/src/hooks/useStartupUpdateCheck.ts`

- [ ] **Step 1: Create the hook**

Create `apps/main/src/hooks/useStartupUpdateCheck.ts`:

```ts
import { useEffect } from "react";
import { checkForUpdates } from "@/modules/updater";

/**
 * Runs one silent update check per app session, shortly after mount.
 * Silent failures are swallowed so the user is never disturbed on startup.
 * See docs/superpowers/specs/2026-04-16-auto-updater-design.md.
 */
export function useStartupUpdateCheck(): void {
  useEffect(() => {
    void checkForUpdates({ silent: true });
  }, []);
}
```

- [ ] **Step 2: Verify it type-checks**

Run: `cd apps/main && npx tsc --noEmit -p .`
Expected: no new errors in `src/hooks/useStartupUpdateCheck.ts`.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/hooks/useStartupUpdateCheck.ts
git commit -m "feat(updater): add useStartupUpdateCheck hook"
```

---

## Task 8: Create the `UpdateMenu` popover component

**Files:**
- Create: `apps/main/src/components/UpdateMenu.tsx`

- [ ] **Step 1: Create the component**

Create `apps/main/src/components/UpdateMenu.tsx`:

```tsx
import { useEffect, useState } from "react";
import { useAtomValue } from "jotai";
import { Settings } from "lucide-react";
import { getVersion } from "@tauri-apps/api/app";
import {
  Popover,
  PopoverTrigger,
  PopoverContent,
} from "@components/components/ui/popover";
import {
  checkForUpdates,
  renderStatus,
  updateStatusAtom,
} from "@/modules/updater";

export function UpdateMenu() {
  const status = useAtomValue(updateStatusAtom);
  const [version, setVersion] = useState<string>("");

  useEffect(() => {
    getVersion()
      .then(setVersion)
      .catch(() => {
        // getVersion only fails outside a Tauri context; safe to ignore.
      });
  }, []);

  const busy =
    status.kind === "checking" ||
    status.kind === "downloading" ||
    status.kind === "installing";
  const statusLine = renderStatus(status);

  return (
    <Popover>
      <PopoverTrigger
        aria-label="App settings"
        className="p-2 rounded-md hover:bg-black/10 text-black"
      >
        <Settings size={20} />
      </PopoverTrigger>
      <PopoverContent align="end" className="w-64">
        <div className="text-sm text-muted-foreground mb-3">
          Rishi {version ? `v${version}` : ""}
        </div>
        <button
          type="button"
          disabled={busy}
          onClick={() => void checkForUpdates({ silent: false })}
          className="w-full rounded-md border px-3 py-1.5 text-sm hover:bg-black/5 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {busy ? "Checking…" : "Check for Updates"}
        </button>
        {statusLine && (
          <div className="mt-2 text-xs text-muted-foreground">{statusLine}</div>
        )}
      </PopoverContent>
    </Popover>
  );
}
```

- [ ] **Step 2: Verify it type-checks**

Run: `cd apps/main && npx tsc --noEmit -p .`
Expected: no new errors in `src/components/UpdateMenu.tsx`.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/UpdateMenu.tsx
git commit -m "feat(updater): add UpdateMenu popover for manual check"
```

---

## Task 9: Wire the startup hook and library-page menu

**Files:**
- Modify: `apps/main/src/routes/__root.tsx`
- Modify: `apps/main/src/routes/index.lazy.tsx`

- [ ] **Step 1: Add the startup hook call in `__root.tsx`**

Current file (around lines 1–22):

```tsx
import Loader from "../components/Loader";
import { useQuery } from "@tanstack/react-query";
import { createRootRoute, Outlet } from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import { useEffect, type JSX } from "react";
import { getBooks } from "@/generated";
import { initDesktopSync, destroyDesktopSync } from "@/modules/sync-triggers";
import { SyncStatusIndicator } from "../components/SyncStatusIndicator";

export const Route = createRootRoute({
  component: () => <RootComponent />,
});

function RootComponent(): JSX.Element {
  // Initialize desktop sync on app mount
  useEffect(() => {
    initDesktopSync();
    return () => {
      destroyDesktopSync();
    };
  }, []);
```

Change the imports and body to:

```tsx
import Loader from "../components/Loader";
import { useQuery } from "@tanstack/react-query";
import { createRootRoute, Outlet } from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import { useEffect, type JSX } from "react";
import { getBooks } from "@/generated";
import { initDesktopSync, destroyDesktopSync } from "@/modules/sync-triggers";
import { SyncStatusIndicator } from "../components/SyncStatusIndicator";
import { useStartupUpdateCheck } from "@/hooks/useStartupUpdateCheck";

export const Route = createRootRoute({
  component: () => <RootComponent />,
});

function RootComponent(): JSX.Element {
  useStartupUpdateCheck();

  // Initialize desktop sync on app mount
  useEffect(() => {
    initDesktopSync();
    return () => {
      destroyDesktopSync();
    };
  }, []);
```

(The new import and the `useStartupUpdateCheck()` call are the only additions; everything else is unchanged.)

- [ ] **Step 2: Render `<UpdateMenu />` on the library page**

Current `apps/main/src/routes/index.lazy.tsx`:

```tsx
import FileDrop from "@components/FileComponent";
import { createLazyFileRoute } from "@tanstack/react-router";
import { motion } from "framer-motion";

export const Route = createLazyFileRoute("/")({
  component: Index,
});

function Index() {
  return (
    <motion.div layout className="grid place-items-center h-screen">
      <FileDrop />
    </motion.div>
  );
}
```

Replace with:

```tsx
import FileDrop from "@components/FileComponent";
import { UpdateMenu } from "@components/UpdateMenu";
import { createLazyFileRoute } from "@tanstack/react-router";
import { motion } from "framer-motion";

export const Route = createLazyFileRoute("/")({
  component: Index,
});

function Index() {
  return (
    <motion.div layout className="grid place-items-center h-screen relative">
      <div className="absolute right-4 top-4 z-10">
        <UpdateMenu />
      </div>
      <FileDrop />
    </motion.div>
  );
}
```

- [ ] **Step 3: Verify the app type-checks and existing tests still pass**

Run: `cd apps/main && npx tsc --noEmit -p .`
Expected: no new errors.

Run: `cd apps/main && npx vitest run src/modules/updater.test.ts`
Expected: PASS (7 tests).

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/routes/__root.tsx apps/main/src/routes/index.lazy.tsx
git commit -m "feat(updater): wire startup check and library-page update menu"
```

---

## Task 10: Manual end-to-end verification

The flow depends on native OS dialogs, a running GitHub release, and code signing — none of which can be exercised by unit tests. Do every check below before considering this feature done.

**Files:** none (verification only).

- [ ] **Step 1: Build the app in dev mode and confirm it starts without errors**

Run: `cd apps/main && bun run tauri dev`
Expected: app window opens, library page shows the new settings gear top-right, no console errors related to `plugin-process` / `plugin-updater` / capability permissions.

- [ ] **Step 2: Verify the popover and "no update" path**

1. Click the settings gear.
2. Popover shows `Rishi v0.1.0` (or current version) and a "Check for Updates" button.
3. Click "Check for Updates".
4. Expected: native dialog with title "No updates available" and body `"You're on the latest version (v0.1.0)."`
5. Popover status line disappears after dismissing the dialog.

(This step assumes you are already on the latest published release. If you are on a version older than what's on GitHub, you will get the "update available" dialog instead — proceed to Step 4 for the install path.)

- [ ] **Step 3: Verify the network-failure path**

1. Disconnect the machine from the network (or block `github.com` via `/etc/hosts`).
2. Click "Check for Updates".
3. Expected: native error dialog `"Unable to check for updates. Please check your connection."`
4. Popover status line shows `"Update failed. See console for details."`
5. Reconnect the network before continuing.

- [ ] **Step 4: Verify the silent startup path does nothing visible on up-to-date builds**

1. Restart the app with network connected.
2. Expected: no dialogs, no popover noise. If the popover is opened, the status line should be absent (idle).

- [ ] **Step 5: Verify the full install-and-relaunch happy path**

1. On a feature branch or tag, bump `apps/main/src-tauri/tauri.conf.json` `"version"` from `0.1.0` to `0.1.1` and `apps/main/package.json` `"version"` to `0.1.1`.
2. Commit, push the tag `v0.1.1`.
3. Wait for `.github/workflows/release-desktop.yml` to finish; confirm the GitHub release contains `latest.json` + signed artifacts for your platform.
4. Revert your local working tree to `v0.1.0` (or install the v0.1.0 build from an earlier release) and launch it.
5. Expected on startup: native dialog `"Rishi v0.1.1 is available. Install and restart now?"` with "Install" / "Later" buttons.
6. Click "Install". Expected: popover status cycles through `Checking…` → `Downloading… N%` → `Installing…` and the app relaunches on v0.1.1.
7. Open the popover post-relaunch: version reads `v0.1.1`.

- [ ] **Step 6: Verify the "Later" path does not re-prompt within the session**

1. Repeat Step 5 until the dialog appears.
2. Click "Later".
3. Expected: no further dialogs during this session.
4. Open the popover and click "Check for Updates" — the dialog reappears (manual check bypasses the "already declined this session" state because there's no persisted flag, only the in-flight guard).
5. Click "Later" again, then restart the app. Expected: dialog reappears on next startup.

- [ ] **Step 7: Verify concurrent-check guard**

1. Relaunch on an older version so the update dialog would appear.
2. Immediately after launch (while the silent check is still running), open the popover and click "Check for Updates".
3. Expected: only one dialog; the second click is a no-op while `checkInFlight` is `true`.

- [ ] **Step 8: Final commit if any small tweaks were made during manual verification**

```bash
# if nothing needed adjusting, skip this step
git status
# only if there are changes
git add -p
git commit -m "fix(updater): <describe tweak>"
```

---

## Self-Review Notes (for the author, not a task)

Spec coverage sanity check:

- §4.1 Rust wiring → Tasks 1, 2, 3
- §4.2 `updater.ts` → Tasks 5, 6
- §4.2 `useStartupUpdateCheck` → Task 7
- §4.2 `UpdateMenu` → Task 8
- §4.2 Placement / routing → Task 9
- §5 Error handling table → covered by Task 6 code + Task 10 verification
- §6 Testing matrix → Task 10, one substep per spec row
- §8 File change summary → Tasks 1–9 cover every file listed

No placeholders. Types and symbol names are consistent: `UpdateStatus`, `updateStatusAtom`, `renderStatus`, `checkForUpdates` appear identically in Tasks 5, 6, 7, and 8.
