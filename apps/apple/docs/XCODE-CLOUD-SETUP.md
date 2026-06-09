# Xcode Cloud Setup Runbook — Rishi for Apple

**Audience:** matovu90@gmail.com (Apple ID owner of the `org.fidexa.rishi` bundle)
**Purpose:** finalize the App Store Connect side of BOOT-09 so every push on `main` produces a TestFlight build with dSYMs uploaded to Sentry.

The repo side is already done — `ci_scripts/`, `fastlane/`, `Gemfile`, and `.xcode-version` ship in `apps/apple/`. What remains can only be done inside App Store Connect's web UI and at sentry.io. Work top-to-bottom; each step has an explicit verify.

---

## 0. Prerequisites checklist

Confirm each item before moving on:

- [ ] Apple Developer Program membership active (Account → Membership shows "Active" with current expiry).
- [ ] App record exists in App Store Connect for bundle id `org.fidexa.rishi`. If missing:
  - https://appstoreconnect.apple.com/apps → **+** → **New App**
  - Platforms: iOS + macOS (Mac Catalyst); Name: `Rishi`; Primary Language: English (U.S.); Bundle ID: `org.fidexa.rishi`; SKU: `rishi-apple`.
- [ ] Xcode Cloud is enabled on this Apple Developer team (free tier — 25 compute hours/month — is sufficient for one workflow).
  - https://appstoreconnect.apple.com → Users and Access → Integrations → Xcode Cloud → **Get Started**, accept the terms.
- [ ] Sentry account exists at https://sentry.io and a project named `rishi-apple` is created under the `fidexa` org (or substitute your real slugs).

---

## 1. Step 1 — Create the Xcode Cloud workflow

1. App Store Connect → Apps → **Rishi** → **Xcode Cloud** tab → **Create Workflow**.
2. **Source code repository:** pick GitHub, authorize the App Store Connect GitHub app on the `rishi-monorepo` repository.
3. **Repository details:**
   - Owner: `matovu-farid`
   - Repository: `rishi-monorepo`
   - Branch / source: `main`
4. **Project / workspace path:** `apps/apple/rishi/rishi.xcodeproj`
5. **Scheme:** `rishi`
6. **Workflow name:** `Rishi (Build & TestFlight)`
7. **Start condition (initial):** Branch Changes → branch `main` → "Auto-cancel builds" off.
   Later phases will swap this for a tag-based release trigger.

Verify: workflow appears in the Workflows list with status `Edit Required` (we still have actions and secrets to attach below).

---

## 2. Step 2 — Configure the Build action

Inside the workflow editor:

1. **Action: Archive** (delete any default `Build` or `Test` action if it conflicts — they're not needed for BOOT-09).
2. **Platform:** add **iOS** and **Mac Catalyst** destinations.
3. **Distribution preparation:** **TestFlight (Internal Testing Only)**.
   Do NOT enable external testing for this skeleton build.
4. **Distribution certificate:** select "Use Xcode Cloud's automatic signing" — Apple manages the cert + provisioning profile inside the runner.

Verify: the Archive action card shows iOS + Mac Catalyst, TestFlight Internal selected, no warning triangles.

---

## 3. Step 3 — Custom build script path

Xcode Cloud's default convention looks for `ci_scripts/` adjacent to the `.xcodeproj`. In this repo, the scripts live at `apps/apple/ci_scripts/` (one level up — see CONCERNS.md for the gitlink reason). Tell Xcode Cloud where to find them:

1. Workflow → Environment → **Custom Build Script Path** (under Advanced) → enter `apps/apple/ci_scripts`.
2. If your Xcode Cloud UI does not expose that field (older revisions hid it), add a symlink in the workflow's post-clone hook instead: the bundled `apps/apple/ci_scripts/ci_post_clone.sh` will be invoked automatically by Apple's runner because the file name and shape match — Xcode Cloud walks up from the project path until it finds a `ci_scripts` directory.

Verify on the first build: the live log shows `[ci_post_clone] done` before the archive step starts.

---

## 4. Step 4 — Attach the Sentry secrets

Workflow → **Environment** → **Custom Environment Variables** → add **three** variables, all marked **Secret** so they are masked in build logs:

| Name                  | Value                                                                                                                              | How to get it                                                                                                              |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `SENTRY_AUTH_TOKEN`   | a Sentry user/integration token with scopes `project:releases` **and** `project:write`                                              | https://sentry.io/settings/account/api/auth-tokens/ → **Create New Token** → tick both scopes → copy once (it won't reappear). |
| `SENTRY_ORG_SLUG`     | usually `fidexa`                                                                                                                    | Sentry → Settings → Organization → **Organization Slug**.                                                                  |
| `SENTRY_PROJECT_SLUG` | usually `rishi-apple` (create the project at https://sentry.io if it does not exist — pick **Apple iOS / Cocoa** as the platform) | Sentry → Projects → click `rishi-apple` → URL slug after `/projects/`.                                                     |

Verify: all three rows show **(Secret)** next to the value field. Save the workflow.

---

## 5. Step 5 — App Store Connect API key (only needed if you ever run Fastlane locally)

The Xcode Cloud workflow itself uses Apple's built-in TestFlight distribution path and does **not** need an API key for the skeleton build. You only need to set one up if you later want to run `fastlane testflight_skeleton` from your laptop.

If/when you do:

1. https://appstoreconnect.apple.com/access/integrations/api → **Generate API Key** → role: **App Manager**, name: `rishi-apple-fastlane`.
2. Download `AuthKey_<KeyID>.p8` (one-time download).
3. Store these three values in your local shell as env vars (or 1Password, or `.env.local`):
   - `APP_STORE_CONNECT_API_KEY_ID` = the Key ID shown on the integrations page
   - `APP_STORE_CONNECT_API_ISSUER_ID` = the Issuer ID at the top of the integrations page
   - `APP_STORE_CONNECT_API_KEY_CONTENT` = base64 of the `.p8` file: `base64 -i AuthKey_<KeyID>.p8`
4. Re-run `fastlane testflight_skeleton` from `apps/apple/` to confirm.

---

## 6. Step 6 — Trigger the first build and verify

From your laptop, on a clean `main`:

```bash
git commit --allow-empty -m "ci: trigger initial Xcode Cloud build (BOOT-09 smoke test)"
git push origin main
```

Then in App Store Connect → Apps → Rishi → Xcode Cloud → Builds, watch the build.

Expected timeline (~12–20 min on a cold cache):

1. **Clone** — completes in seconds.
2. **Post-clone hook** — log shows `[ci_post_clone] done` after Bundler + sentry-cli install.
3. **Archive** — Xcode Cloud builds the `rishi` scheme for iOS + Catalyst destinations. **Status must be Succeeded.**
4. **Post-xcodebuild hook** — log shows `[ci_post_xcodebuild] dSYM upload complete`.
5. **TestFlight upload** — TestFlight tab in App Store Connect shows one build with status `Processing` → `Ready to Test` (internal).
6. **Sentry** — https://sentry.io/organizations/fidexa/projects/rishi-apple/ → Settings → Debug Files shows one upload with a UUID set. Cross-check locally:
   ```bash
   xcrun dwarfdump --uuid path/to/rishi.app.dSYM/Contents/Resources/DWARF/rishi
   ```
   The UUID printed must match a row in Sentry's Debug Files table.

---

## 7. BOOT-09 verification checklist (Phase 0 success criterion #4)

Mark each box once the corresponding evidence appears:

- [ ] Xcode Cloud workflow `Rishi (Build & TestFlight)` exists in App Store Connect and shows a green Archive run.
- [ ] `ci_post_clone.sh` ran during that build (Xcode Cloud build log contains `[ci_post_clone] done`).
- [ ] `ci_post_xcodebuild.sh` invoked `fastlane upload_dsyms` (log contains `[ci_post_xcodebuild] dSYM upload complete`).
- [ ] An empty TestFlight build appears in App Store Connect → Rishi → TestFlight, carrying the synthesized Info.plist keys from Plan 00-03 (PrivacyInfo.xcprivacy, entitlements, BGTaskScheduler IDs).

Once all four are checked, BOOT-09 is satisfied. Tick `[ ] BOOT-09` in REQUIREMENTS.md and mark Phase 0 success criterion #4 met in STATE.md.

---

## 8. Troubleshooting

### `ITMS-91053: Missing API declarations`

Plan 00-03 did not land — the bundle is missing `PrivacyInfo.xcprivacy`.

- Verify `apps/apple/rishi/rishi/PrivacyInfo.xcprivacy` exists and is added to the `rishi` target's **Copy Bundle Resources** build phase.
- Re-run the workflow.

### `code signing required` / `No signing certificate found`

The workflow lost its automatic signing pick.

- Workflow editor → Archive action → **Distribution certificate** → re-select "Use Xcode Cloud's automatic signing".
- Confirm the team has at least one Distribution certificate at Account → Certificates.

### `Sentry 401 Unauthorized` in post-xcodebuild log

`SENTRY_AUTH_TOKEN` is missing, has the wrong scope, or was rotated out.

- Regenerate at https://sentry.io/settings/account/api/auth-tokens/ with scopes `project:releases` + `project:write`.
- Update the secret in the Xcode Cloud workflow environment.

### `Could not find Gemfile` in post-clone log

The script could not `cd` into `apps/apple/`. Either the repo path layout changed or `$CI_PRIMARY_REPOSITORY_PATH` is unset.

- Confirm `apps/apple/Gemfile` is present on `main`.
- Inspect the Xcode Cloud build log for the line `cd "$CI_PRIMARY_REPOSITORY_PATH/apps/apple"` and follow what failed.

### `xcodebuild: error: '-resolvePackageDependencies' requires …`

Xcode Cloud's runner picked an Xcode older than `.xcode-version`.

- Verify `apps/apple/.xcode-version` contains a Xcode major version that App Store Connect actually offers; bump if Apple has retired 16.4.

### `bundle install` is slow on every build

Add Xcode Cloud's **Custom Cache Path** for `~/.bundle` and `apps/apple/vendor/bundle`. Workflow → Environment → Custom Cache Paths.

---

Once steps 1–6 are green, BOOT-09 is satisfied. Mark `[ ] BOOT-09` checked in REQUIREMENTS.md and Phase 0 success criterion #4 met in STATE.md.
