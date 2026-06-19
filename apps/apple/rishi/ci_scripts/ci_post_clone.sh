#!/bin/sh

set -euo pipefail

# Xcode Cloud runs in a fresh environment with no saved macro trust, so Swift
# macro packages (e.g. MetaCodable) fail with "Macro ... must be enabled before
# it can be used". Disabling fingerprint validation skips the interactive
# trust dialog that cannot be answered in CI.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
