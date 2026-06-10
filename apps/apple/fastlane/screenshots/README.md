# Fastlane Screenshots — Rishi for Apple

This directory holds the App Store / Mac App Store screenshots that `fastlane deliver` uploads when the `release_app_store` or `release_mac_app_store` lanes run.

**No real screenshots ship in plan 12-05 — they land in plan 12-06 after the Phase 12 a11y + Catalyst-polish work is visible in the UI.** This README documents the required device frames, paths, naming, and how to produce 1px placeholder PNGs so the lanes can dry-run before real captures exist.

---

## Required device frames (en-US)

App Store Connect requires at least one screenshot per supported device class. Apple now derives smaller-display sizes from the largest provided frame per family, so the practical minimum set is six frames:

| Device class | Display size | Native dimensions (px) | Path (en-US) |
| --- | --- | --- | --- |
| iPhone 6.9" | iPhone 16 Pro Max | 1320 × 2868 | `en-US/iphone_6_9/{01..05}.png` |
| iPhone 6.7" | iPhone 14 Plus / 15 Plus | 1290 × 2796 | `en-US/iphone_6_7/{01..05}.png` |
| iPhone 6.5" | iPhone XS Max / 11 Pro Max | 1242 × 2688 | `en-US/iphone_6_5/{01..05}.png` |
| iPad 13" | iPad Pro M4 13" | 2064 × 2752 | `en-US/ipad_13/{01..05}.png` |
| iPad 11" | iPad Pro 11" / iPad Air | 1668 × 2388 | `en-US/ipad_11/{01..05}.png` |
| Mac | Mac App Store screenshot | 1280 × 800 min, 2880 × 1800 preferred | `en-US/mac/{01..05}.png` |

Up to 10 screenshots per device class are accepted. We ship five per class:

1. Library grid (Reading Now + grid)
2. PDF reader (page + toolbar + highlight color picker)
3. EPUB reader (font/theme controls)
4. Chat (book-grounded conversation)
5. Mac sidebar / Catalyst-specific (Mac frame only — others substitute Settings / Voice Chat)

## File naming

`fastlane deliver` reads screenshots in lexical order, so name them `01_*.png` … `10_*.png`. Apple shows them to reviewers and on the product page in the same order.

## Placeholder PNGs (for dry-run uploads only)

The two release lanes accept `SKIP_SCREENSHOTS=1` to bypass the screenshot upload entirely. That is the path plan 12-05 uses. If you instead need to exercise the upload code path before real captures exist, drop 1×1 placeholder PNGs into each directory:

```bash
# macOS — uses built-in sips
mkdir -p en-US/iphone_6_9 en-US/iphone_6_7 en-US/iphone_6_5 \
         en-US/ipad_13 en-US/ipad_11 en-US/mac

# create a 1×1 black PNG from /dev/null via sips' empty-canvas mode
sips -s format png -s formatOptions normal --resampleHeightWidth 1 1 \
     /System/Library/Desktop\ Pictures/Solid\ Colors/Black.png \
     --out /tmp/_placeholder.png

for dir in en-US/iphone_6_9 en-US/iphone_6_7 en-US/iphone_6_5 \
           en-US/ipad_13 en-US/ipad_11 en-US/mac; do
  for i in 01 02 03 04 05; do
    cp /tmp/_placeholder.png "$dir/${i}_placeholder.png"
  done
done
```

App Store Connect will REJECT placeholders at submission time — never let a placeholder reach the submit-for-review step. The `SKIP_SCREENSHOTS=1` flag in plan 12-05's lanes is the safe path.

## Capture playbook (executes in plan 12-06)

Plan 12-06 (`12-06-distribution-and-release-handoff`) drives real captures:

1. Boot each simulator device matching the table above plus a Mac Catalyst run.
2. Seed the simulator with the bundled sample book + a deterministic chat fixture.
3. Use the `xcrun simctl io <device> screenshot` command for iOS frames and Xcode's built-in capture for Mac.
4. Strip device chrome with `fastlane frameit` (optional — Apple no longer requires bezels).
5. Commit captures under the paths above and re-run `fastlane release_app_store`.

## Reference

- Apple's current device + resolution matrix: <https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications>
- Fastlane deliver screenshot docs: <https://docs.fastlane.tools/actions/upload_to_app_store/#screenshots>
