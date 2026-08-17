# Rishi iPhone App Store Preview Quality Redesign

## Goal

Replace the first-pass iPhone mockup preview with a portrait App Store-ready preview that makes the Rishi UI legible, uses physically restrained product lighting, and feels intentional rather than like a generic Blender test render.

## Evidence from the first pass

- The landscape 1920×1080 composition leaves the phone too small for readable UI text.
- The phone is pushed to the right and rotated aggressively, which makes the screen a secondary detail instead of the product message.
- The screen is overexposed and carries a broad, artificial reflection that washes out the screenshot.
- The dark floor/background is too bright at the horizon and does not separate the device with a controlled product-photography gradient.
- The first MP4 is 12.27 seconds; current App Store Connect requirements specify 15–30 seconds for app previews.

## Chosen design

Render one portrait 886×1920 composition, accepted for current iPhone app-preview targets. Keep the iPhone large and nearly front-facing with a modest three-quarter bias only where it helps the frame read as a real device. Use a dark studio field, one broad soft key, a low fill, a neutral narrow rim, and restrained grounding. Hide the finite generated floor plane whose far edge reads as an artificial horizon; the device remains separated through controlled tonal contrast rather than a visible seam. Reduce the device reflection to a soft, low-intensity neutral profile so the edge reads without painting a white or cyan veil across the display.

The video lasts about 16.5 seconds at 30 fps. A high-contrast title plate establishes the product, the reader opens on text and then advances to a highlighted passage with playback controls, and the library provides the payoff. Short crossfades separate the states instead of compositing unrelated UI over itself. A gentle scale push provides motion without sacrificing screen legibility. The saved `.blend` contains the highlighted reader pass; the MP4 combines all four plates. No text overlays, fake claims, or decorative UI are added.

## Implementation boundaries

- Keep the existing validated Sketchfab iPhone 17 Pro GLB and MCP bridge.
- Add explicit quality-profile arguments to `mcp_render.py` rather than creating alternate Blender project files.
- Render temporary stills and intermediate crops only under `/private/tmp`; atomically promote exactly one `.blend`, one `.mp4`, and one hero `.png`.
- Use portrait dimensions and 16-second timing in `render.sh` and `audit.sh`.
- Keep simulator refresh optional; the approved desktop screenshots remain valid source plates when the Xcode project cannot build under the installed beta.

## Quality gates

Every iteration must be inspected as pixels, not only metadata:

1. Screen text and controls remain readable at the 886×1920 target.
2. No broad reflection crosses the screen content; edge highlights remain plausible.
3. The device has a visible contact relationship with the background and no blown-out white body.
4. The phone is fully inside frame with balanced margins and no distracting horizon seam.
5. The MP4 is H.264, 886×1920, 30 fps CFR, with a restrained ambient/chime bed, stereo AAC, short crossfades, and 15–30 seconds.
6. An independent adversarial reviewer must find no Critical or High visual issues; Medium findings are fixed where practical and re-reviewed.

## Review loop

After the first revised render, commission an independent visual review focused on realism, readability, composition, App Store suitability, and cleanup. Fix every Critical/High finding, rerender, and repeat until the reviewer returns PASS or PASS WITH NOTES with no Critical/High findings.
