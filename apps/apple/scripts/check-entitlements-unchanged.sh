#!/usr/bin/env bash
# Guards IAP-13: rishi.entitlements must NOT regain the deprecated StoreKit-1
# `com.apple.developer.in-app-payments` key. StoreKit 2 IAP requires no
# entitlement; adding the key causes App Review confusion ("declared but
# unused"). See 13-RESEARCH.md Section 11 Pitfall 10.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# Script lives at apps/apple/scripts/. Entitlements live at
# apps/apple/rishi/rishi/rishi.entitlements relative to it.
ENT="$SCRIPT_DIR/../rishi/rishi/rishi.entitlements"

if [[ ! -f "$ENT" ]]; then
    echo "FAIL: $ENT not found"
    exit 1
fi

if grep -q "com\.apple\.developer\.in-app-payments" "$ENT"; then
    echo "FAIL: com.apple.developer.in-app-payments is deprecated (StoreKit 1 era)."
    echo "      StoreKit 2 IAP works without any entitlement. Remove the key."
    echo "      See 13-RESEARCH.md Section 11 Pitfall 10."
    exit 1
fi

echo "OK: rishi.entitlements is clean (no deprecated in-app-payments key)."
exit 0
