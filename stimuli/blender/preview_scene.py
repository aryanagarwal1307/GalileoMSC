"""Save one scripted stimulus as an editable Blender scene without rendering PNGs.

Run from the repository root with Blender's Python; arguments follow ``--``.
The saved .blend is a preview. Final stimuli are still built from the Python
renderer and trajectory JSON.
"""

import argparse
import importlib.util
from pathlib import Path
import sys

import bpy

spec = importlib.util.spec_from_file_location(
    "render_stimuli", Path(__file__).with_name("render_stimuli.py"))
renderer = importlib.util.module_from_spec(spec)
previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
try:
    spec.loader.exec_module(renderer)
finally:
    sys.dont_write_bytecode = previous
renderer.bpy = bpy


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trajectory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--png", type=Path, help="Also render the selected frame to this PNG")
    parser.add_argument("--frame", type=int, default=0,
                        help="Zero-based trajectory frame to show when the file opens")
    parser.add_argument("--resolution", type=int, nargs=2, default=(1920, 1080),
                        metavar=("WIDTH", "HEIGHT"), help="Preview dimensions in pixels")
    args = parser.parse_args(argv)

    renderer.require(all(v > 0 for v in args.resolution), "Resolution must be positive")
    trajectory = renderer.load_trajectory(args.trajectory.resolve())
    renderer.require(0 <= args.frame < len(trajectory["frames"]),
                     f"Frame must be in 0..{len(trajectory['frames']) - 1}")
    settings = argparse.Namespace(engine="EEVEE", resolution=args.resolution)
    scene, objects = renderer.configure_scene(trajectory, settings)
    renderer.import_animation(scene, objects, trajectory["frames"])
    renderer.verify_replay(scene, objects, trajectory["frames"])
    scene.frame_set(args.frame + 1)

    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.region_3d.view_perspective = "CAMERA"
                area.spaces.active.shading.type = "MATERIAL"

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    print(f"Saved editable preview: {output}")
    print(f"Open in Blender; timeline frame {args.frame + 1} = trajectory frame {args.frame}.")
    if args.png:
        png = args.png.resolve()
        png.parent.mkdir(parents=True, exist_ok=True)
        scene.render.filepath = str(png)
        bpy.ops.render.render(write_still=True)
        print(f"Rendered selected frame: {png}")


if __name__ == "__main__":
    main()
