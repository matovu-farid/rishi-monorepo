#!/usr/bin/env bash
# IAP-09: anti-steering CI guard. Greps Swift sources for forbidden strings
# that would violate App Review Guideline 3.1.1 (external billing links,
# steering language, Stripe URLs, etc.). See 13-RESEARCH.md Section 7.1.
#
# Modes:
#   (default)            — strict; any forbidden match exits 1.
#   --allow-known-legacy — Wave-0 mode; BillingPortalService and
#                          /api/billing/portal are downgraded to WARN.
#                          Wave 2 removes those usages and we drop this flag.
#   --self-test          — proves the grep mechanics catch a synthetic
#                          forbidden string in a tempdir. Always strict.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# Script lives at apps/apple/scripts/. The "apps/apple" root for scan_root
# is the parent directory; scan_root walks apps/apple/Packages/*/Sources +
# apps/apple/rishi/rishi based off the path it's given.
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
MODE="strict"
SELF_TEST=0
case "${1:-}" in
    --allow-known-legacy) MODE="legacy" ;;
    --self-test)          SELF_TEST=1   ;;
    "")                   ;;
    *) echo "usage: $0 [--allow-known-legacy|--self-test]"; exit 2 ;;
esac

# Patterns that are ALWAYS forbidden — even in --allow-known-legacy mode.
# Promote items out of LEGACY_PATTERNS into here once Wave 2 removes them.
PATTERNS=(
    'rishi\.fidexa\.org/subscribe'
    'manage at rishi'
    'manage your subscription at'
    'https://buy\.itunes\.apple\.com'
    'unsafePayloadValue'
)

# Patterns currently present in Phase-11 fallback code (PaywallView text-only
# CTA, BillingAPI.swift Stripe portal endpoint, BillingPortalService actor).
# Wave 2 removes every occurrence and we promote them into PATTERNS at that
# point. Strict mode (no flag) still fails on these — used by the final pre-
# submission gate after Wave 2.
LEGACY_PATTERNS=(
    'BillingPortalService'
    '/api/billing/portal'
    '[Ss]ubscribe at'
    'stripe\.com'
)

# Allow-list (non-billing links permitted in source; do NOT count as steering).
ALLOW_PATTERNS=(
    'appstoreconnect://'
    'rishi\.fidexa\.org/terms'
    'rishi\.fidexa\.org/privacy'
)

# scan PATTERN ROOT_DIR — print matches; return non-empty hits via stdout.
grep_pattern() {
    local p="$1"
    local base="$2"
    local raw=""
    # Iterate package source roots + the main app sources. Ignore test trees
    # (per plan: tests intentionally exercise legacy/test fixtures).
    local roots=()
    for pkg in "$base"/apps/apple/Packages/*/Sources; do
        [[ -d "$pkg" ]] && roots+=("$pkg")
    done
    [[ -d "$base/apps/apple/rishi/rishi" ]] && roots+=("$base/apps/apple/rishi/rishi")
    [[ ${#roots[@]} -eq 0 ]] && return 0
    raw="$(grep -rInE "$p" --include='*.swift' "${roots[@]}" 2>/dev/null || true)"
    # Strip allow-listed lines.
    for a in "${ALLOW_PATTERNS[@]}"; do
        if [[ -n "$raw" ]]; then
            raw="$(printf '%s\n' "$raw" | grep -vE "$a" || true)"
        fi
    done
    printf '%s' "$raw"
}

scan_root() {
    local base="$1"
    local rc=0

    # Strict patterns always fail on match.
    for p in "${PATTERNS[@]}"; do
        local hits
        hits="$(grep_pattern "$p" "$base")"
        if [[ -n "$hits" ]]; then
            echo "FAIL: pattern '$p' matched:"
            echo "$hits"
            rc=1
        fi
    done

    # Legacy patterns: fail in strict mode, warn in legacy mode.
    for p in "${LEGACY_PATTERNS[@]}"; do
        local hits
        hits="$(grep_pattern "$p" "$base")"
        if [[ -n "$hits" ]]; then
            if [[ "$MODE" == "strict" ]]; then
                echo "FAIL: legacy pattern '$p' matched (remove in Wave 2):"
                echo "$hits"
                rc=1
            else
                echo "WARN (known-legacy, removed in Wave 2): '$p'"
                printf '%s\n' "$hits" | head -3
            fi
        fi
    done

    return $rc
}

if [[ "$SELF_TEST" -eq 1 ]]; then
    TMP="$(mktemp -d)"
    SYNTH_DIR="$TMP/apps/apple/Packages/Synthetic/Sources/Synthetic"
    mkdir -p "$SYNTH_DIR"
    printf 'let url = "Subscribe at rishi.fidexa.org/subscribe"\n' \
        > "$SYNTH_DIR/Bad.swift"
    # Run scan against the synthetic root.
    if scan_root "$TMP" >/tmp/anti-steering-selftest.log 2>&1; then
        echo "self-test FAILED: synthetic forbidden string was not detected"
        cat /tmp/anti-steering-selftest.log
        rm -rf "$TMP" /tmp/anti-steering-selftest.log
        exit 1
    fi
    # Confirm the offending line was printed.
    if ! grep -q "Subscribe at rishi.fidexa.org/subscribe" /tmp/anti-steering-selftest.log; then
        echo "self-test FAILED: scan did not print the offending line"
        cat /tmp/anti-steering-selftest.log
        rm -rf "$TMP" /tmp/anti-steering-selftest.log
        exit 1
    fi
    rm -rf "$TMP" /tmp/anti-steering-selftest.log
    echo "self-test PASSED: forbidden pattern detection works"
    exit 0
fi

scan_root "$ROOT"
