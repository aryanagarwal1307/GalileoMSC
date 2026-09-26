"""Canonical resumable build: python stimuli/build_stimuli.py --all.

Edit the settings below; --dry-run checks dependencies and plans without building.
The stage implementations remain in the exporter, Blender renderer and encoder.
"""

import argparse
from contextlib import contextmanager
import copy
from fractions import Fraction
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

# EDIT BUILD PARAMETERS HERE. These overrides apply to EVERY condition and are
# passed into a derived TOML file; the source stimuli.toml is never rewritten.
# Conditions, appearance labels and mass ratios remain defined in stimuli.toml.
SIMULATION = {
    "physics_hz": 240,               # Simulation dt = 1 / physics_hz seconds.
    "video_fps": 60,                 # Must divide physics_hz exactly.
    "max_duration": 10.0,            # Simulation safety limit, excluding holds.
    "post_collision_duration": 2.0,  # Simulate this long after first contact.
    "seed": 42,
    "obj_ramp_dims": [0.20, 0.20, 0.10],
    "obj_table_dims": [0.20, 0.20, 0.10],
    "obj_frictions": [0.3, 0.3],
    "restitution": 0.5,
    "obj_positions": [0.5, 1.5],
    "slope": 2 / 3,
    "table_ramp_intersection": 0.0,
}
RENDERING = {"resolution": [960, 540], "engine": "EEVEE", "samples": 64}
ENCODING = {
    "crf": 15,
    "preset": "slow",
    "hold_start_seconds": 0.5,  # Additional first-frame display; 0 disables.
    "hold_end_seconds": 0.5,    # Additional final-frame display; 0 disables.
}
# Fixed camera, lights, materials, bevels and color management are shared by the
# renderer. Its source hash is tracked, so changes there invalidate all renders.
# MODEL-CLOCK ALIGNMENT BEFORE HUMAN-DATA FITTING REMAINS A SEPARATE TASK.

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "stimuli/config/stimuli.toml"
EXPORTER = ROOT / "scripts/export_stimulus_trajectories.jl"
RENDERER = ROOT / "stimuli/blender/render_stimuli.py"
ENCODER = ROOT / "stimuli/video/encode_videos.py"
TRAJECTORIES = ROOT / "stimuli/generated/trajectories"
FRAMES = ROOT / "results/stimuli/final/pngs"
VIDEOS = ROOT / "stimuli/generated/videos"
WORK = ROOT / "stimuli/generated/build"
CACHE_SCHEMA = 1


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, allow_nan=False).encode()).hexdigest()


def file_hash(path):
    h = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def module(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    result = importlib.util.module_from_spec(spec)
    # Importing validation helpers must not create __pycache__ in the source tree.
    previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(result)
    finally:
        sys.dont_write_bytecode = previous
    return result


def stage(number, condition, message):
    print(f"[stage {number}/6] [{condition}] {message}", flush=True)


def run(command):
    """Inherit stdout/stderr: Julia, Blender and FFmpeg output streams immediately."""
    print("$ " + shlex.join([str(x) for x in command]), flush=True)
    subprocess.run([str(x) for x in command], cwd=ROOT, check=True)


def tool_output(command):
    result = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        json.dump(value, file, indent=2, allow_nan=False)
        file.write("\n")
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def read_state(path):
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text())
        require(value.get("schema_version") == CACHE_SCHEMA, "Unknown cache schema")
        return value
    except (ValueError, OSError):
        print("Build checkpoint is invalid; outputs will be revalidated/rebuilt.", flush=True)
        return {}


@contextmanager
def lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        file = path.open("x")
    except FileExistsError:
        raise ValueError(f"{path} exists. Another build may be running; remove a stale lock only after checking its PID.") from None
    try:
        with file:
            file.write(str(os.getpid()) + "\n")
        yield
    finally:
        path.unlink(missing_ok=True)


def configuration():
    require(sys.version_info >= (3, 8), "Python 3.8+ is required")
    try:
        import tomllib
    except ImportError:
        try:
            import tomli as tomllib
        except ImportError:
            raise ValueError("Python <3.11 needs tomli: python -m pip install tomli") from None
    config = tomllib.loads(CONFIG.read_text())
    resolved = copy.deepcopy(config)
    resolved["defaults"].update(SIMULATION)
    for condition in resolved["conditions"]:
        # Master settings win even over per-condition settings for these keys.
        condition.update(SIMULATION)
    enabled = [c for c in resolved["conditions"] if c.get("enabled", resolved["defaults"].get("enabled", True))]
    ids = [c["condition_id"] for c in enabled]
    require(len(ids) == len(set(ids)) == 8, "The build requires exactly eight unique enabled conditions in stimuli.toml")
    require(all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", c) for c in ids), "Unsafe condition ID")
    require(RENDERING["engine"] == "EEVEE", "Canonical experimental renders use EEVEE")
    require(len(RENDERING["resolution"]) == 2 and all(type(v) is int and v > 0 and v % 2 == 0 for v in RENDERING["resolution"]),
            "Resolution must have positive even dimensions")
    require(type(RENDERING["samples"]) is int and RENDERING["samples"] > 0, "Samples must be positive")
    require(type(ENCODING["crf"]) is int and 0 <= ENCODING["crf"] <= 51, "CRF must be 0..51")
    require(ENCODING["preset"] in ("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"), "Invalid x264 preset")
    # Hold validation uses the encoder's shared function, not an independent rule.
    module(ENCODER).with_holds({"fps": Fraction(str(SIMULATION["video_fps"])), "frame_count": 1},
                              ENCODING["hold_start_seconds"], ENCODING["hold_end_seconds"])
    return resolved, sorted(ids)


def toml_text(config):
    """Serialize the existing flat stimulus schema; Julia still validates its semantics."""
    def table(values):
        return [json.dumps(key) + " = " + json.dumps(value, allow_nan=False) for key, value in sorted(values.items())]
    lines = ["# Generated by build_stimuli.py; edit the master's settings instead.", "[materials]"]
    lines += table(config["materials"]) + ["", "[defaults]"] + table(config["defaults"])
    for condition in config["conditions"]:
        lines += ["", "[[conditions]]"] + table(condition)
    return "\n".join(lines) + "\n"


def dependencies(config_text, blender_override=None):
    print("[preflight] Checking Python, Julia/PyCall/PyBullet, Blender and FFmpeg...", flush=True)
    tools = {name: shutil.which(name) for name in ("julia", "ffmpeg", "ffprobe")}
    blender = blender_override or shutil.which("blender")
    if blender is None and Path("/Applications/Blender.app/Contents/MacOS/Blender").exists():
        blender = "/Applications/Blender.app/Contents/MacOS/Blender"
    tools["blender"] = blender
    for name, path in tools.items():
        require(path, f"Missing dependency: {name}; install it and put it on PATH")
    versions = {name: tool_output([tools[name], "-version"]) for name in ("ffmpeg", "ffprobe")}
    versions["blender"] = tool_output([blender, "--version"])
    require("libx264" in tool_output([tools["ffmpeg"], "-hide_banner", "-encoders"]), "FFmpeg lacks libx264")
    require("tpad" in tool_output([tools["ffmpeg"], "-hide_banner", "-filters"]), "FFmpeg lacks the tpad hold filter")
    match = re.search(r"Blender (\d+)\.(\d+)", versions["blender"])
    require(match and tuple(map(int, match.groups())) >= (4, 2), "Blender 4.2+ is required")
    # Reuse load_stimuli and resolved_fields from the existing exporter. This checks
    # the actual PyCall Python, not an unrelated shell Python installation.
    code = '''include(ARGS[1]); using PhyBullet, PhySMC, PyCall
specs = filter(s -> s.enabled, load_stimuli(ARGS[2]))
py = pyimport("sys"); metadata = pyimport("importlib.metadata")
info = (; specs=resolved_fields.(specs), julia=string(VERSION),
    python=String(py.version), python_executable=String(py.executable),
    pybullet=metadata.version("pybullet"), pybullet_api=pb.getAPIVersion(),
    packages=Dict(string(m) => (; version=string(Base.pkgversion(m)),
        sources=Dict(relpath(joinpath(d,f), pkgdir(m)) => bytes2hex(SHA.sha256(read(joinpath(d,f))))
            for (d,_,files) in walkdir(joinpath(pkgdir(m), "src")) for f in files if endswith(f,".jl")))
        for m in (PhyBullet, PhySMC, PyCall)))
open(ARGS[3], "w") do io; JSON.print(io, info); end
println("Julia dependencies, PyCall Python, PyBullet and all stimulus specs validated.")'''
    with tempfile.TemporaryDirectory(prefix="stimulus-dependencies-") as temp:
        temp = Path(temp)
        (temp / "stimuli.toml").write_text(config_text)
        run([tools["julia"], "--startup-file=no", "--compiled-modules=existing", f"--project={ROOT}",
             "-e", code, EXPORTER, temp / "stimuli.toml", temp / "info.json"])
        info = json.loads((temp / "info.json").read_text())
    versions["simulation"] = {k: v for k, v in info.items() if k != "specs"}
    versions["python"] = sys.version
    print("[preflight] Dependencies ready; no simulations or renders were started.", flush=True)
    return tools, versions, {s["condition_id"]: s for s in info["specs"]}


def trajectory_key(config, versions):
    paths = [EXPORTER, ROOT / "Project.toml", ROOT / "assets/ramp.obj"]
    paths += sorted((ROOT / "src").rglob("*.jl"))
    if (ROOT / "Manifest.toml").exists():
        paths.append(ROOT / "Manifest.toml")
    return digest({"schema": CACHE_SCHEMA, "config": config, "simulation": versions["simulation"],
                   "code": {str(p.relative_to(ROOT)): file_hash(p) for p in paths}})


def render_key(trajectory_path, versions):
    return digest({"schema": CACHE_SCHEMA, "trajectory": file_hash(trajectory_path),
                   "renderer": file_hash(RENDERER), "settings": RENDERING, "blender": versions["blender"]})


def video_key(source, versions):
    return digest({"schema": CACHE_SCHEMA, "encoder": file_hash(ENCODER), "settings": ENCODING,
                   "pngs": source["png_sequence_sha256"], "metadata": source["metadata_sha256"],
                   "ffmpeg": versions["ffmpeg"], "ffprobe": versions["ffprobe"]})


def validate_trajectories(directory, specs, renderer, encoder):
    catalog = encoder.discover(directory)
    require(set(catalog) == set(specs), "Trajectory set differs from the eight resolved conditions")
    for condition in sorted(specs):
        path, _ = catalog[condition]
        data = renderer.load_trajectory(path)
        require(data["stimulus"] == specs[condition], f"{condition}: trajectory parameters differ from master configuration")
        catalog[condition] = (path, data)
        stage(2, condition, f"validated {len(data['frames'])} trajectory frames")
    first = next(iter(catalog.values()))[1]
    for condition, (_, data) in catalog.items():
        require(data["frame_times_seconds"] == first["frame_times_seconds"],
                f"{condition}: unequal trajectory lengths/timing; adjust common simulation settings, never trim conditions")
        for name in renderer.OBJECT_NAMES:
            for field in ("position", "quaternion_xyzw"):
                require(data["frames"][0]["objects"][name][field] == first["frames"][0]["objects"][name][field],
                        f"{condition}: initial pose differs across conditions")
    return catalog


def trajectory_cache_valid(record, key, specs):
    try:
        return (record.get("key") == key and set(record["files"]) == set(specs)
                and {p.name for p in TRAJECTORIES.iterdir()} == {c + ".json" for c in specs}
                and all(file_hash(TRAJECTORIES / (c + ".json")) == record["files"][c] for c in specs))
    except (KeyError, OSError):
        return False


def checked_render(condition, catalog, encoder, frames_root=None):
    frames_root = FRAMES if frames_root is None else frames_root
    source = encoder.validate_source(condition, catalog[condition], frames_root)
    render = source["render"]
    require(render["renderer_sha256"] == file_hash(RENDERER), f"{condition}: outdated renderer")
    require(render["resolution"] == RENDERING["resolution"] and render["render"]["samples"] == RENDERING["samples"],
            f"{condition}: outdated rendering parameters")
    require(render["engine"] in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"), f"{condition}: incorrect engine")
    return source


def cached_render(condition, catalog, encoder, record, key):
    try:
        if record.get("key") != key:
            return None
        source = checked_render(condition, catalog, encoder)
        if source["png_sequence_sha256"] == record["pngs"] and source["metadata_sha256"] == record["metadata"]:
            return source
    except (OSError, KeyError, ValueError):
        pass
    return None


def publish_directory(staged, destination, allowed_names):
    """Swap only pipeline-owned directories; never delete unexpected user files."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        staged.rename(destination)
        return
    unexpected = {p.name for p in destination.iterdir()} - set(allowed_names)
    require(not unexpected, f"Refusing to replace unrelated files in {destination}: {sorted(unexpected)}")
    with tempfile.TemporaryDirectory(prefix="previous-", dir=destination.parent) as temp:
        backup = Path(temp) / "previous"
        destination.rename(backup)
        try:
            staged.rename(destination)
        except BaseException:
            backup.rename(destination)
            raise


def export_command(tools, config, output):
    return [tools["julia"], "--startup-file=no", "--compiled-modules=existing", f"--project={ROOT}",
            EXPORTER, "--config", config, "--output-dir", output]


def render_command(tools, trajectory, output):
    return [tools["blender"], "--background", "--factory-startup", "--python-exit-code", "1",
            "--python", RENDERER, "--", "--trajectory", trajectory, "--output-dir", output,
            "--resolution", *RENDERING["resolution"], "--engine", RENDERING["engine"], "--samples", RENDERING["samples"]]


def dry_run(config, specs, tools, versions, state, force, renderer, encoder):
    key = trajectory_key(config, versions)
    reuse = not force and trajectory_cache_valid(state.get("trajectory", {}), key, specs)
    stage(1, "all", "REUSE trajectory cache" if reuse else "WOULD GENERATE all eight trajectories")
    print(shlex.join([str(x) for x in export_command(tools, WORK / "resolved_stimuli.toml", TRAJECTORIES)]))
    # Existing outputs can be inspected even if their provenance is too old to reuse.
    catalog = None
    try:
        catalog = validate_trajectories(TRAJECTORIES, specs, renderer, encoder)
    except (OSError, ValueError, KeyError) as exc:
        stage(2, "all", f"WOULD VALIDATE generated trajectories; current outputs unavailable/stale: {exc}")
    for condition in sorted(specs):
        source = None
        if catalog:
            rkey = render_key(catalog[condition][0], versions)
            if reuse and not force:
                source = cached_render(condition, catalog, encoder, state.get("renders", {}).get(condition, {}), rkey)
        stage(3, condition, "REUSE render" if source else "WOULD RENDER full sequence")
        if not source:
            print(shlex.join([str(x) for x in render_command(tools, TRAJECTORIES / (condition + ".json"), FRAMES)]))
    stage(4, "all", "WOULD VALIDATE complete PNGs, checksums, dimensions, FPS and equal frame counts")
    stage(5, "all", "WOULD REUSE hash-matching videos or encode complete sequences with configured holds")
    print(shlex.join([sys.executable, str(ENCODER), "--all", "--trajectory-dir", str(TRAJECTORIES),
                      "--frames-dir", str(FRAMES), "--output-dir", str(VIDEOS), "--overwrite",
                      "--crf", str(ENCODING["crf"]), "--preset", ENCODING["preset"],
                      "--hold-start", str(ENCODING["hold_start_seconds"]), "--hold-end", str(ENCODING["hold_end_seconds"])]))
    stage(6, "all", "WOULD FFprobe every final MP4, write combined manifest and print eight-file summary")
    print("Dry run complete: no trajectories, PNGs, videos or build checkpoints were written.")


def build(config, specs, tools, versions, state, force, renderer, encoder):
    WORK.mkdir(parents=True, exist_ok=True)
    state_path = WORK / "state.json"
    state["schema_version"] = CACHE_SCHEMA
    for key in ("renders", "videos"):
        state.setdefault(key, {})
    config_path = WORK / "resolved_stimuli.toml"
    config_path.write_text(toml_text(config))
    key = trajectory_key(config, versions)
    if not force and trajectory_cache_valid(state.get("trajectory", {}), key, specs):
        stage(1, "all", "reusing unchanged trajectories")
        catalog = validate_trajectories(TRAJECTORIES, specs, renderer, encoder)
    else:
        stage(1, "all", "generating all eight trajectories")
        with tempfile.TemporaryDirectory(prefix="trajectories-", dir=WORK) as temp:
            staged = Path(temp) / "trajectories"
            run(export_command(tools, config_path, staged))
            validate_trajectories(staged, specs, renderer, encoder)  # Fail before publishing or rendering.
            publish_directory(staged, TRAJECTORIES, [c + ".json" for c in specs])
        catalog = {c: (TRAJECTORIES / (c + ".json"), renderer.load_trajectory(TRAJECTORIES / (c + ".json"))) for c in specs}
        state["trajectory"] = {"key": key, "files": {c: file_hash(p) for c, (p, _) in catalog.items()}}
        atomic_json(state_path, state)
    for condition in sorted(specs):
        key = render_key(catalog[condition][0], versions)
        source = None if force else cached_render(condition, catalog, encoder, state["renders"].get(condition, {}), key)
        if source:
            stage(3, condition, "reusing complete unchanged PNG sequence")
            continue
        stage(3, condition, "rendering complete PNG sequence")
        with tempfile.TemporaryDirectory(prefix="render-", dir=WORK) as temp:
            run(render_command(tools, catalog[condition][0], Path(temp)))
            source = checked_render(condition, catalog, encoder, Path(temp))
            # Only old frame_*.png files and render metadata belong to this stage.
            allowed = [p.name for p in (FRAMES / condition).glob("frame_*.png")] + ["render_metadata.json", "render_metadata.json.tmp"]
            publish_directory(Path(temp) / condition, FRAMES / condition, allowed)
        state["renders"][condition] = {"key": key, "pngs": source["png_sequence_sha256"], "metadata": source["metadata_sha256"]}
        atomic_json(state_path, state)
    sources = []
    for condition in sorted(specs):
        stage(4, condition, "validating complete rendered sequence")
        sources.append(checked_render(condition, catalog, encoder))
    encoder.matching_sources(sources)
    require(len({s["render"]["policy_sha256"] for s in sources}) == 1, "Render policies differ across conditions")
    held_sources = [encoder.with_holds(s, ENCODING["hold_start_seconds"], ENCODING["hold_end_seconds"]) for s in sources]
    expected_files = {c + ".mp4" for c in specs} | {"video_manifest.json", ".encode.lock"}
    with lock(VIDEOS / ".encode.lock"):
        extra = {p.name for p in VIDEOS.iterdir()} - expected_files
        require(not extra, f"Unexpected files in final video directory (preserved): {sorted(extra)}")
        entries = {}
        manifest_path = VIDEOS / "video_manifest.json"
        for source in held_sources:
            condition = source["condition_id"]
            target = VIDEOS / (condition + ".mp4")
            key = video_key(source, versions)
            record = state["videos"].get(condition, {})
            reuse = (not force and record.get("key") == key and target.exists()
                     and file_hash(target) == record.get("entry", {}).get("video_sha256"))
            if reuse:
                stage(5, condition, "reusing unchanged encoded video")
                entry = record["entry"]
            else:
                stage(5, condition, "encoding full sequence with endpoint holds")
                # Mark the old manifest incomplete before replacing any video.
                encoder.save_manifest(manifest_path, entries, specs)
                entry = encoder.encode_condition(source, VIDEOS, tools["ffmpeg"], tools["ffprobe"],
                    {n: versions[n].splitlines()[0] for n in ("ffmpeg", "ffprobe")},
                    crf=ENCODING["crf"], preset=ENCODING["preset"], overwrite=True)
                state["videos"][condition] = {"key": key, "entry": entry}
                atomic_json(state_path, state)
            entries[condition] = entry
        for source in held_sources:
            condition = source["condition_id"]
            stage(6, condition, "FFprobe validation of final video")
            entries[condition].update(encoder.probe_video(tools["ffprobe"], VIDEOS / (condition + ".mp4"), source))
        encoder.matching_videos(entries.values())
        require(len(entries) == 8, "Expected exactly eight final videos")
        encoder.save_manifest(manifest_path, entries, specs, build={
            "command": "python stimuli/build_stimuli.py --all", "settings": {"simulation": SIMULATION, "rendering": RENDERING, "encoding": ENCODING},
            "resolved_stimuli": config, "orchestrator_sha256": file_hash(Path(__file__)),
            "trajectory_build_key": state["trajectory"]["key"],
            "render_build_keys": {c: state["renders"][c]["key"] for c in specs},
            "video_build_keys": {c: state["videos"][c]["key"] for c in specs},
            "software": versions, "playback": "jsPsych applies stopping frames; video frame = trajectory frame + hold_start_frames"})
        atomic_json(state_path, state)
    require({p.name for p in VIDEOS.iterdir()} == expected_files - {".encode.lock"}, "Final output set is not exactly eight MP4s and one manifest")
    print("\nComplete: eight full stimulus videos verified.")
    for condition in sorted(entries):
        entry = entries[condition]
        path = VIDEOS / entry["video_path"]
        print(f"{os.path.relpath(path, ROOT)} | {entry['frame_count']} frames | {entry['duration_seconds']:.6f} s | {path.stat().st_size:,} bytes")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", required=True, help="Build all eight complete conditions")
    parser.add_argument("--force", action="store_true", help="Rebuild every stage, ignoring cached outputs")
    parser.add_argument("--dry-run", action="store_true", help="Check dependencies/configuration and print the plan without building")
    parser.add_argument("--blender", help="Blender executable path; default: PATH or the macOS app")
    args = parser.parse_args(argv)
    config, ids = configuration()
    tools, versions, specs = dependencies(toml_text(config), args.blender)
    require(set(specs) == set(ids), "Resolved Julia condition set differs from configuration")
    renderer, encoder = module(RENDERER), module(ENCODER)
    state = read_state(WORK / "state.json")
    if args.dry_run:
        dry_run(config, specs, tools, versions, state, args.force, renderer, encoder)
        return
    with lock(WORK / ".build.lock"):
        # Reload after acquiring the lock in case another process just finished.
        state = read_state(WORK / "state.json")
        build(config, specs, tools, versions, state, args.force, renderer, encoder)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f"BUILD FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
