#!/usr/bin/env python3
"""Render one Rishi screen plate through the local Mockup Studio Blender MCP."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import selectors
import socket
import subprocess
import sys
import time
from pathlib import Path


SKETCHFAB_URL = "https://sketchfab.com/3d-models/iphone-17-pro-4aeeeb41f9d14f96bb3f2589edc3edac"
ADDON_PATH = Path("/Users/faridmatovu/projects/mockup-studio/blender-addon")
APPROVED_MODEL_SHA256 = {
    "acecb257d2d21cfeb840f5aea75d8fe1f084ab9027dbbd4cc108586fc909b7ba",
    "18c28a17c58cfe241ec902175c998d778560cb26e694231c77c7c2b06df77379",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wait_for_line(process: subprocess.Popen[str], timeout: float = 240.0) -> str:
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout):
            raise RuntimeError(f"MCP response timed out; exit_code={process.poll()}")
        line = process.stdout.readline()
        if not line:
            raise RuntimeError(f"MCP exited without a response; exit_code={process.poll()}")
        return line
    finally:
        selector.close()


def call_tool(process: subprocess.Popen[str], request_id: int, name: str, arguments: dict) -> dict:
    request = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    response = json.loads(wait_for_line(process))
    if "error" in response:
        raise RuntimeError(f"MCP {name} failed: {response['error']}")
    result = response.get("result")
    if not isinstance(result, dict) or result.get("isError"):
        raise RuntimeError(f"MCP {name} returned an error: {result}")
    return result


def wait_for_bridge(socket_path: Path, token_path: Path, timeout: float = 30.0, process: subprocess.Popen[str] | None = None) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if token_path.is_file() and socket_path.exists() and token_path.read_text(encoding="utf-8").strip():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(0.5)
                    client.connect(str(socket_path))
                return
            except OSError:
                pass
        time.sleep(0.1)
    detail = ""
    if process is not None and process.poll() is not None:
        detail = f"; Blender exited with code {process.returncode}: {process.stderr.read()[-1200:] if process.stderr else ''}"
    raise RuntimeError(f"Blender bridge did not become reachable at {socket_path}{detail}")


def decode_image(result: dict, destination: Path) -> int:
    image = next((item for item in result.get("content", []) if item.get("type") == "image"), None)
    if not image or not image.get("data"):
        raise RuntimeError("MCP render did not return inline PNG content")
    data = base64.b64decode(image["data"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return len(data)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=Path("/Users/faridmatovu/Downloads/iphone_17_pro.glb"))
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--extra-media", type=Path, action="append")
    parser.add_argument("--mcp", type=Path, default=Path("/Users/faridmatovu/projects/mockup-studio/.build/out/Products/Release/MockupStudioMCP"))
    parser.add_argument("--blender", type=Path, default=Path("/Applications/Blender.app/Contents/MacOS/Blender"))
    parser.add_argument("--socket-dir", type=Path, required=True)
    parser.add_argument("--video-output", type=Path)
    parser.add_argument("--preview-output", type=Path, required=True)
    parser.add_argument("--project-output", type=Path)
    parser.add_argument("--width", type=int, default=886)
    parser.add_argument("--height", type=int, default=1920)
    parser.add_argument("--duration", type=float, default=6.5)
    parser.add_argument("--frame-rate", type=float, default=30.0)
    parser.add_argument("--hero-time", type=float, default=4.5)
    parser.add_argument("--animation-preset", choices=("none", "orbit", "float"), default="none")
    parser.add_argument("--camera-focal-length", type=float, default=95.0)
    parser.add_argument("--camera-aperture", type=float, default=16.0)
    parser.add_argument("--camera-focus-distance", type=float, default=5.7)
    parser.add_argument("--lighting-intensity", type=float, default=260.0)
    parser.add_argument("--shadow-style", choices=("natural", "soft", "hard", "none"), default="soft")
    parser.add_argument("--background-primary", default="#C9C6C2")
    parser.add_argument("--background-secondary", default="#E8E5E0")
    parser.add_argument("--reflection-style", choices=("natural", "soft", "none"), default="soft")
    parser.add_argument("--reflection-environment", choices=("studio", "office", "beach", "none", "custom"), default="custom")
    parser.add_argument("--reflection-tint", default="#F3F1EE")
    parser.add_argument("--reflection-angle", type=float, default=-18.0)
    parser.add_argument("--reflection-width", type=float, default=0.6)
    parser.add_argument("--reflection-intensity", type=float, default=0.025)
    parser.add_argument("--device-roughness", type=float, default=0.28)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    extra_media_paths = args.extra_media or []
    for path in (args.model, args.media, args.mcp, args.blender, ADDON_PATH, *extra_media_paths):
        if path is not None and not path.exists():
            raise SystemExit(f"missing MCP render input: {path}")
    if (args.width, args.height) not in {(886, 1920), (1920, 886)} or args.frame_rate != 30.0:
        raise SystemExit("production MCP renders must be 886x1920 or 1920x886 at 30 fps")
    if args.duration <= 0 or not 0 <= args.hero_time <= args.duration:
        raise SystemExit("invalid duration or hero time")

    model_hash = sha256(args.model)
    if model_hash not in APPROVED_MODEL_SHA256:
        raise SystemExit(f"unapproved iPhone model checksum: {model_hash}")

    args.socket_dir.mkdir(parents=True, exist_ok=True)
    user = os.environ.get("USER", "unknown").replace("/", "-")
    socket_path = args.socket_dir / f"mockup-studio-blender-{user}.sock"
    token_path = args.socket_dir / f"mockup-studio-blender-{user}.token"
    socket_path.unlink(missing_ok=True)
    token_path.unlink(missing_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(args.socket_dir)
    correction_code = (
        "def rishi_scene_correction():\n"
        "    obj=bpy.data.objects.get('Object_33')\n"
        "    layer=obj.data.uv_layers.get('MS_SCREEN_UV') if obj else None\n"
        "    if layer and obj and not obj.get('rishi_uv_correction_applied'):\n"
        "        for loop in layer.data:\n"
        "            u,v=loop.uv.x,loop.uv.y\n"
        "            loop.uv.x=v\n"
        "            loop.uv.y=u\n"
        "        obj['rishi_uv_correction_applied']=True\n"
        "    scene=bpy.context.scene\n"
        "    floor=bpy.data.objects.get('MS_FLOOR')\n"
        "    if floor:\n"
        "        floor.hide_render=True\n"
        "        floor.hide_viewport=True\n"
        "        material=floor.data.materials[0] if floor.data.materials else None\n"
        "        shader=material.node_tree.nodes.get('Principled BSDF') if material and material.use_nodes else None\n"
        "        if shader:\n"
        "            shader.inputs['Base Color'].default_value=(0.52,0.51,0.50,1.0)\n"
        "            shader.inputs['Roughness'].default_value=0.82\n"
        "    screen_material=bpy.data.materials.get('MS_SCREEN_CONTENT')\n"
        "    screen_nodes=screen_material.node_tree.nodes if screen_material and screen_material.use_nodes else []\n"
        "    for node in screen_nodes:\n"
        "        if node.bl_idname == 'ShaderNodeTexImage':\n"
        "            node.interpolation='Linear'\n"
        "    screen_shader=screen_nodes.get('Principled BSDF') if screen_nodes else None\n"
        "    if screen_shader:\n"
        "        screen_shader.inputs['Roughness'].default_value=0.10\n"
        "        if screen_shader.inputs.get('Specular IOR Level'):\n"
        "            screen_shader.inputs['Specular IOR Level'].default_value=0.16\n"
        "        if screen_shader.inputs.get('Emission Strength'):\n"
        "            screen_shader.inputs['Emission Strength'].default_value=0.30\n"
        "    world=scene.world\n"
        "    world_background=world.node_tree.nodes.get('Background') if world and world.use_nodes else None\n"
        "    if world_background:\n"
        "        world_background.inputs['Strength'].default_value=0.55\n"
        "    scene.render.resolution_percentage=100\n"
        "    if hasattr(scene.render, 'filter_size'):\n"
        "        scene.render.filter_size=0.10\n"
        "    try:\n"
        "        scene.view_settings.view_transform='AgX'\n"
        "        scene.view_settings.look='AgX - Medium High Contrast'\n"
        "        scene.view_settings.exposure=0.65\n"
        "    except Exception:\n"
        "        pass\n"
        "    try:\n"
        "        scene.render.image_settings.color_depth='16'\n"
        "    except Exception:\n"
        "        pass\n"
        "    camera=scene.camera\n"
        "    if layer and floor and camera and scene.get('ms_camera_framed') and scene.get('ms_background_json') and scene.get('ms_appearance_json') and scene.get('ms_timeline_json') and not scene.get('rishi_camera_composition_applied'):\n"
        "        from mathutils import Vector\n"
        "        meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and not obj.hide_render and not obj.get('ms_generated')]\n"
        "        if meshes:\n"
        "            corners=[obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box]\n"
        "            minimum=Vector((min(point.x for point in corners),min(point.y for point in corners),min(point.z for point in corners)))\n"
        "            maximum=Vector((max(point.x for point in corners),max(point.y for point in corners),max(point.z for point in corners)))\n"
        "            center=(minimum+maximum)*0.5\n"
        "            offset=camera.location-center\n"
        "            camera.location=center+Vector((offset.x*0.28,offset.y*0.80,offset.z*0.34))\n"
        "            camera.rotation_euler=(center-camera.location).to_track_quat('-Z','Y').to_euler()\n"
        "            scene['rishi_camera_composition_applied']=True\n"
        "            return None\n"
        "    return 0.05 if not (layer and floor and scene.get('rishi_camera_composition_applied')) else None\n"
    )
    render_marker = f"RISHI_MCP_{os.getpid()}_{int(time.time() * 1000)}"
    expression = (
        f"{render_marker}=True; "
        f"import sys; sys.path.insert(0, {str(ADDON_PATH)!r}); "
        "import mockup_studio; mockup_studio.register(); import bpy; "
        f"exec({correction_code!r}); bpy.app.timers.register(rishi_scene_correction, first_interval=0.1)"
    )
    # The add-on needs Blender's UI context, but the user should not lose
    # desktop focus. Invoke the executable directly because this installation's
    # app bundle is not registered correctly with LaunchServices. Blender's
    # no-window-focus flag preserves the bridge without activating the editor.
    blender = subprocess.Popen([str(args.blender), "--no-window-focus", "--python-expr", expression], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
    mcp: subprocess.Popen[str] | None = None
    try:
        wait_for_bridge(socket_path, token_path, process=blender)
        mcp = subprocess.Popen([str(args.mcp), "--live", "--socket", str(socket_path), "--token", str(token_path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
        mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "rishi-iphone-preview", "version": "1.0"}}}) + "\n")
        mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n")
        mcp.stdin.flush()
        initialize = json.loads(wait_for_line(mcp))
        if "error" in initialize:
            raise RuntimeError(f"MCP initialize failed: {initialize['error']}")

        request_id = 2
        call_tool(mcp, request_id, "create_project", {"title": "Rishi iPhone Preview"}); request_id += 1
        imported = call_tool(mcp, request_id, "import_asset", {"path": str(args.model), "provenance": {"asset_id": "iphone_17_pro", "source_url": SKETCHFAB_URL, "creator": "Ibrahim.Bhl", "license_name": "CC Attribution", "attribution": "Iphone 17 pro 3D model by Ibrahim.Bhl — Sketchfab", "local_path": str(args.model), "sha256": model_hash}}); request_id += 1
        object_id = imported["structuredContent"]["object_id"]
        inspection = call_tool(mcp, request_id, "inspect_asset", {"asset_id": "iphone_17_pro"}); request_id += 1
        diagnostics = inspection.get("structuredContent", {}).get("diagnostics", {})
        if diagnostics.get("profile_id") != "apple.iphone-17-pro.sketchfab" or diagnostics.get("profile_status") != "validated":
            raise RuntimeError(f"validated iPhone profile not selected: {diagnostics}")
        prepared = call_tool(mcp, request_id, "prepare_asset", {"asset_id": "iphone_17_pro", "display_surface": "Object_33"}); request_id += 1
        prepared_content = prepared.get("structuredContent", {})
        if prepared_content.get("status") != "prepared" or prepared_content.get("display_surface") != "Object_33":
            raise RuntimeError(f"unexpected display preparation: {prepared_content}")

        for extra_media_path in extra_media_paths:
            call_tool(mcp, request_id, "import_media", {"path": str(extra_media_path), "linked": False}); request_id += 1
        media = call_tool(mcp, request_id, "import_media", {"path": str(args.media), "linked": False}); request_id += 1
        media_id = media["structuredContent"]["media_id"]
        call_tool(mcp, request_id, "assign_display", {"object_id": object_id, "media_id": media_id, "mapping": {"fit": "cover", "scale": 1.0, "offset_x": 0.0, "offset_y": 0.0}}); request_id += 1
        time.sleep(0.25)
        call_tool(mcp, request_id, "configure_scene", {"settings": {"engine": "BLENDER_EEVEE_NEXT", "width": args.width, "height": args.height, "transparent_background": False}}); request_id += 1
        # The validated Sketchfab profile faces the camera along -Y. Set the
        # longer product lens before framing so the addon solves composition
        # against the final perspective, preserving a near-front-on hero view.
        call_tool(mcp, request_id, "set_camera", {
            "focal_length": args.camera_focal_length,
            "aperture": args.camera_aperture,
            "focus_distance": args.camera_focus_distance,
            "depth_of_field_enabled": False,
        }); request_id += 1
        call_tool(mcp, request_id, "frame_all", {}); request_id += 1
        # Apply the editorial product push after framing. Framing first keeps
        # the phone centered and front-facing; this deterministic focal-length
        # change makes the app UI more legible without changing the angle.
        call_tool(mcp, request_id, "set_camera", {
            "focal_length": args.camera_focal_length * 1.18,
            "aperture": args.camera_aperture,
            "focus_distance": args.camera_focus_distance,
            "depth_of_field_enabled": False,
        }); request_id += 1
        call_tool(mcp, request_id, "set_background", {"kind": "gradient", "primary_hex": args.background_primary, "secondary_hex": args.background_secondary, "blur": 0.0}); request_id += 1
        call_tool(mcp, request_id, "set_lighting", {"intensity": args.lighting_intensity, "fill_intensity": 84.0, "ambient_strength": 0.14, "environment": "custom", "environment_strength": 0.24, "environment_tint_hex": "#F3F1EE", "shadow_style": args.shadow_style, "position": {"x": -1.8, "y": 3.0, "z": 4.5}}); request_id += 1
        call_tool(mcp, request_id, "set_appearance", {"object_id": object_id, "roughness": args.device_roughness, "reflection_style": args.reflection_style, "reflection_environment": args.reflection_environment, "reflection_tint_hex": args.reflection_tint, "reflection_angle": args.reflection_angle, "reflection_width": args.reflection_width, "reflection_intensity": args.reflection_intensity}); request_id += 1
        call_tool(mcp, request_id, "set_timeline", {"duration": args.duration, "frame_rate": args.frame_rate}); request_id += 1
        if args.animation_preset != "none":
            call_tool(mcp, request_id, "set_animation_preset", {"preset": args.animation_preset, "duration": args.duration, "frame_rate": args.frame_rate}); request_id += 1
        time.sleep(0.25)
        preview = call_tool(mcp, request_id, "render_preview", {"width": args.width, "height": args.height, "time": args.hero_time, "transparent_background": False}); request_id += 1
        preview_bytes = decode_image(preview, args.preview_output)
        video = None
        if args.video_output:
            video = call_tool(mcp, request_id, "export_video", {"path": str(args.video_output), "width": args.width, "height": args.height, "frame_rate": args.frame_rate, "duration": args.duration, "transparent_background": False}); request_id += 1
            if not args.video_output.is_file() or args.video_output.stat().st_size == 0:
                raise RuntimeError("MCP video export did not create a non-empty file")
        if args.project_output:
            call_tool(mcp, request_id, "save_project", {"path": str(args.project_output)})
            if not args.project_output.is_file() or args.project_output.stat().st_size == 0:
                raise RuntimeError("MCP save_project did not create a non-empty project")
        print(json.dumps({"model_sha256": model_hash, "display_surface": prepared_content.get("display_surface"), "inspection_status": inspection.get("structuredContent", {}).get("status"), "preview_bytes": preview_bytes, "video": video.get("structuredContent", {}) if video else None, "video_output": str(args.video_output) if args.video_output else None, "preview_output": str(args.preview_output), "project_output": str(args.project_output) if args.project_output else None, "width": args.width, "height": args.height, "frame_rate": args.frame_rate, "duration": args.duration}, sort_keys=True))
        return 0
    finally:
        if mcp is not None:
            mcp.terminate()
            try: mcp.wait(timeout=8)
            except subprocess.TimeoutExpired: mcp.kill()
        blender.terminate()
        try: blender.wait(timeout=8)
        except subprocess.TimeoutExpired: blender.kill()
        subprocess.run(["pkill", "-TERM", "-f", render_marker], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        socket_path.unlink(missing_ok=True)
        token_path.unlink(missing_ok=True)


if __name__ == "__main__":
    try: raise SystemExit(main())
    except Exception as error:
        print(f"mcp_render failed: {error}", file=sys.stderr)
        raise SystemExit(1)
