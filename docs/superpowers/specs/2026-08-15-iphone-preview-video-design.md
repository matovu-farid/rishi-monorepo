# Rishi iPhone Preview Video — Design

**Date:** 2026-08-15
**Scope:** `apps/apple/marketing/iphone-preview`
**Status:** Superseded by `2026-08-15-iphone-preview-quality-redesign-design.md`

> This was the initial landscape concept. The production workflow now uses the superseding portrait 886×1920 design, four-state reader progression, and current App Store timing/bitrate gates.

## Goal

Produce a crisp, silent 16:9 iPhone product preview for Rishi using an editable Blender scene with Rishi screenshots mapped to the phone display. The first render must work from the existing desktop screenshots even when CoreSimulator is unavailable; later renders can replace the source plates with fresh simulator captures without changing the scene or edit pipeline.

## Deliverables

- `rishi-iphone-preview.blend`: the single editable Blender scene from the final MCP pass.
- `rishi-iphone-preview.mp4`: the single final H.264, 1920×1080, 30 fps, 12–15 second silent video.
- `rishi-iphone-preview-hero.png`: the single final still from the hero angle.
- `README.md` and scripts that document and reproduce the render.

## Visual direction

- Warm off-white studio background matching Rishi’s existing iPhone library capture.
- Dark graphite/titanium phone body with rounded corners, subtle metallic edge, glass screen, and a recognizable three-lens camera bump.
- Rishi’s native iPhone library capture is the opening screen plate.
- A reader view from the 2026-08-10 native phone capture is the second screen plate. Its outer device frame is cropped before import so the 3D phone does not show a double bezel; both plates are imported in the final MCP session and packed into the saved project.
- Motion is restrained: a slow push-in on each still, a screen-content crossfade, and a final hero hold. No decorative text, narration, or OS chrome is added.

## Technical design

`mcp_render.py` is the single source of truth for scene construction. It launches the locally available Mockup Studio MCP bridge beside Blender, imports the checksum-validated local iPhone 17 Pro GLB, prepares its `Object_33` display surface, assigns the Rishi screenshot, configures a 1920×1080 Eevee render at 30 fps, keeps the bounded orbit preset in the editable scene, and saves the `.blend`. The pipeline requires the validated local GLB rather than silently substituting a different model, so production output is deterministic and does not depend on network availability.

`render.sh` validates Blender, ffmpeg, the MCP executable, the local GLB, and source images; renders separate library and reader hero stills through MCP in a unique temporary staging directory; animates and crossfades them with ffmpeg; saves one final `.blend` from the final MCP pass; and writes the final MP4 plus a hero still. Temporary stills, crops, logs, sockets, and intermediate projects are deleted after successful completion. Only the three final artifacts are stored under `apps/apple/marketing/iphone-preview/output/` and generated output is excluded from version control. MCP is intentionally not asked to encode the long delivery video, keeping Blender renders and disk usage bounded.

The live simulator capture path is separate from the Blender render. `capture_simulator.sh` selects an iPhone 17 Pro simulator, boots it, waits for CoreSimulator, builds/installs/launches the current `rishi` scheme using `/Applications/Xcode-beta.app`, and writes a native screenshot and optional screen recording. If CoreSimulator is unavailable, it exits with a clear diagnostic and the existing desktop plates remain valid inputs.

## Timing

- 0.0–2.5s: phone enters from a slightly elevated three-quarter angle.
- 2.5–6.5s: restrained push-in settles into the hero angle; library screen remains visible.
- 6.5–9.0s: crossfade to the reading screen plate while the phone holds.
- 9.0–12.25s: gentle push-in and final hold.

## Verification

The production check is the combination of a Blender background render exit code and `audit.sh` output. The audit must prove 1920×1080, 30 fps CFR, H.264 video, 12–15 seconds, no audio stream, and non-empty `.blend`, `.png`, and `.mp4` outputs. A fresh `git diff --check` and a render-log scan are also required before the result is handed off.

## Out of scope

- Editing the Rishi app or its UI.
- Uploading or publishing the video.
- Building a new Blender MCP integration; the existing local Mockup Studio bridge is used as-is.
- Publishing the downloaded model without verifying its Sketchfab attribution and license information.
