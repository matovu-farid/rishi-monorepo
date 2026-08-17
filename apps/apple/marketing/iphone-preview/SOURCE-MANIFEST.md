# Preview source manifest

The render is intentionally local-first: it uses the user’s installed Blender/MCP and the verified iPhone 17 Pro simulator captures under `/private/tmp` rather than copying large source assets into this repository. Set the environment overrides documented in `README.md` when reproducing on another machine.

| Input | Default | SHA-256 |
| --- | --- | --- |
| iPhone 17 Pro model | `/Users/faridmatovu/Downloads/iphone_17_pro.glb` — Sketchfab `Iphone 17 pro` by Ibrahim.Bhl, `CC Attribution` | `18c28a17c58cfe241ec902175c998d778560cb26e694231c77c7c2b06df77379` |
| Library screen | `/private/tmp/rishi-current-library-new.png` | `2fbd8a9d09ccb1116a0d5b5c76935b66518f656f4971317f4d43eaf90c30a6f2` |
| Reader plate | `/private/tmp/rishi-current-reader-next-new.png` | `49cdb987466fcc611dc6d2ae37bd0806a16f29e196fa3117f79c3498534506c1` |
| Story plate renderer | `apps/apple/marketing/iphone-preview/story_plate.swift` | generated with the local Xcode Swift toolchain |
| Mockup Studio MCP | `/Users/faridmatovu/projects/mockup-studio/.build/out/Products/Release/MockupStudioMCP` | `81e92011f720ef2c7a47007d32ebc674c357ffc3c5c9779fa415a7000be7001e` |
| Blender add-on scene adapter | `/Users/faridmatovu/projects/mockup-studio/blender-addon/mockup_studio/blender_scene.py` | `36ec19cb55c10bc21b9aa0f6032c3051d17947b53176697f924125893eaf5860` |

The add-on checksum is a provenance marker for the installed renderer, not a vendored dependency. `render.sh` creates all crops, sockets, logs, and intermediate renders under `/private/tmp`; only the final `.blend`, `.mp4`, and hero `.png` are promoted to `output/`. The final story is 13 seconds, 886×1920, 30 fps, H.264, and has no audio stream.
