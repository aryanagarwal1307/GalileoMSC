"""Render unchanged production scenes, extracting the table blocks at native scale.

Run from the repository root:
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
    --python-exit-code 1 --python stimuli/blender/render_materials.py
Requires the existing trajectories and the production Blender version (5.2.2).
"""

import argparse
from pathlib import Path
import subprocess
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_stimuli as renderer

renderer.bpy = bpy
OUTPUT = renderer.ROOT / "experiment/assets/materials"
SOURCES = {"wood": "brick_to_wood", "brick": "wood_to_brick", "metal": "brick_to_metal"}


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for material, source in SOURCES.items():
        data = renderer.load_trajectory(
            renderer.ROOT / f"stimuli/generated/trajectories/{source}_congruent.json")
        scene, objects = renderer.configure_scene(
            data, argparse.Namespace(engine="EEVEE", resolution=(1920, 1080)))
        renderer.import_animation(scene, objects, data["frames"])
        scene.frame_set(1)
        block = objects["table_object"]
        assert data["objects"]["table_object"]["material"] == material
        # Keep every scene object for identical lighting, shadows and reflections.
        # Cryptomatte only extracts the visible block after the scene is rendered.
        scene.view_layers[0].use_pass_cryptomatte_object = True
        tree = bpy.data.node_groups.new("Extract production block", "CompositorNodeTree")
        scene.compositing_node_group = tree
        scene.render.use_compositing = True
        tree.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        layers = tree.nodes.new("CompositorNodeRLayers")
        matte = tree.nodes.new("CompositorNodeCryptomatteV2")
        matte.scene = scene
        matte.layer_name = scene.view_layers[0].name + ".CryptoObject"
        matte.matte_id = block.name
        tree.links.new(layers.outputs["Image"], matte.inputs["Image"])
        # Crop without rescaling; all three blocks share the same pose/geometry.
        corners = [world_to_camera_view(scene, scene.camera, block.matrix_world @ Vector(c))
                   for c in block.bound_box]
        x = round((min(c.x for c in corners) + max(c.x for c in corners)) * 1920 / 2 - 192)
        y = round((min(c.y for c in corners) + max(c.y for c in corners)) * 1080 / 2 - 192)
        assert all(x < c.x * 1920 < x + 384 and y < c.y * 1080 < y + 384 for c in corners)
        crop = tree.nodes.new("CompositorNodeCrop")
        for key, value in {"X": x, "Y": y, "Width": 384, "Height": 384}.items():
            crop.inputs[key].default_value = value
        tree.links.new(matte.outputs["Image"], crop.inputs["Image"])
        final = tree.nodes.new("NodeGroupOutput")
        tree.links.new(crop.outputs["Image"], final.inputs["Image"])
        scene.render.image_settings.color_mode = "RGBA"
        path = OUTPUT / f"{material}.png"
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True)
        # Blender centers the cropped compositor output on a full-size canvas.
        # macOS sips removes that transparent padding without resampling.
        subprocess.run(["sips", "--cropToHeightWidth", "384", "384", str(path)], check=True)
        print(f"Saved {material}: unchanged 1920x1080 scene, 384x384 crop at {x}, {y}", flush=True)


if __name__ == "__main__":
    main()
