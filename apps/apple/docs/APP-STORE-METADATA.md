# App Store Metadata + Submission Runbook — Rishi for Apple

**Audience:** matovu90@gmail.com (Apple ID owner of the `org.fidexa.rishi` bundle)
**Purpose:** make it impossible to forget a metadata field, an App Privacy answer, a required-reason API entry, or a Reader-App-entitlement disclosure when shipping a build to App Store Connect — for both the iOS App Store and the Mac App Store.

This runbook covers the metadata side of DIST-03. Screenshot capture lives in plan 12-06. Xcode Cloud build configuration lives in `docs/XCODE-CLOUD-SETUP.md`.

**Last updated:** 2026-06-10 (Phase 12 plan 12-05)

---

## 0. Prerequisites checklist

Confirm each item before running either release lane:

- [ ] Apple Developer Program membership active.
- [ ] App record exists in App Store Connect for bundle id `org.fidexa.rishi` (iOS + macOS via Mac Catalyst). If missing, create it under https://appstoreconnect.apple.com/apps → **+** → **New App**.
- [ ] App Store Connect API key configured locally (`APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_CONTENT`). See `docs/XCODE-CLOUD-SETUP.md` § 5.
- [ ] `bundle install` succeeded in `apps/apple/`. The release lanes depend on the Gemfile-pinned `fastlane`.
- [ ] Reader App entitlement application (`com.apple.developer.storekit.external-link.account`) status known. Pending today. If denied, see § 6 below.

---

## 1. Where each metadata field lives

| Field | Path | Limit | Source of truth |
| --- | --- | --- | --- |
| App name | `fastlane/metadata/en-US/name.txt` | 30 chars | This file |
| Subtitle | `fastlane/metadata/en-US/subtitle.txt` | 30 chars | This file |
| Description | `fastlane/metadata/en-US/description.txt` | 4000 chars | This file |
| Keywords | `fastlane/metadata/en-US/keywords.txt` | 100 chars | This file |
| Promotional text | `fastlane/metadata/en-US/promotional_text.txt` | 170 chars | This file (editable post-release without a binary push) |
| Release notes | `fastlane/metadata/en-US/release_notes.txt` | 4000 chars | This file |
| Marketing URL | `fastlane/metadata/en-US/marketing_url.txt` | URL | https://rishi.fidexa.org |
| Support URL | `fastlane/metadata/en-US/support_url.txt` | URL | https://rishi.fidexa.org/support |
| Privacy URL | `fastlane/metadata/en-US/privacy_url.txt` | URL | https://rishi.fidexa.org/privacy |
| Review contact | `fastlane/metadata/review_information/*.txt` | — | This file |
| App Privacy details | `fastlane/metadata/app_privacy.json` | — | Mirrors `rishi/rishi/PrivacyInfo.xcprivacy` |
| Screenshots | `fastlane/screenshots/en-US/<device>/` | per-device px | Captured in plan 12-06 |

All length limits are enforced by `fastlane/scripts/validate_metadata.rb`. CI breaks before upload if a field overflows.

---

## 2. Updating copy without re-shipping a binary

Promotional text, marketing URL, support URL, privacy URL, keywords, name, subtitle, and the App Privacy declarations can be updated against the **same** approved build:

```bash
cd apps/apple
# 1. Edit the relevant fastlane/metadata/en-US/*.txt or app_privacy.json
# 2. Lint
bundle exec fastlane metadata_validate
# 3. Upload metadata only (no binary)
bundle exec fastlane deliver --skip_binary_upload --skip_screenshots --force
```

Description, screenshots, and version-specific release notes require a new binary submission.

---

## 3. App Privacy answers → PrivacyInfo.xcprivacy mapping

`fastlane/metadata/app_privacy.json` and `rishi/rishi/PrivacyInfo.xcprivacy` MUST stay in lockstep — App Review compares them.

| `app_privacy.json` data type | PrivacyInfo.xcprivacy entry | Notes |
| --- | --- | --- |
| User Content / Other User Content | (declared via App Privacy only) | Books, highlights, notes, chat — not a Privacy Manifest collected-type code |
| Identifiers / User ID | (declared via App Privacy only) | SIWA stable user id, or Google sub |
| Contact Info / Email Address | (declared via App Privacy only) | May be private relay |
| Diagnostics / Crash Data | `NSPrivacyCollectedDataTypeCrashData`, linked=false, tracking=false | Sentry crash data |
| Diagnostics / Performance Data | `NSPrivacyCollectedDataTypePerformanceData`, linked=false, tracking=false | Sentry performance + breadcrumbs |
| Usage Data / Product Interaction | (declared via App Privacy only) | Anonymous reading-session + chat-turn counts |

Nothing is marked `used_for_tracking: true`. No third-party tracking SDKs are bundled. Confirm before each submission with:

```bash
grep -i 'tracking\|advertis' apps/apple/Packages/*/Sources/**/*.swift | grep -v '//' | head
```

If the grep returns hits, audit the new dep before submission.

---

## 4. Required-reason API mapping

`PrivacyInfo.xcprivacy` declares four required-reason APIs. App Review rejects builds with `ITMS-91053` if any in-bundle API access lacks a declaration. Current declarations:

| `NSPrivacyAccessedAPIType` | Reason code | Why we declare it |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | Reading file modification times when comparing local book modtime to sync state (RishiDB + sync engine) |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Storing reader settings, theme prefs, opt-out flags (RishiUIKit + RishiSettings) |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` | Pre-flight checks before importing or downloading a book (RishiLibrary + RishiSync) |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | Diagnostics breadcrumb context (RishiLogging + Sentry SDK) |

When adding a new dep:
1. Run Xcode → Product → Build → check Reports navigator for "Privacy Manifest" warnings.
2. Cross-reference the SDK's own `PrivacyInfo.xcprivacy` for inherited declarations.
3. Update `rishi/rishi/PrivacyInfo.xcprivacy` and re-run `bundle exec fastlane metadata_validate`.

---

## 5. Screenshot specs

Six device frames required. See `fastlane/screenshots/README.md` for the matrix. Briefly:

- iPhone 6.9" (1320×2868), 6.7" (1290×2796), 6.5" (1242×2688)
- iPad 13" (2064×2752), 11" (1668×2388)
- Mac (1280×800 minimum, 2880×1800 preferred)

Capture playbook executes in plan 12-06. For dry-runs before captures land, pass `SKIP_SCREENSHOTS=1` to the release lanes.

---

## 6. Common rejection causes — and the local mitigation

### Guideline 4.0 — Reader App entitlement

Rishi is a reader app. Subscription management lives at `rishi.fidexa.org`, not in-app.

- **Status today:** Reader App entitlement (External Link Account Entitlement) application is pending.
- **If APPROVED:** Settings → Subscription opens a SafariViewController to `rishi.fidexa.org/subscribe` with the external-link confirmation sheet (handled automatically by `_SCAccountStorefrontExtension`).
- **If DENIED:** Phase 11 ships text-only "Manage your subscription at rishi.fidexa.org" copy with zero tappable billing UI. Code-path already gated on `Pro.entitlement.canPresentExternalLink` — flip to `false` and re-ship.

Both paths are documented in `STATE.md` Phase 0 decisions.

### Guideline 5.1.1(v) — Account deletion

App Review requires in-app account deletion when the app supports account creation. Present in Settings → Account → Delete Account. Implementation:

1. Client calls `POST /api/auth/delete-user` on our worker.
2. Worker calls `https://appleid.apple.com/auth/revoke` server-side per Pitfall 1.
3. Worker deletes the user row + cascades sync state.
4. Client clears Keychain + signs out.

Failures on the worker side log to `siwa_revocation_failures`. Row deletion proceeds anyway so the user is not stranded. See Phase 3 plan 03-05 for the client wiring.

### Guideline 2.1 — Voice chat permission primer

Mic permission requires an in-app primer per Phase 11 ONB-02 before the system prompt. Settings → Voice Chat → "How voice chat works" walks through it. App Review prompt: cite the primer in the reviewer notes; reviewers historically accept this when the primer is present.

### Guideline 5.1.2 — Background sync data minimization

Silent push wakes the app for sync. We do NOT collect IDFA, contacts, or location during background runs. Background runs only fetch the next sync window and exit. See Phase 7 plan 07-04.

### `ITMS-91053` — Missing API declarations

Cause: a new dep introduced a required-reason API call without an entry in `PrivacyInfo.xcprivacy`. Mitigation: see § 4 above.

---

## 7. Mac App Store gotchas (Catalyst-specific)

- **Sandbox entitlement:** Catalyst Release builds use `App Sandbox` automatically. Verify via Signing & Capabilities for the rishi target.
- **Microphone permission UX:** Catalyst requires `NSMicrophoneUsageDescription` in `Info.plist` (already present from Phase 0 BOOT-01). On macOS, the system prompt only fires the FIRST time the engine starts — the primer must run before that.
- **Hardened runtime:** Release Catalyst builds need Hardened Runtime with `com.apple.security.device.audio-input` for mic. Already in the entitlements file.
- **Signed dev builds for mic testing:** Local debug Catalyst builds will silently fail mic access unless signed with a Developer ID certificate. See the `project_macos_mic_entitlements` user memory for the workaround — sign dev builds with `codesign --force --sign "Developer ID Application: Farid Matovu (<TEAM>)" …`.
- **Mac App Store screenshot dimensions:** Differ from iOS. The Mac frame is 1280×800 minimum, 2880×1800 preferred. Captured in plan 12-06.

---

## 8. Lane usage

All commands run from `apps/apple/`.

```bash
# Lint metadata only — fast, runs in seconds, no Xcode build
bundle exec fastlane metadata_validate

# Dry-run iOS App Store upload (no screenshots; assumes captures not yet ready)
bundle exec fastlane release_app_store SKIP_SCREENSHOTS=1

# Full iOS App Store upload (post plan 12-06 captures)
bundle exec fastlane release_app_store

# Mac App Store upload
bundle exec fastlane release_mac_app_store
```

Neither release lane auto-submits for review. Submission is a manual step in App Store Connect → Apps → Rishi → iOS App / macOS App → Add for Review, after the build status reads "Ready to Submit".

---

## 9. Troubleshooting

### `metadata_validate` fails on `name.txt exceeds 30 char limit`

You edited copy past Apple's hard cap. Trim. The validator prints the exact byte count.

### `metadata_validate` fails on `marketing_url.txt must be http(s)`

You either left a placeholder (`example.com`) or pasted an `ftp://` link. Replace with the production URL.

### `upload_to_app_store` fails on App Privacy mismatch

`app_privacy.json` does not match what App Store Connect already has on file. Either:
- Re-run `bundle exec fastlane deliver --skip_binary_upload --force` to push the new declarations, or
- Reconcile by hand in the App Store Connect UI under App Privacy.

### `upload_to_app_store` fails on `Invalid Provisioning Profile`

App Store Connect API key expired or scope is wrong. Regenerate at https://appstoreconnect.apple.com/access/integrations/api with role **App Manager**.

### `release_app_store` fails before metadata upload

`metadata_validate` is the first step. Read the printed errors and re-run. The validator is intentionally fail-fast so you fix all errors in one cycle.

---

## 10. Deferred items (tracked here, not blockers)

- [ ] Real phone number in `review_information/phone_number.txt` (placeholder today — App Review prefers a reachable number).
- [ ] Localized metadata beyond `en-US` (English-only at v1).
- [ ] Real screenshot captures land in plan 12-06.
- [ ] Reader App entitlement application status — moves out of "Pending" once Apple replies.
- [ ] Apple `team_id` in `fastlane/Appfile` is sourced from `APP_STORE_CONNECT_API_KEY_*` env at runtime; if we ever ship local-only fastlane runs from another machine, hard-code it.

---

## 11. References

- Apple — App Store Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
- Apple — App Privacy details: <https://developer.apple.com/app-store/app-privacy-details/>
- Apple — Required-reason APIs: <https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api>
- Apple — Reader App entitlement: <https://developer.apple.com/support/storekit-external-entitlement/>
- Fastlane deliver: <https://docs.fastlane.tools/actions/upload_to_app_store/>
- Fastlane App Privacy: <https://docs.fastlane.tools/actions/upload_to_app_store/#app-privacy-details>
