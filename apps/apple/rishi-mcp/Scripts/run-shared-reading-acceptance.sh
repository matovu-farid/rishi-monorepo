#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: run-shared-reading-acceptance.sh --mcp-binary PATH --mcp-client PATH --owner catalyst --participant iphone17 --sync-timeout-ms N --sha SHA --evidence-root PATH"
  exit 64
}

typeset mcp_binary="" mcp_client="" owner="" participant="" timeout_ms="" sha="" evidence_root=""
while (( $# > 0 )); do
  (( $# >= 2 )) || usage
  case "$1" in
    --mcp-binary) mcp_binary="$2" ;;
    --mcp-client) mcp_client="$2" ;;
    --owner) owner="$2" ;;
    --participant) participant="$2" ;;
    --sync-timeout-ms) timeout_ms="$2" ;;
    --sha) sha="$2" ;;
    --evidence-root) evidence_root="$2" ;;
    *) usage ;;
  esac
  shift 2
done

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || usage
typeset script_dir="${0:A:h}" repo_root git_root head
repo_root="$(cd -- "$script_dir/../../../.." && pwd -P)" || { print -u2 -- "could not derive repository root"; exit 65; }
git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" || { print -u2 -- "acceptance wrapper is not inside a git worktree"; exit 65; }
git_root="$(cd -- "$git_root" && pwd -P)" || { print -u2 -- "could not resolve git repository root"; exit 65; }
[[ "$git_root" == "$repo_root" ]] || { print -u2 -- "derived repository root does not match git worktree root"; exit 65; }
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || { print -u2 -- "could not read git HEAD"; exit 65; }
[[ "$head" == "$sha" ]] || { print -u2 -- "requested SHA does not match git HEAD"; exit 65; }

[[ -n "$evidence_root" && "$evidence_root" == /* ]] || usage
typeset mcp_evidence="$evidence_root/shared-reading-mcp-evidence.json"
typeset e2e_evidence="$evidence_root/shared-reading-apple-e2e-evidence.json"
for artifact in "$mcp_evidence" "$e2e_evidence"; do
  [[ ! -e "$artifact" && ! -L "$artifact" ]] || { print -u2 -- "refusing to overwrite existing evidence: $artifact"; exit 73; }
done

[[ -x "$mcp_binary" ]] || { print -u2 -- "MCP binary is not executable"; exit 66; }
[[ -r "$mcp_client" ]] || { print -u2 -- "MCP client is not readable"; exit 66; }
[[ "$owner" == "catalyst" && "$participant" == "iphone17" ]] || usage
[[ "$timeout_ms" == <-> && "$timeout_ms" -ge 100 && "$timeout_ms" -le 120000 ]] || usage
[[ -n "${RISHI_E2E_BOOK_IDENTIFIER:-}" ]] || { print -u2 -- "RISHI_E2E_BOOK_IDENTIFIER is required"; exit 78; }

exec bun "$mcp_client" \
  --mcp-binary "$mcp_binary" \
  --owner "$owner" \
  --participant "$participant" \
  --sync-timeout-ms "$timeout_ms" \
  --sha "$sha" \
  --evidence-root "$evidence_root" \
  --book-identifier "$RISHI_E2E_BOOK_IDENTIFIER"
