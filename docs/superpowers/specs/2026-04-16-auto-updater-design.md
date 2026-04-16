# Auto-Updater — Design Spec

**Date:** 2026-04-16
**Scope:** desktop only (macOS, Windows, Linux). Mobile updates go through App Store / Play Store.

## 1. Goal

Let the desktop app detect that a new version has been released on GitHub, and prompt the user to install it with a single confirmation.

## 2. Context — what already exists

The updater plugin is fully bootstrapped in the repo; only the frontend flow is missing.

| Layer | File | Status |
|---|---|---|
| Rust dep | `apps/main/src-tauri/Cargo.toml:79` — `tauri-plugin-updater = "2"` behind `cfg(not(any(target_os = "android", target_os = "ios")))` | done |
| Rust registration | `apps/main/src-tauri/src/lib.rs:52` — `.plugin(tauri_plugin_updater::Builder::new().build())` | done |
| Config | `apps/main/src-tauri/tauri.conf.json` — `plugins.updater.pubkey` + `endpoints: [".../releases/latest/download/latest.json"]`; `bundle.createUpdaterArtifacts: true` | done |
| Capability | `apps/main/src-tauri/capabilities/desktop.json` — `updater:default` | done |
| JS dep | `apps/main/package.json:42` — `@tauri-apps/plugin-updater ~2` | done |
| CI signing | `.github/workflows/release-desktop.yml` — `TAURI_SIGNING_PRIVATE_KEY` + `includeUpdaterJson: true` on `v*` tags | done |
| `process` plugin (needed for `relaunch()`) | — | **missing** |
| Frontend flow (`check` + prompt + install + relaunch) | — | **missing** |
| Manual "Check for Updates" UI | — | **missing** |

## 3. User-facing behavior

**Check frequency:** on every app startup, plus a manual "Check for Updates" button in a settings popover on the library page.

**Prompt style:** native OS dialog (`tauri-plugin-dialog`'s `ask()`). No release notes shown — the dialog text is `"Rishi vX.Y.Z is available. Install and restart now?"` with Yes/No.

**Startup check (silent):**
1. Check runs once shortly after app mount.
2. Network errors are swallowed silently — user never sees a failure toast on startup.
3. If no update → nothing happens.
4. If update found → native Yes/No dialog.
5. Yes → download + install + relaunch.
6. No → nothing happens; re-prompts on next startup.

**Manual check (non-silent):**
1. User clicks the settings gear in the library-page top-right, then "Check for Updates".
2. Network failure → native `message()` dialog: `"Unable to check for updates. Please check your connection."`
3. No update → native `message()` dialog: `"You're on the latest version (vX.Y.Z)."`
4. Update found → same Yes/No prompt as silent path.
5. Popover shows live status (`checking` / `downloading N%` / `installing` / `error`).

## 4. Architecture

### 4.1 New Rust / Tauri wiring

- Add `tauri-plugin-process = "2"` to `apps/main/src-tauri/Cargo.toml` under the same desktop-only target gate used for `tauri-plugin-updater`.
- Register it in `apps/main/src-tauri/src/lib.rs` alongside the updater registration: `.plugin(tauri_plugin_process::init())`. Gate the registration with `#[cfg(not(any(target_os = "android", target_os = "ios")))]` to mirror the Cargo gate.
- Add `process:default` to `apps/main/src-tauri/capabilities/desktop.json` permissions. (`process:default` includes `allow-restart` and `allow-exit`; we only need restart.)

### 4.2 New frontend modules

#### `apps/main/src/modules/updater.ts`

Single source of truth for update flow.

```ts
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { ask, message } from "@tauri-apps/plugin-dialog";
import { platform } from "@tauri-apps/plugin-os";
import { getVersion } from "@tauri-apps/api/app";
import { atom } from "jotai";
import { customStore } from "@/stores/jotai";

export type UpdateStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "downloading"; downloaded: number; total: number }
  | { kind: "installing" }
  | { kind: "error"; message: string };

export const updateStatusAtom = atom<UpdateStatus>({ kind: "idle" });

let checkInFlight = false;

export async function checkForUpdates(opts: { silent: boolean }): Promise<void> {
  if (checkInFlight) return;
  // Defensive guard — plugin isn't registered on mobile builds.
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
      { title: "Update available", kind: "info", okLabel: "Install", cancelLabel: "Later" }
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
          customStore.set(updateStatusAtom, { kind: "downloading", downloaded: 0, total });
          break;
        case "Progress":
          downloaded += event.data.chunkLength;
          customStore.set(updateStatusAtom, { kind: "downloading", downloaded, total });
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
      await message("Unable to check for updates. Please check your connection.", {
        title: "Update check failed",
        kind: "error",
      });
    }
  } finally {
    checkInFlight = false;
  }
}
```

**Key design choices:**
- Single entrypoint; `silent` flag is the only behavioral split.
- Jotai atom (`updateStatusAtom`) drives the popover status line. The existing global store (`customStore` from `@/stores/jotai`, already used elsewhere in the codebase) is written to directly so callers don't have to pass providers.
- Module-level `checkInFlight` flag prevents concurrent checks.
- Platform guard makes the module safe to import anywhere (including potential shared layers) without a mobile-bundle crash.
- Errors in silent mode only log + update status; never interrupt the user.

#### `apps/main/src/hooks/useStartupUpdateCheck.ts`

Runs the silent check once per app session.

```ts
import { useEffect } from "react";
import { checkForUpdates } from "@/modules/updater";

export function useStartupUpdateCheck() {
  useEffect(() => {
    void checkForUpdates({ silent: true });
  }, []);
}
```

Called once from `apps/main/src/routes/__root.tsx` inside `RootComponent` — alongside the existing `initDesktopSync()` effect.

#### `apps/main/src/components/UpdateMenu.tsx`

Library-page settings gear + popover.

```tsx
// Shape only — exact UI primitive imports match ReaderSettings.tsx
import { Popover, PopoverTrigger, PopoverContent } from "@components/components/ui/popover";
import { Settings } from "lucide-react";
import { useAtomValue } from "jotai";
import { useEffect, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { checkForUpdates, updateStatusAtom } from "@/modules/updater";

export function UpdateMenu() {
  const status = useAtomValue(updateStatusAtom);
  const [version, setVersion] = useState<string>("");

  useEffect(() => {
    getVersion().then(setVersion);
  }, []);

  const busy = status.kind !== "idle" && status.kind !== "error";
  const statusLine = renderStatus(status);

  return (
    <Popover>
      <PopoverTrigger aria-label="App settings">
        <Settings size={20} />
      </PopoverTrigger>
      <PopoverContent align="end">
        <div className="text-sm text-muted-foreground mb-2">Rishi v{version}</div>
        <button
          disabled={busy}
          onClick={() => checkForUpdates({ silent: false })}
          className="w-full"
        >
          {busy ? "Checking…" : "Check for Updates"}
        </button>
        {statusLine && <div className="mt-2 text-xs">{statusLine}</div>}
      </PopoverContent>
    </Popover>
  );
}

function renderStatus(s: import("@/modules/updater").UpdateStatus) {
  switch (s.kind) {
    case "idle": return null;
    case "checking": return "Checking for updates…";
    case "downloading": {
      const pct = s.total > 0 ? Math.floor((s.downloaded / s.total) * 100) : 0;
      return `Downloading… ${pct}%`;
    }
    case "installing": return "Installing…";
    case "error": return "Update failed. See console for details.";
  }
}
```

**Placement:** rendered inside `apps/main/src/routes/index.lazy.tsx` at the top-right of the library page, absolutely positioned (e.g., `className="absolute right-4 top-4"` inside the Index component's wrapper). It does **not** render on book reader routes because `epub.tsx` already owns top-right real estate there.

### 4.3 Data flow

```
┌──────────────┐   mount    ┌──────────────────────────┐
│  __root.tsx  │──────────▶│ useStartupUpdateCheck     │
└──────────────┘            │   └▶ checkForUpdates({silent:true})
                            └──────────────────────────┘
                                         │
┌───────────────────┐  click   ┌────────▼──────────┐        ┌──────────────┐
│ UpdateMenu button │────────▶ │ checkForUpdates   │──────▶ │ plugin-updater│
└───────────────────┘          │ ({silent:false})  │        │   .check()    │
                               └────────┬──────────┘        └──────┬───────┘
                                        │                          │ Update | null
                                        │        ┌─────────────────┘
                                        ▼        ▼
                                 ┌──────────────────┐
                                 │ plugin-dialog.ask │ ─── accepted=false ──▶ idle
                                 └────────┬──────────┘
                                          │ accepted=true
                                          ▼
                        ┌────────────────────────────────────┐
                        │ update.downloadAndInstall(cb)      │
                        │    cb writes updateStatusAtom      │──▶ UpdateMenu reads via useAtomValue
                        └────────────┬───────────────────────┘
                                     ▼
                            plugin-process.relaunch()
```

## 5. Error handling

| Failure | Silent mode | Manual mode |
|---|---|---|
| `check()` network error | log only, status → `error`, stays idle to user | `message()` dialog: "Unable to check for updates…" |
| `downloadAndInstall()` fails mid-stream | log, status → `error`, user sees "Update failed" in popover | same + `message()` dialog |
| User clicks Cancel on `ask()` | status → `idle`, no retry | same |
| Platform unsupported (mobile) | early return, no-op | early return, no-op |
| Already in-flight | early return | early return |

No Sentry integration added for updater errors; existing `sentry` init in `lib.rs` will still catch unhandled rejections. Console warnings are sufficient for surfacing to developers.

## 6. Testing

No automated tests are practical for this flow — it exercises native OS dialogs, a Tauri IPC plugin, and platform code signing. Verification is manual:

1. **Happy path:** build v0.1.0 locally, push tag `v0.1.1` → GitHub release built by CI → open v0.1.0 app → startup dialog appears → click Install → downloads, installs, relaunches as v0.1.1.
2. **No update:** run v0.1.1 when `v0.1.1` is the latest release → startup does nothing → manual check shows "You're on the latest version".
3. **Network failure:** run app offline → startup is silent → manual check shows error dialog.
4. **User declines:** dismiss startup dialog → no reprompt this session → restart app → dialog appears again.
5. **Concurrent clicks:** spam the "Check for Updates" button → only one check runs (in-flight guard).
6. **Mobile safety:** `apps/mobile` is a separate package that does not import from `apps/main`, so `updater.ts` and `@tauri-apps/plugin-process` never reach the mobile bundle. The runtime `platform()` check in `checkForUpdates` is a defense-in-depth guard in case that invariant ever changes (e.g., someone introduces a shared `packages/` layer that imports `updater.ts`).

## 7. Out of scope (YAGNI)

- Release notes display (user picked native dialog, which doesn't show them).
- Release-channel selection (alpha/beta).
- Auto-install without prompting.
- "Remind me in N days" / snooze.
- In-app progress bar during install (status text in popover is enough; native dialog blocks interaction during download anyway).
- Rollback / downgrade.
- Native OS menu bar entry — can be added later without touching the `updater.ts` module.
- Sentry breadcrumbs for updater events.

## 8. File change summary

**New files:**
- `apps/main/src/modules/updater.ts`
- `apps/main/src/hooks/useStartupUpdateCheck.ts`
- `apps/main/src/components/UpdateMenu.tsx`

**Modified files:**
- `apps/main/src-tauri/Cargo.toml` — add `tauri-plugin-process = "2"` under the desktop-only target section (lines 78–79 region).
- `apps/main/src-tauri/src/lib.rs` — register `tauri_plugin_process::init()` with matching desktop `cfg` gate.
- `apps/main/src-tauri/capabilities/desktop.json` — add `"process:default"` to `permissions`.
- `apps/main/package.json` — add `"@tauri-apps/plugin-process": "~2"`.
- `apps/main/src/routes/__root.tsx` — call `useStartupUpdateCheck()` inside `RootComponent`.
- `apps/main/src/routes/index.lazy.tsx` — render `<UpdateMenu />` absolutely top-right of the Index component.

No changes to CI, signing, or `tauri.conf.json` — release pipeline already publishes `latest.json` with a valid signature.
