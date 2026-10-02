"""Build a Blender scene and replay validated PyBullet JSON as PNG frames.

Tested against the installed Blender 5.2.2 LTS. No Blender rigid-body world is
created. JSON frame 0 maps to Blender frame 1 and to file frame_0000.png.
Run with: blender --background --factory-startup --python-exit-code 1
    --python stimuli/blender/render_stimuli.py -- --trajectory PATH --smoke
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
OBJECT_NAMES = ("ramp_object", "table_object")
CAMERA = {"location": [3.0, -9.0, 5.0], "target": [0.0, 0.0, 0.45],
          "ortho_scale": 6.1, "clip_start": 0.05, "clip_end": 200.0}
LIGHTS = {
    "key": {"location": [-3.0, -4.0, 7.0], "target": [0.0, 0.0, 0.0],
            "energy_watts": 1500.0, "size_m": 4.0, "color": [1.0, 1.0, 1.0]},
    "fill": {"location": [4.0, 1.0, 5.0], "target": [0.0, 0.0, 0.3],
             "energy_watts": 650.0, "size_m": 3.0, "color": [1.0, 1.0, 1.0]},
}
BEVEL = {"width_m": 0.003, "segments": 3, "normal_method": "smooth + weighted normals",
         "weighted_normal_weight": 50}
MATERIALS = {
    "wood": {"metallic": 0.0, "roughness": 0.43,
             "dark_color": [0.105, 0.035, 0.010, 1.0],
             "light_color": [0.48, 0.255, 0.095, 1.0],
             "grain_axis": "local X", "grain_frequency_per_m": 22.0,
             "noise_stretch": [2.0, 45.0, 45.0], "bump_strength": 0.15,
             "bump_distance_m": 0.0006},
    "brick": {"metallic": 0.0, "roughness": 0.85,
              "color_1": [0.23, 0.070, 0.046, 1.0],
              "color_2": [0.37, 0.15, 0.09, 1.0],
              "mortar_color": [0.15, 0.13, 0.105, 1.0],
              "brick_width_m": 0.065, "row_height_m": 0.035,
              "mortar_size_m": 0.0013,
              "bump_strength": 0.25, "bump_distance_m": 0.0008},
    "metal": {"metallic": 1.0, "roughness": 0.23,
              "base_color": [0.48, 0.50, 0.52, 1.0]},
}
RENDER = {"samples": 64, "shadow_rays": 4, "shadow_steps": 12,
          "world_color": [0.35, 0.35, 0.35, 1.0], "world_strength": 0.5,
          "view_transform": "AgX", "look": "None", "exposure": 0.0, "gamma": 1.0,
          "texture_coordinate_scale": 1.0, "procedural_seed": 0}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def vector(value, size, label):
    require(isinstance(value, list) and len(value) == size, f"{label}: expected {size} values")
    require(all(isinstance(x, (int, float)) and math.isfinite(x) for x in value),
            f"{label}: values must be finite numbers")
    return value


def near(a, b):
    return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-9)


def load_trajectory(path):
    """Validate the exported clock, geometry and every pose before using Blender."""
    data = json.loads(path.read_text())
    require(data.get("schema_version") == 1, f"{path}: unsupported schema_version")
    condition = data["condition_id"]
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", condition), "Unsafe condition_id")
    spec, timing, collision = data["stimulus"], data["timing"], data["collision"]
    require(condition == spec["condition_id"], "Mismatched condition IDs")
    hz, fps = spec["physics_hz"], spec["video_fps"]
    require(type(hz) is int and type(fps) is int and hz > 0 and fps > 0 and hz % fps == 0,
            "physics_hz and video_fps must be positive divisible integers")
    k = hz // fps
    require(timing["physics_hz"] == hz and timing["video_fps"] == fps
            and timing["substeps_per_frame"] == k, "Inconsistent clock metadata")
    frames = data["frames"]
    require(len(frames) >= 2 and len(frames) == timing["frame_count"], "Invalid frame count")
    require(len(data["frame_times_seconds"]) == len(frames), "Invalid frame time count")
    require(near(timing["duration_seconds"], (len(frames) - 1) / fps), "Duration/FPS mismatch")
    require(timing["duration_seconds"] <= spec["max_duration"] + 1e-9, "Maximum duration exceeded")
    require(timing["total_physics_substeps"] == (len(frames) - 1) * k, "Incorrect substep total")
    contact = collision["first_contact_substep"]
    require(type(contact) is int and 0 < contact <= timing["total_physics_substeps"], "Missing collision")
    require(near(collision["first_contact_time_seconds"], contact / hz), "Incorrect contact time")
    require(collision["video_frame"] == (contact + k - 1) // k, "Incorrect contact video frame")
    if timing["post_collision_duration_completed"]:
        elapsed = timing["duration_seconds"] - contact / hz
        require(spec["post_collision_duration"] - 1e-9 <= elapsed
                < spec["post_collision_duration"] + 1 / fps + 1 / hz, "Incorrect post-contact duration")
    geometry = data["scene_geometry"]
    for key in ("base_dims", "table_dims", "ramp_dims"):
        require(all(x > 0 for x in vector(geometry[key], 3, key)), f"{key} must be positive")
    vector(geometry["ramp_position"], 3, "ramp_position")
    for name, dims_key in zip(OBJECT_NAMES, ("obj_ramp_dims", "obj_table_dims")):
        obj = data["objects"][name]
        require(obj["material"] in MATERIALS, f"Unsupported material: {obj['material']}")
        require(all(x > 0 for x in vector(obj["dimensions"], 3, name)), "Nonpositive dimensions")
        require(obj["dimensions"] == spec[dims_key] == geometry[dims_key], "Dimension metadata mismatch")
        require(math.isfinite(obj["mass"]) and obj["mass"] > 0, "Invalid mass")
    require(near(data["objects"]["ramp_object"]["mass"], spec["mass_ratio"])
            and data["objects"]["table_object"]["mass"] == 1.0, "Invalid mass normalization")
    for i, sample in enumerate(frames):
        require(sample["frame"] == i and sample["physics_substep"] == i * k, "Nonuniform frame stepping")
        require(near(sample["time_seconds"], i / fps)
                and near(data["frame_times_seconds"][i], i / fps), "Incorrect frame time")
        for name in OBJECT_NAMES:
            state = sample["objects"][name]
            for field in ("position", "linear_velocity", "angular_velocity"):
                vector(state[field], 3, f"frame {i}: {name}.{field}")
            q = vector(state["quaternion_xyzw"], 4, f"frame {i}: {name}.quaternion")
            require(abs(sum(x * x for x in q) - 1.0) < 1e-6, "Quaternion is not normalized")
    for name, key in zip(OBJECT_NAMES, ("obj_ramp_position", "obj_table_position")):
        require(all(near(a, b) for a, b in zip(frames[0]["objects"][name]["position"], geometry[key])),
                "Frame zero does not match initial scene")
    return data


def arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--trajectory", type=Path, help="One exported trajectory JSON")
    inputs.add_argument("--all", action="store_true", help="Render every enabled condition in stimuli.toml")
    parser.add_argument("--output-dir", type=Path, help="Root directory; condition_id is appended")
    parser.add_argument("--resolution", type=int, nargs=2, default=(960, 540), metavar=("WIDTH", "HEIGHT"))
    parser.add_argument("--engine", choices=("EEVEE", "CYCLES"), default="EEVEE")
    parser.add_argument("--samples", type=int, default=RENDER["samples"], help="Render samples (shared across conditions)")
    subset = parser.add_mutually_exclusive_group()
    subset.add_argument("--frame-range", type=int, nargs=2, metavar=("START", "END"),
                        help="Inclusive zero-based JSON frame range")
    subset.add_argument("--smoke", action="store_true", help="Render only frame zero, collision, and final frame")
    parser.add_argument("--validate-only", action="store_true", help="Validate JSON without creating a Blender scene")
    args = parser.parse_args(argv)
    require(all(x > 0 for x in args.resolution), "Resolution must be positive")
    require(args.samples > 0, "Render samples must be positive")
    return args


def input_paths(args):
    if args.trajectory:
        return [args.trajectory.resolve()]
    import tomllib
    config = tomllib.loads((ROOT / "stimuli/config/stimuli.toml").read_text())
    return [ROOT / "stimuli/generated/trajectories" / (c["condition_id"] + ".json")
            for c in config["conditions"] if c.get("enabled", config["defaults"].get("enabled", True))]


def selected_frames(data, args):
    last = len(data["frames"]) - 1
    if args.smoke:
        return sorted({0, data["collision"]["video_frame"], last})
    start, end = args.frame_range or (0, last)
    require(0 <= start <= end <= last, f"Frame range must lie within 0..{last}")
    return list(range(start, end + 1))


def material(name, color, metallic=0.0, roughness=0.6):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Metallic"].default_value = metallic
    shader.inputs["Roughness"].default_value = roughness
    return mat, shader


def procedural_material(name):
    params = MATERIALS[name]
    mat, shader = material(name, params.get("base_color", [0.5, 0.5, 0.5, 1.0]),
                           params["metallic"], params["roughness"])
    if name == "metal":
        return mat
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    coordinates = nodes.new("ShaderNodeTexCoord")
    # Object coordinates are in meters because meshes have applied unit scale.
    # They stay attached to the object; no world-space texture sliding occurs.
    mapping = nodes.new("ShaderNodeVectorMath")
    mapping.operation = "SCALE"
    mapping.inputs[3].default_value = RENDER["texture_coordinate_scale"]
    links.new(coordinates.outputs["Object"], mapping.inputs[0])
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = params["bump_strength"]
    bump.inputs["Distance"].default_value = params["bump_distance_m"]
    links.new(bump.outputs["Normal"], shader.inputs["Normal"])
    if name == "wood":
        stretch = nodes.new("ShaderNodeVectorMath")
        stretch.operation = "MULTIPLY"
        stretch.inputs[1].default_value = params["noise_stretch"]
        links.new(mapping.outputs["Vector"], stretch.inputs[0])
        noise = nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 1.0
        noise.inputs["Detail"].default_value = 3.0
        links.new(stretch.outputs["Vector"], noise.inputs["Vector"])
        wave = nodes.new("ShaderNodeTexWave")
        wave.wave_type = "BANDS"
        wave.bands_direction = "Y"
        wave.inputs["Scale"].default_value = params["grain_frequency_per_m"]
        wave.inputs["Distortion"].default_value = 4.0
        wave.inputs["Detail Scale"].default_value = 1.5
        links.new(mapping.outputs["Vector"], wave.inputs["Vector"])
        grain = nodes.new("ShaderNodeMath")
        grain.operation = "MULTIPLY"
        links.new(noise.outputs["Fac"], grain.inputs[0])
        links.new(wave.outputs["Fac"], grain.inputs[1])
        ramp = nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.elements[0].position = 0.07
        ramp.color_ramp.elements[0].color = params["dark_color"]
        ramp.color_ramp.elements[1].position = 0.65
        ramp.color_ramp.elements[1].color = params["light_color"]
        links.new(grain.outputs[0], ramp.inputs["Fac"])
        links.new(ramp.outputs["Color"], shader.inputs["Base Color"])
        links.new(grain.outputs[0], bump.inputs["Height"])
    else:
        # Planar brick projections blend by local face normal, so mortar is
        # visible on the top AND both side orientations with the same metric scale.
        separate_position = nodes.new("ShaderNodeSeparateXYZ")
        links.new(mapping.outputs["Vector"], separate_position.inputs[0])
        normal = nodes.new("ShaderNodeNewGeometry")
        transform = nodes.new("ShaderNodeVectorTransform")
        transform.vector_type, transform.convert_from, transform.convert_to = "NORMAL", "WORLD", "OBJECT"
        links.new(normal.outputs["Normal"], transform.inputs[0])
        absolute = nodes.new("ShaderNodeVectorMath")
        absolute.operation = "ABSOLUTE"
        links.new(transform.outputs[0], absolute.inputs[0])
        separate_normal = nodes.new("ShaderNodeSeparateXYZ")
        links.new(absolute.outputs[0], separate_normal.inputs[0])
        colors, heights = [], []
        for axes, weight in (("YZ", "X"), ("XZ", "Y"), ("XY", "Z")):
            combine = nodes.new("ShaderNodeCombineXYZ")
            for dest, source in zip("XY", axes):
                links.new(separate_position.outputs[source], combine.inputs[dest])
            brick = nodes.new("ShaderNodeTexBrick")
            links.new(combine.outputs[0], brick.inputs["Vector"])
            for socket, key in (("Color1", "color_1"), ("Color2", "color_2"),
                                ("Mortar", "mortar_color"), ("Mortar Size", "mortar_size_m"),
                                ("Brick Width", "brick_width_m"), ("Row Height", "row_height_m")):
                brick.inputs[socket].default_value = params[key]
            brick.inputs["Scale"].default_value = 1.0
            multiply_color = nodes.new("ShaderNodeVectorMath")
            multiply_color.operation = "SCALE"
            links.new(brick.outputs["Color"], multiply_color.inputs[0])
            links.new(separate_normal.outputs[weight], multiply_color.inputs[3])
            colors.append(multiply_color.outputs[0])
            multiply_height = nodes.new("ShaderNodeMath")
            multiply_height.operation = "MULTIPLY"
            links.new(brick.outputs["Fac"], multiply_height.inputs[0])
            links.new(separate_normal.outputs[weight], multiply_height.inputs[1])
            heights.append(multiply_height.outputs[0])
        def add_sockets(sockets, node_type):
            total = sockets[0]
            for socket in sockets[1:]:
                add = nodes.new(node_type)
                add.operation = "ADD"
                links.new(total, add.inputs[0])
                links.new(socket, add.inputs[1])
                total = add.outputs[0]
            return total
        links.new(add_sockets(colors, "ShaderNodeVectorMath"), shader.inputs["Base Color"])
        links.new(add_sockets(heights, "ShaderNodeMath"), bump.inputs["Height"])
    return mat


def mesh_object(name, vertices, faces, mat):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.data.materials.append(mat)
    return obj


def box(name, dimensions, position, mat, bevel=False):
    x, y, z = (d / 2 for d in dimensions)
    vertices = [(-x, -y, -z), (x, -y, -z), (x, y, -z), (-x, y, -z),
                (-x, -y, z), (x, -y, z), (x, y, z), (-x, y, z)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
             (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    obj = mesh_object(name, vertices, faces, mat)
    obj.location = position
    if bevel:
        for face in obj.data.polygons:
            face.use_smooth = True
        mod = obj.modifiers.new("Identical 3 mm edge bevel", "BEVEL")
        mod.width, mod.segments = BEVEL["width_m"], BEVEL["segments"]
        mod.affect, mod.limit_method, mod.harden_normals = "EDGES", "ANGLE", True
        normal = obj.modifiers.new("Identical weighted normals", "WEIGHTED_NORMAL")
        normal.keep_sharp, normal.weight = True, BEVEL["weighted_normal_weight"]
    return obj


def point_at(obj, target):
    from mathutils import Vector
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def configure_scene(data, args):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    # Blender 5 restored BLENDER_EEVEE; 4.2-4.5 used BLENDER_EEVEE_NEXT.
    scene.render.engine = ("BLENDER_EEVEE" if bpy.app.version >= (5, 0, 0) else "BLENDER_EEVEE_NEXT") if args.engine == "EEVEE" else "CYCLES"
    scene.unit_settings.system, scene.unit_settings.scale_length = "METRIC", 1.0
    scene.render.resolution_x, scene.render.resolution_y = args.resolution
    scene.render.resolution_percentage = 100
    scene.render.fps, scene.render.fps_base = data["timing"]["video_fps"], 1.0
    scene.render.use_motion_blur = False
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "8"
    scene.render.image_settings.compression = 15
    scene.render.use_file_extension = True
    scene.render.use_compositing = False
    scene.view_settings.view_transform = RENDER["view_transform"]
    scene.view_settings.look = RENDER["look"]
    scene.view_settings.exposure, scene.view_settings.gamma = RENDER["exposure"], RENDER["gamma"]
    scene.view_settings.use_curve_mapping = False
    if args.engine == "EEVEE":
        scene.eevee.taa_render_samples = RENDER["samples"]
        scene.eevee.use_shadows = True
        scene.eevee.shadow_ray_count, scene.eevee.shadow_step_count = RENDER["shadow_rays"], RENDER["shadow_steps"]
        scene.eevee.use_raytracing = True
        scene.eevee.ray_tracing_method = "SCREEN"
    else:
        scene.cycles.samples, scene.cycles.seed = RENDER["samples"], RENDER["procedural_seed"]
        scene.cycles.use_animated_seed = False
    world = bpy.data.worlds.new("Neutral studio")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = RENDER["world_color"]
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = RENDER["world_strength"]
    scene.world = world
    g = data["scene_geometry"]
    table_mat, _ = material("Tabletop", [0.33, 0.34, 0.35, 1.0], roughness=0.7)
    ramp_mat, _ = material("Ramp", [0.42, 0.43, 0.44, 1.0], roughness=0.75)
    base_mat, _ = material("Table base", [0.24, 0.25, 0.26, 1.0], roughness=0.8)
    ground_mat, _ = material("Neutral ground", [0.24, 0.25, 0.27, 1.0], roughness=0.85)
    box("Tabletop", g["table_dims"], [0, 0, -g["table_dims"][2] / 2], table_mat)
    box("Table base", g["base_dims"], [0, 0, -(g["base_dims"][2] + g["table_dims"][2]) / 2], base_mat)
    box("Backdrop ground", [200, 200, 0.1], [0, 0, -g["base_dims"][2] - g["table_dims"][2] / 2 - 0.05], ground_mat)
    x, y, z = g["ramp_dims"]
    # Construct a closed wedge directly; never depend on imported OBJ face normals.
    ramp = mesh_object("Ramp", [(0, 0, 0), (x, 0, 0), (x, y, 0), (0, y, 0), (0, 0, z), (0, y, z)],
                       [(0, 3, 2), (0, 2, 1), (0, 4, 5), (0, 5, 3),
                        (1, 2, 5), (1, 5, 4), (0, 1, 4), (3, 5, 2)], ramp_mat)
    ramp.location = g["ramp_position"]
    materials = {name: procedural_material(name) for name in MATERIALS}
    objects = {name: box(name, data["objects"][name]["dimensions"], (0, 0, 0),
                         materials[data["objects"][name]["material"]], bevel=True) for name in OBJECT_NAMES}
    camera_data = bpy.data.cameras.new("Fixed camera")
    camera = bpy.data.objects.new("Fixed camera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = CAMERA["location"]
    point_at(camera, CAMERA["target"])
    camera_data.type, camera_data.ortho_scale = "ORTHO", CAMERA["ortho_scale"]
    camera_data.clip_start, camera_data.clip_end = CAMERA["clip_start"], CAMERA["clip_end"]
    camera_data.dof.use_dof = False
    scene.camera = camera
    for name, params in LIGHTS.items():
        light_data = bpy.data.lights.new(name, "AREA")
        light = bpy.data.objects.new(name, light_data)
        scene.collection.objects.link(light)
        light.location = params["location"]
        point_at(light, params["target"])
        light_data.energy, light_data.size = params["energy_watts"], params["size_m"]
        light_data.color, light_data.shape, light_data.use_shadow = params["color"], "DISK", True
        light_data.use_shadow_jitter = True
        # Modern Eevee's virtual shadow maps replace the old contact-shadow toggle.
        light_data.shadow_maximum_resolution = 0.001
    require(scene.rigidbody_world is None, "Unexpected Blender rigid-body world")
    require(all(obj.rigid_body is None for obj in scene.objects), "Unexpected rigid body")
    return scene, objects


def action_curves(obj):
    action = obj.animation_data.action
    if hasattr(action, "layers"):
        for layer in action.layers:
            for strip in layer.strips:
                if strip.type == "KEYFRAME":
                    for bag in strip.channelbags:
                        yield from bag.fcurves
    else:
        yield from action.fcurves


def import_animation(scene, objects, frames):
    for obj in objects.values():
        obj.rotation_mode = "QUATERNION"
    for sample in frames:
        for name, obj in objects.items():
            state = sample["objects"][name]
            obj.location = state["position"]
            x, y, z, w = state["quaternion_xyzw"]
            obj.rotation_quaternion = (w, x, y, z)
            obj.keyframe_insert(data_path="location", frame=sample["frame"] + 1)
            obj.keyframe_insert(data_path="rotation_quaternion", frame=sample["frame"] + 1)
    for obj in objects.values():
        curves = list(action_curves(obj))
        require(len(curves) == 7, "Expected 3 position and 4 quaternion animation channels")
        for curve in curves:
            curve.extrapolation = "CONSTANT"
            require(len(curve.keyframe_points) == len(frames), "Missing pose keyframes")
            for point in curve.keyframe_points:
                point.interpolation = "LINEAR"
    scene.frame_start, scene.frame_end = 1, len(frames)


def verify_replay(scene, objects, frames):
    """Check evaluated Blender transforms against every recorded pose, without physics."""
    from bpy_extras.object_utils import world_to_camera_view
    from mathutils import Vector
    max_position_error = max_quaternion_error = 0.0
    for sample in frames:
        scene.frame_set(sample["frame"] + 1)
        for name, obj in objects.items():
            state = sample["objects"][name]
            position_error = max(abs(a - b) for a, b in zip(obj.location, state["position"]))
            x, y, z, w = state["quaternion_xyzw"]
            quaternion_error = max(abs(a - b) for a, b in zip(obj.rotation_quaternion, (w, x, y, z)))
            max_position_error = max(max_position_error, position_error)
            max_quaternion_error = max(max_quaternion_error, quaternion_error)
            require(position_error < 1e-6 and quaternion_error < 1e-6, "Blender changed a recorded pose")
            for corner in obj.bound_box:
                projected = world_to_camera_view(scene, scene.camera, obj.matrix_world @ Vector(corner))
                require(0.02 < projected.x < 0.98 and 0.02 < projected.y < 0.98 and projected.z > 0,
                        f"Fixed camera crops {name} at frame {sample['frame']}; do not auto-fit individual conditions")
    return {"frames_verified": len(frames), "objects_per_frame": len(objects),
            "max_position_error_m": max_position_error, "max_quaternion_component_error": max_quaternion_error,
            "all_fcurves_linear": True, "all_objects_inside_camera": True, "blender_physics": False}


def render_condition(path, data, args, output_root):
    scene, objects = configure_scene(data, args)
    import_animation(scene, objects, data["frames"])
    verification = verify_replay(scene, objects, data["frames"])
    indices = selected_frames(data, args)
    output = output_root / data["condition_id"]
    output.mkdir(parents=True, exist_ok=True)
    policy = {"resolution": list(args.resolution), "fps": scene.render.fps,
              "engine": scene.render.engine, "camera": CAMERA, "lighting": LIGHTS,
              "materials": MATERIALS, "bevel": BEVEL, "render": RENDER,
              "motion_blur": False, "depth_of_field": False, "png": {"mode": "RGB", "bit_depth": 8}}
    metadata = {"schema_version": 1, "condition_id": data["condition_id"],
                "blender_version": bpy.app.version_string, "blender_build_hash": bpy.app.build_hash.decode(),
                "trajectory_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "renderer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "policy_sha256": hashlib.sha256(json.dumps(policy, sort_keys=True).encode()).hexdigest(),
                **policy, "camera_matrix_world": [list(row) for row in scene.camera.matrix_world],
                "object_dimensions": {name: data["objects"][name]["dimensions"] for name in OBJECT_NAMES},
                "object_materials": {name: data["objects"][name]["material"] for name in OBJECT_NAMES},
                "frame_mapping": "JSON n -> Blender n+1 -> frame_nnnn.png",
                "mode": "smoke" if args.smoke else "frames", "requested_frames": indices,
                "rendered_frames": [], "status": "rendering", "pose_verification": verification,
                "shadow_method": "virtual shadow maps, jittered area shadows, screen-space ray tracing",
                "material_coordinates": "local object coordinates in meters; common mapping scale 1.0",
                "scene_geometry": data["scene_geometry"]}
    metadata_path = output / "render_metadata.json"
    def save_metadata():
        temporary = output / "render_metadata.json.tmp"
        temporary.write_text(json.dumps(metadata, indent=2, allow_nan=False) + "\n")
        temporary.replace(metadata_path)
    save_metadata()
    try:
        for index in indices:
            scene.frame_set(index + 1)
            scene.render.filepath = str(output / f"frame_{index:04d}.png")
            bpy.ops.render.render(write_still=True)
            metadata["rendered_frames"].append(index)
            save_metadata()
        metadata["status"] = "complete"
    except Exception:
        metadata["status"] = "failed"
        raise
    finally:
        save_metadata()
    print(f"Rendered {data['condition_id']}: {len(indices)} PNGs -> {output}", flush=True)


def main(argv=None):
    if argv is None:
        argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    args = arguments(argv)
    RENDER["samples"] = args.samples
    # Validate the entire requested set before creating any Blender scene or output.
    trajectories = [(path, load_trajectory(path)) for path in input_paths(args)]
    for path, data in trajectories:
        selected_frames(data, args)
        print(f"Validated {path.name}: {len(data['frames'])} frames", flush=True)
    if args.validate_only or not trajectories:
        return
    global bpy
    import bpy
    require(bpy.app.version >= (4, 2, 0), "Blender 4.2 or newer is required; tested on 5.2.2 LTS")
    output_root = (args.output_dir or (ROOT / "results/stimuli/smoke" if args.smoke
                                     else ROOT / "stimuli/generated/frames")).resolve()
    for path, data in trajectories:
        render_condition(path, data, args, output_root)


if __name__ == "__main__":
    main()
