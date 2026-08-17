# Rishi iPhone Preview

This folder contains the reproducible portrait iPhone App Store preview workflow. It uses the validated local iPhone 17 Pro GLB and the installed Mockup Studio Blender MCP bridge. The render uses existing Rishi screenshots by default, so it remains useful while CoreSimulator is unavailable.

## Final artifacts

Successful renders leave exactly three generated files in `output/`:

- `rishi-iphone-preview.blend` — the single editable Blender project from the final MCP pass.
- `rishi-iphone-preview.mp4` — silent H.264 video, 886×1920 portrait, 30 fps, 13 seconds, measured at about 11.5 Mbps total.
- `rishi-iphone-preview-hero.png` — the final reader hero still.

The current pass uses the verified library and reader plates supplied through `RISHI_LIBRARY_SCREEN` and `RISHI_READER_SCREEN`. The AI Chat and Book Sharing states are native-style feature plates built by the bundled macOS Swift helper, using the app’s typography, spacing, brown theme, and controls so the story remains legible even while the simulator’s bootstrap service is unavailable. The same helper renders the brown in-screen instruction cards, keeping typography crisp even when the local FFmpeg build has no `drawtext` filter.

Temporary stills, cropped plates, MCP sockets/tokens, logs, and Xcode build data are created under `/private/tmp` and removed automatically. Blender is asked to save only the final project; the video is assembled from the temporary still renders after the MCP passes complete.

## Render

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/marketing/iphone-preview
./render.sh
./audit.sh
```

The render uses:

```text
Model:   /Users/faridmatovu/Downloads/iphone_17_pro.glb
Library: /private/tmp/rishi-current-library-new.png
Reader:  /private/tmp/rishi-current-reader-next-new.png
```

Each current simulator plate is scaled to the final `886×1920` render target with only a minimal center crop, avoiding the earlier low-resolution 680 px intermediate and second marketing upscale. The Blender session applies the validated screen-UV correction, a 95 mm product lens, AgX medium-high contrast, a reduced pixel filter, linear screen-texture interpolation, controlled reflections, and a hidden separate Blender instance so the user’s foreground app is not interrupted. The floor is excluded from the final camera view to remove the horizon edge; a small composited contact shadow keeps the phone grounded against a subtle radial studio world. The MP4 uses eight short hard-cut states: an instruction card followed by the reader, an instruction card followed by AI Chat, and an instruction card followed by the long-press menu, send-book sheet, and sent confirmation. The opening card explicitly says Rishi supports EPUBs and PDFs; the later cards show asking Rishi about the current chapter and completing a share to a recipient. Each state uses the full device frame, with the phone enlarged for readable in-screen UI. It is intentionally video-only, with no audio stream, and stays well below the 30-second App Store preview limit. The editable `.blend` remains a single final project. Override inputs with `RISHI_PHONE_MODEL`, `RISHI_LIBRARY_SCREEN`, `RISHI_READER_SCREEN`, `RISHI_MCP_BIN`, `RISHI_BLENDER`, `RISHI_FFMPEG`, `RISHI_SWIFT`, and `RISHI_OUTPUT_DIR`.

Blender 5.2 needs desktop/Metal access in this environment. If the normal shell reports exit 139 during the startup preflight or the bridge does not become reachable, repair/relaunch Blender before regenerating the 3D pass; the existing promoted artifacts remain usable and are not overwritten by a failed render.

## Optional simulator capture

```bash
./capture_simulator.sh
RISHI_RECORD_SECONDS=8 ./capture_simulator.sh
```

The script exports `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`, builds the current `rishi` scheme, installs and launches `org.fidexa.rishi` with `RISHI_UITEST=1`, waits `RISHI_SIMULATOR_WAIT_SECONDS` (default 8), and captures a screenshot to `/private/tmp/rishi-iphone-simulator.png` by default. CoreSimulatorService may still refuse connections; in that case the existing desktop plates remain the authoritative inputs.

## Model provenance

The local GLB is the validated iPhone 17 Pro asset discovered in the user’s Downloads folder. The supplied Sketchfab listing identifies the model as `Iphone 17 pro` by Ibrahim.Bhl under `CC Attribution`; retain that attribution with any App Store marketing submission and recheck the listing before publication.
