#!/bin/sh
set -e
# Xcode Cloud runs this once per build after `git clone`. Working directory
# is $CI_PRIMARY_REPOSITORY_PATH. Apple's container has Homebrew + Ruby preinstalled.

# Install Bundler and lock to the Gemfile.
gem install bundler --no-document
cd "$CI_PRIMARY_REPOSITORY_PATH/apps/apple"
bundle install --path vendor/bundle

# sentry-cli (used in post-xcodebuild for dSYM upload).
brew install getsentry/tools/sentry-cli || true

echo "[ci_post_clone] done"
