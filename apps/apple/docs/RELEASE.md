# Rishi for Apple — Release Runbook (v1.0)

**Audience:** matovu90@gmail.com (Apple Developer Account owner)
**Scope:** v1.0 milestone (Phase 12 plan 12-06 close).
**Last updated:** 2026-06-10

Companion docs:
- `docs/APP-STORE-METADATA.md` — metadata + privacy + submission detail (plan 12-05).
- `docs/CROSS-TEAM-BLOCKERS.md` — open worker-side dependencies that gate parts of this flow.
- `docs/XCODE-CLOUD-SETUP.md` — CI signing + API key configuration.

This runbook is the human checklist. Anything not in this file is automated by
the fastlane lanes the runbook calls.

---

## 0. Pre-flight checklist

Run through this list before invoking any release lane. Each step is
recoverable, but skipping them produces hard-to-roll-back uploads.

- [ ] `git status` is clean on `main`. `.planning/` may be dirty (gitignored).
- [ ] `cd apps/apple/Packages/RishiUIKit && swift test` passes.
- [ ] All Phase 12 plans (12-01 .. 12-05) show "● Complete" in `.planning/ROADMAP.md`.
- [ ] Cross-team blockers reviewed in [`docs/CROSS-TEAM-BLOCKERS.md`](CROSS-TEAM-BLOCKERS.md).
      Worker Ticket 2 (AASA) and Reader App entitlement statuses are the two
      that may force a decision before App Store submission.
- [ ] Reader App entitlement status checked at https://developer.apple.com →
      Account → Identifiers → org.fidexa.rishi → Capabilities. If granted,
      Phase 11's external-link billing UI is live. If pending, the app
      auto-falls-back to the text-only "manage at rishi.fidexa.org" copy.
- [ ] Version bumped (per `feedback_version_bump.md` memory — bump BEFORE
      tagging or uploading). See § 1.
- [ ] Release notes drafted (per `feedback_release_notes.md` memory — always
      include release notes when uploading). See § 2.

---

## 1. Version bump

Two version numbers live in `rishi/rishi.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION` — the user-facing "1.0.0" string (CFBundleShortVersionString).
- `CURRENT_PROJECT_VERSION` — the monotonic build number (CFBundleVersion). Apple
  rejects an upload with a non-monotonic build number against the same marketing
  version.

```bash
# example: bumping to 1.0.0 build 2
sed -i '' 's/MARKETING_VERSION = .*/MARKETING_VERSION = 1.0.0;/' rishi/rishi.xcodeproj/project.pbxproj
sed -i '' 's/CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = 2;/' rishi/rishi.xcodeproj/project.pbxproj

git add rishi/rishi.xcodeproj/project.pbxproj
git commit -m "chore(release): bump version to 1.0.0 (build 2)"
```

(For the very first 1.0 upload, `CURRENT_PROJECT_VERSION = 1` is fine.)

---

## 2. Changelog / release notes

Write the TestFlight changelog the lane will upload. Lane order of precedence:
`fastlane/changelog.txt` if present, else `git log -1 --pretty=%B`.

```bash
cat > fastlane/changelog.txt <<'EOF'
v1.0.0 — first public TestFlight build.

What's new:
- Full Electron parity on iPhone, iPad, and Mac (via Mac Catalyst).
- Library import + EPUB / PDF reader with theming and Read Aloud.
- AI Chat about the open book, plus real-time voice chat.
- Cross-device sync with silent-push wake.
- Mac Catalyst: native menu bar, ⌘O / ⌘N / ⌘F / ⌘1 / ⌘2, sidebar split-view,
  scene restoration.
- Accessibility: VoiceOver-labeled covers, toolbars, and TTS controls; Dynamic
  Type throughout; Reduce Motion respected.

Known limits (Phase 0 BOOT-07): if Apple has not yet granted the Reader App
entitlement, the Settings → Subscription row is text-only — manage your
subscription at rishi.fidexa.org.
EOF
```

App Store release notes (the production listing) live separately at
`fastlane/metadata/en-US/release_notes.txt` — see APP-STORE-METADATA.md § 1.

---

## 3. Build + upload to TestFlight (iOS)

```bash
cd apps/apple
bundle exec fastlane release_testflight
```

The lane runs `metadata_validate` first (so a malformed `name.txt` /
`keywords.txt` / `release_notes.txt` aborts before code-signing), then
`build_app` (clean Release, app-store export), then `upload_to_testflight`
with internal-tester-only distribution.

The lane returns as soon as the upload completes — Apple processing happens
asynchronously. Monitor at https://appstoreconnect.apple.com → TestFlight →
Builds. Expect 5–30 min to "Ready to Test".

If the lane fails:
- `Authentication failed` → re-verify the App Store Connect API key (see
  `XCODE-CLOUD-SETUP.md` § 5).
- `No profiles for "org.fidexa.rishi" were found` → re-run match / re-download
  the provisioning profile from developer.apple.com.

---

## 4. Build + upload to Mac App Store via TestFlight (Mac Catalyst)

```bash
cd apps/apple
bundle exec fastlane release_mac_testflight
```

Mac Catalyst goes through the same TestFlight pipeline (`platform: "osx"`).
The signed-build requirement for microphone access during voice chat
(`project_macos_mic_entitlements.md`) is satisfied because TestFlight builds
are signed.

App Store Connect treats macOS as a separate platform — confirm the macOS
build appears in TestFlight → macOS Builds (not the iOS list).

---

## 5. Real screenshots (replace placeholders)

Plan 12-06 ships placeholder 1x1 PNGs under
`fastlane/screenshots/en-US/<frame>/` so `release_app_store` can dry-run
end-to-end. BEFORE production submission, replace them with real captures.

```bash
cd apps/apple

# iPhone frames (iphone_6_9 = 6.9" Pro Max class; iphone_6_7 = 6.7" Plus class):
xcrun simctl boot "iPhone 16 Pro Max"
open -a Simulator
# launch rishi in the booted simulator
xcrun simctl io booted screenshot fastlane/screenshots/en-US/iphone_6_9/01.png  # library
xcrun simctl io booted screenshot fastlane/screenshots/en-US/iphone_6_9/02.png  # reader (themed)
xcrun simctl io booted screenshot fastlane/screenshots/en-US/iphone_6_9/03.png  # reader (TOC)
xcrun simctl io booted screenshot fastlane/screenshots/en-US/iphone_6_9/04.png  # chat
xcrun simctl io booted screenshot fastlane/screenshots/en-US/iphone_6_9/05.png  # settings

# repeat for iphone_6_7, ipad_13, ipad_11 with the matching simulators.

# Mac Catalyst — use macOS native screencapture against the running app:
screencapture -l$(osascript -e 'tell app "rishi" to id of window 1') \
  fastlane/screenshots/en-US/mac/01.png
# repeat for 02..05.

# Re-run the seeding script to confirm no placeholders remain (it skips
# any file that already exists, so this is a no-op against real captures):
./fastlane/scripts/capture_screenshots.sh
```

The five screen rotation we ship in v1.0:
1. Library (Reading Now + grid).
2. EPUB reader, dark theme, mid-chapter.
3. EPUB reader with TOC drawer open.
4. Chat about the open book (one user turn + one assistant turn visible).
5. Settings → Subscription (state depends on Reader App entitlement —
   shows tappable "Manage Subscription" if granted, text-only otherwise).

---

## 6. App Store submission (manual decision)

TestFlight is upload-only — App Store submission is a separate explicit step.

```bash
cd apps/apple
bundle exec fastlane release_app_store        # uploads iOS metadata + screenshots
bundle exec fastlane release_mac_app_store    # uploads macOS metadata + screenshots
```

Neither lane auto-submits. Sign in to App Store Connect, open the build
record, and tap "Submit for Review" when:

- Reader App entitlement status is decided (granted → external-link billing
  UI is in the binary; denied → text-only billing UI is in the binary —
  per `READER-APP-ENTITLEMENT.md`).
- Cross-team Worker Ticket 2 (AASA hosting) is live OR you have decided to
  ship Universal Links as deferred. The iOS side handles missing AASA
  gracefully — Universal Links degrade to in-app routing via the
  `rishi://` scheme.
- Cross-team Worker Ticket 3 (Silent-push APNs) is live OR sync degradation
  to manual-refresh is acceptable for v1.0.

---

## 7. Post-submission monitoring

- Watch CI for the dSYM upload to Sentry (existing `upload_dsyms` lane runs
  after every archive — see `Fastfile`).
- Monitor App Review status (target: 24–72h). Standard rejection causes
  documented in `APP-STORE-METADATA.md` § 6.
- If approved with "Pending Developer Release", verify the build is at the
  intended `MARKETING_VERSION` before releasing to all users.

---

## 8. Rollback

If a TestFlight build needs to be pulled:

```bash
# Revert the version bump and the changelog
git revert <version-bump-commit>
git revert <changelog-commit>
```

In App Store Connect:
- TestFlight builds: expire the build (TestFlight → Build → Expire).
- App Store builds: if the build is "Pending Developer Release", DO NOT
  release. If it's already live, submit a fix build with a higher
  `CURRENT_PROJECT_VERSION` rather than attempting a takedown.

---

## 9. MEMORY directives referenced

- `feedback_release_process.md` — release.sh + monitor only Release Desktop CI.
  Note: that memory targets rishi-electron. The iOS equivalent is the
  `release_testflight` lane in `fastlane/Fastfile` plus this runbook.
- `feedback_release_notes.md` — always include release notes when uploading.
- `feedback_version_bump.md` — bump version BEFORE tagging / uploading.
- `project_apple_signing.md` — Developer ID + team ID source of truth.
- `project_macos_mic_entitlements.md` — Catalyst voice chat needs signed
  builds (TestFlight builds are signed → mic works on TestFlight).
- `project_mas_auto_submit.md` — future: auto-submit MAS releases via
  App Store Connect API after the first approval lands.
