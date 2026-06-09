#!/bin/sh
set -e
# Xcode Cloud runs this after every xcodebuild action. We only act on archive builds.

if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
  echo "[ci_post_xcodebuild] skipping — action=$CI_XCODEBUILD_ACTION"
  exit 0
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/apps/apple"

# Required env vars (set as Xcode Cloud secrets per XCODE-CLOUD-SETUP.md):
#   SENTRY_AUTH_TOKEN  — Sentry user/integration token with project:releases scope
#   SENTRY_ORG_SLUG    — e.g. "fidexa"
#   SENTRY_PROJECT_SLUG — e.g. "rishi-apple"
: "${SENTRY_AUTH_TOKEN:?missing — set in Xcode Cloud secrets}"
: "${SENTRY_ORG_SLUG:?missing}"
: "${SENTRY_PROJECT_SLUG:?missing}"

bundle exec fastlane upload_dsyms \
  archive_path:"$CI_ARCHIVE_PATH" \
  sentry_org:"$SENTRY_ORG_SLUG" \
  sentry_project:"$SENTRY_PROJECT_SLUG"

echo "[ci_post_xcodebuild] dSYM upload complete"
