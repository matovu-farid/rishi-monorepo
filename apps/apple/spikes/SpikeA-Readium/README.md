# Spike A — Readium 3.9 on Mac Catalyst

Throwaway prototype. Validates whether `readium/swift-toolkit` 3.9+ renders an
EPUB on Mac Catalyst with a working pagination, table-of-contents sidebar, and
Decorations API. Verdict feeds Phase 6 (EPUB Reader) — see
`../../.planning/phases/00-bootstrap-spikes/SPIKE-A-REPORT.md`.

This package is **not** part of the `rishi` app target. Do not link to it from
the production app.

## Run on Mac Catalyst

```bash
# From this directory:
swift package resolve

# Then either:
#   (a) open Package.swift in Xcode, choose the "My Mac (Mac Catalyst)" run
#       destination, hit Cmd-R; or
#   (b) generate an Xcode project explicitly and build via xcodebuild:
xcodebuild \
  -scheme SpikeAReadium \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  build
```

## Validation checklist (filled into SPIKE-A-REPORT.md after a real run)

(a) Publication opens; first page renders text (not blank).
(b) Forward/back paging advances and saves a CFI-shaped position.
(c) TOC list shows chapter entries that navigate when tapped.
(d) Decorations API call returns without exception and draws a highlight.
(e) Trackpad two-finger swipe and arrow-key paging both work.

## Sample EPUB

`Resources/sample.epub` is Project Gutenberg ebook #11 — *Alice's Adventures in
Wonderland* by Lewis Carroll (public domain, ~188 KB).
Source: <https://www.gutenberg.org/ebooks/11.epub.images>
