"""Encode complete Blender PNG sequences; validate inputs and probe every MP4.

Python standard library only. Requires FFmpeg (libx264) and FFprobe on PATH.
No experimental stopping frame or collision time is used to trim a video.
"""

import argparse
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def discover(directory):
    """IDs come from generated trajectory metadata, never a filename/name list."""
    found, seen = {}, set()
    for path in sorted(directory.glob("*.json")):
        data = read_json(path)
        condition = data["condition_id"]
        require(isinstance(condition, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", condition),
                f"{path}: unsafe condition ID")
        require(condition not in seen, f"Duplicate trajectory condition: {condition}")
        seen.add(condition)
        require(data["schema_version"] == 1 and data["stimulus"]["condition_id"] == condition,
                f"{path}: inconsistent trajectory metadata")
        if data["stimulus"].get("enabled", True):
            found[condition] = (path, data)
    require(found, f"No enabled trajectory metadata found in {directory}")
    return found


def validate_source(condition, trajectory, frames_root):
    path, data = trajectory
    directory = frames_root / condition
    metadata_path = directory / "render_metadata.json"
    render = read_json(metadata_path)
    require(render["schema_version"] == 1 and render["condition_id"] == condition,
            f"{condition}: render metadata ID/schema mismatch")
    require(render["status"] == "complete" and render["mode"] == "frames",
            f"{condition}: render is incomplete or a smoke render")
    require(render["trajectory_sha256"] == sha256(path), f"{condition}: render uses a different trajectory")
    count = data["timing"]["frame_count"]
    require(type(count) is int and count > 0 and len(data["frames"]) == count,
            f"{condition}: invalid trajectory frame count")
    indices = list(range(count))
    require([f["frame"] for f in data["frames"]] == indices, f"{condition}: noncontiguous trajectory frames")
    require(render["requested_frames"] == render["rendered_frames"] == indices,
            f"{condition}: render must contain the entire trajectory, frame 0 through {count - 1}")
    fps = Fraction(str(render["fps"]))
    require(fps > 0 and fps == Fraction(str(data["timing"]["video_fps"])),
            f"{condition}: invalid/mismatched FPS")
    resolution = render["resolution"]
    require(len(resolution) == 2 and all(type(x) is int and x > 0 and x % 2 == 0 for x in resolution),
            f"{condition}: yuv420p requires positive even width and height")
    expected = {f"frame_{i:04d}.png" for i in indices}
    actual = {p.name for p in directory.glob("*.png")}
    missing, extra = sorted(expected - actual), sorted(actual - expected)
    require(not missing and not extra,
            f"{condition}: PNG sequence mismatch; missing={missing[:5]}, unexpected={extra[:5]}")
    sequence_hash = hashlib.sha256()
    for name in sorted(expected):
        content = (directory / name).read_bytes()
        header = content[:33]
        require(len(header) == 33 and header[:8] == b"\x89PNG\r\n\x1a\n"
                and header[8:16] == b"\x00\x00\x00\x0dIHDR", f"{condition}/{name}: invalid PNG header")
        require(list(struct.unpack(">II", header[16:24])) == resolution,
                f"{condition}/{name}: resolution differs from render metadata")
        offset, ended = 8, False
        while offset + 12 <= len(content):
            size = struct.unpack(">I", content[offset:offset + 4])[0]
            end = offset + 12 + size
            require(end <= len(content), f"{condition}/{name}: truncated PNG chunk")
            chunk = content[offset + 4:end - 4]
            require(zlib.crc32(chunk) == struct.unpack(">I", content[end - 4:end])[0],
                    f"{condition}/{name}: PNG checksum mismatch")
            offset = end
            if chunk[:4] == b"IEND":
                ended = True
                break
        require(ended and offset == len(content), f"{condition}/{name}: incomplete PNG")
        sequence_hash.update(name.encode())
        sequence_hash.update(hashlib.sha256(content).digest())
    return {"condition_id": condition, "directory": directory, "fps": fps,
            "frame_count": count, "resolution": resolution, "render": render,
            "metadata_path": metadata_path, "metadata_sha256": sha256(metadata_path),
            "png_sequence_sha256": sequence_hash.hexdigest()}


def matching_sources(sources):
    formats = {(s["fps"], s["frame_count"], tuple(s["resolution"])) for s in sources}
    require(len(formats) == 1, "Conditions must have identical FPS, frame count, and resolution; no trimming is allowed")


def with_holds(source, start_seconds=0, end_seconds=0):
    """Add identical endpoint display holds without modifying trajectory samples."""
    require("trajectory_frame_count" not in source, "Holds have already been applied")
    holds = []
    for seconds in (start_seconds, end_seconds):
        count = Fraction(str(seconds)) * source["fps"]
        require(count >= 0 and count.denominator == 1,
                "Hold durations must be nonnegative whole video-frame intervals")
        holds.append(int(count))
    return {**source, "trajectory_frame_count": source["frame_count"],
            "hold_start_frames": holds[0], "hold_end_frames": holds[1],
            "frame_count": source["frame_count"] + sum(holds)}


def ffmpeg_command(ffmpeg, source, destination, crf=15, overwrite=False, preset="slow"):
    fps = source["fps"]
    rate = f"{fps.numerator}/{fps.denominator}"
    start, end = source.get("hold_start_frames", 0), source.get("hold_end_frames", 0)
    filters = ["-vf", f"tpad=start_mode=clone:start={start}:stop_mode=clone:stop={end}"] if start or end else []
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y" if overwrite else "-n",
            "-threads", "1", "-err_detect", "explode", "-framerate", rate, "-start_number", "0",
            "-i", str(source["directory"] / "frame_%04d.png"),
            "-map", "0:v:0", "-an", "-sn", "-dn", "-map_metadata", "-1",
            "-c:v", "libx264", "-preset", preset, "-crf", str(crf), *filters,
            "-threads:v", "1", "-filter_threads", "1", "-pix_fmt", "yuv420p",
            "-r", rate, "-fps_mode", "cfr", "-frames:v", str(source["frame_count"]),
            "-fflags", "+bitexact", "-flags:v", "+bitexact", "-movflags", "+faststart",
            "-video_track_timescale", str(fps.numerator * 1000),
            "-movie_timescale", str(fps.numerator * 1000), str(destination)]


def verify_faststart(path):
    atoms = []
    with path.open("rb") as file:
        end = path.stat().st_size
        while file.tell() < end:
            start = file.tell()
            header = file.read(8)
            require(len(header) == 8, f"{path}: truncated MP4 atom")
            size, kind = struct.unpack(">I4s", header)
            if size == 1:
                size = struct.unpack(">Q", file.read(8))[0]
            elif size == 0:
                size = end - start
            require(size >= 8 and start + size <= end, f"{path}: invalid MP4 atom")
            atoms.append(kind)
            file.seek(start + size)
    require(b"moov" in atoms and b"mdat" in atoms and atoms.index(b"moov") < atoms.index(b"mdat"),
            f"{path}: MP4 is not faststart")


def probe_video(ffprobe, path, source):
    command = [ffprobe, "-v", "error", "-count_frames", "-show_frames", "-show_entries",
               "stream=codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,r_frame_rate,nb_frames,nb_read_frames,duration,duration_ts,time_base:format=duration:frame=best_effort_timestamp",
               "-of", "json", str(path)]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    require(not result.stderr.strip(), f"{path}: FFprobe decoding errors: {result.stderr.strip()}")
    data = json.loads(result.stdout)
    streams = data["streams"]
    require(len(streams) == 1 and streams[0]["codec_type"] == "video", f"{path}: expected one video stream and no audio")
    video = streams[0]
    require(video["codec_name"] == "h264" and video["pix_fmt"] == "yuv420p", f"{path}: unexpected codec/pixel format")
    require([video["width"], video["height"]] == source["resolution"], f"{path}: incorrect resolution")
    require(Fraction(video["avg_frame_rate"]) == Fraction(video["r_frame_rate"]) == source["fps"],
            f"{path}: incorrect frame rate")
    count = source["frame_count"]
    require(int(video["nb_read_frames"]) == int(video["nb_frames"]) == len(data["frames"]) == count,
            f"{path}: incorrect decoded frame count")
    time_base = Fraction(video["time_base"])
    duration = count / source["fps"]
    require(int(video["duration_ts"]) * time_base == duration, f"{path}: incorrect exact stream duration")
    for label, value in (("stream", video["duration"]), ("container", data["format"]["duration"])):
        require(math.isclose(float(value), float(duration), rel_tol=0, abs_tol=1e-6),
                f"{path}: incorrect {label} duration: {value}")
    require(all(int(frame["best_effort_timestamp"]) * time_base == i / source["fps"]
                for i, frame in enumerate(data["frames"])), f"{path}: nonconstant frame timing")
    verify_faststart(path)
    return {"codec": video["codec_name"], "pixel_format": video["pix_fmt"],
            "fps": float(source["fps"]), "fps_rational": str(source["fps"]),
            "frame_count": count, "resolution": source["resolution"],
            "duration_seconds": float(duration), "duration_rational": str(duration),
            "probed_duration_seconds": float(data["format"]["duration"]),
            "audio_streams": 0, "constant_frame_rate": True, "faststart": True,
            "trajectory_frame_count": source.get("trajectory_frame_count", count),
            "hold_start_frames": source.get("hold_start_frames", 0),
            "hold_end_frames": source.get("hold_end_frames", 0),
            "trajectory_frame_offset": source.get("hold_start_frames", 0)}


def matching_videos(entries):
    require(len({(e["frame_count"], e["duration_rational"], e["fps_rational"], tuple(e["resolution"]),
                  e.get("hold_start_frames", 0), e.get("hold_end_frames", 0))
                 for e in entries}) <= 1, "Encoded videos differ in frame count, duration, FPS, or resolution")


def read_manifest(path):
    if not path.exists():
        return {}
    manifest = read_json(path)
    require(manifest["schema_version"] == 1, "Unsupported video manifest schema")
    entries = {}
    for entry in manifest["conditions"]:
        condition = entry["condition_id"]
        require(condition not in entries, f"Duplicate video manifest condition: {condition}")
        require(entry["video_path"] == condition + ".mp4", "Unexpected video manifest path")
        entries[condition] = entry
    return entries


def save_manifest(path, entries, catalog, build=None):
    matching_videos(entries.values())
    data = {"schema_version": 1, "video_paths_relative_to": "this manifest directory",
            "complete_eight_conditions": len(entries) == len(catalog) == 8 and set(entries) == set(catalog),
            "duration_policy": "All trajectory frames plus configured endpoint holds; duration = frame_count / fps. No trial-specific truncation.",
            "conditions": [entries[key] for key in sorted(entries)]}
    if build is not None:
        data["build"] = build
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        json.dump(data, file, indent=2, allow_nan=False)
        file.write("\n")
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def encode_condition(source, output, ffmpeg, ffprobe, versions, crf=15, overwrite=False, preset="slow"):
    """Shared atomic encode/probe/publish operation for the CLI and full builder."""
    condition = source["condition_id"]
    target = output / (condition + ".mp4")
    require(overwrite or not target.exists(), f"{target} exists; use --overwrite")
    print(f"Encoding {condition}...", flush=True)
    with tempfile.TemporaryDirectory(prefix=".encode-", dir=output) as temp:
        temporary = Path(temp) / target.name
        command = ffmpeg_command(ffmpeg, source, temporary, crf, preset=preset)
        subprocess.run(command, check=True)
        verified = probe_video(ffprobe, temporary, source)
        entry = {"condition_id": condition, "video_path": target.name, **verified,
                 "video_sha256": sha256(temporary),
                 "source_render_metadata_path": os.path.relpath(source["metadata_path"], output),
                 "source_render_metadata_sha256": source["metadata_sha256"],
                 "source_png_sequence_sha256": source["png_sequence_sha256"],
                 "source_render_metadata": source["render"],
                 "encoding": {"crf": crf, "preset": preset, "encoder": "libx264", "threads": 1,
                              "command": ffmpeg_command(ffmpeg, source, target, crf, overwrite, preset), **versions}}
        if overwrite:
            temporary.replace(target)
        else:
            os.link(temporary, target)
    print(f"Verified {condition}: {verified['frame_count']} frames, {verified['duration_seconds']:.6f} s -> {target}", flush=True)
    return entry


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--condition", help="Condition ID from generated trajectory metadata")
    selection.add_argument("--all", action="store_true", help="Require and encode exactly eight conditions")
    parser.add_argument("--trajectory-dir", type=Path, default=ROOT / "stimuli/generated/trajectories")
    parser.add_argument("--frames-dir", type=Path, default=ROOT / "results/stimuli/final/pngs")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "stimuli/generated/videos")
    parser.add_argument("--crf", type=int, default=15, choices=range(52), metavar="0..51")
    parser.add_argument("--preset", default="slow", choices=("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"))
    parser.add_argument("--hold-start", type=float, default=0, help="Extra seconds displaying the first frame")
    parser.add_argument("--hold-end", type=float, default=0, help="Extra seconds displaying the final frame")
    parser.add_argument("--overwrite", action="store_true", help="Explicitly allow replacement of existing selected videos")
    parser.add_argument("--dry-run", action="store_true", help="Validate sources and print commands; write nothing")
    return parser.parse_args(argv)


def main(argv=None):
    args = arguments(argv)
    catalog = discover(args.trajectory_dir.resolve())
    require(not args.all or len(catalog) == 8,
            f"--all requires exactly eight unique enabled conditions; found {len(catalog)}: {', '.join(catalog)}")
    require(args.all or args.condition in catalog, f"Unknown condition: {args.condition}")
    selected = sorted(catalog) if args.all else [args.condition]
    sources = [validate_source(c, catalog[c], args.frames_dir.resolve()) for c in selected]
    matching_sources(sources)
    sources = [with_holds(s, args.hold_start, args.hold_end) for s in sources]
    output = args.output_dir.resolve()
    for source in sources:
        target = output / (source["condition_id"] + ".mp4")
        require(args.overwrite or not target.exists(), f"{target} already exists; use --overwrite explicitly")
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    require(ffmpeg and ffprobe, "Both ffmpeg and ffprobe must be installed and on PATH")
    for source in sources:
        print(f"Validated {source['condition_id']}: {source['frame_count']} frames, {source['fps']} fps, {source['resolution']}", flush=True)
    if args.dry_run:
        for source in sources:
            print(shlex.join(ffmpeg_command(ffmpeg, source, output / (source["condition_id"] + ".mp4"), args.crf, args.overwrite, args.preset)))
        return
    versions = {name: subprocess.run([tool, "-version"], check=True, capture_output=True, text=True).stdout.splitlines()[0]
                for name, tool in (("ffmpeg", ffmpeg), ("ffprobe", ffprobe))}
    output.mkdir(parents=True, exist_ok=True)
    lock = output / ".encode.lock"
    try:
        lock_file = lock.open("x")
    except FileExistsError:
        raise ValueError(f"{lock} exists; another encoder may be running. Remove only after confirming it has stopped.") from None
    try:
        with lock_file:
            lock_file.write(f"{os.getpid()}\n")
        manifest_path = output / "video_manifest.json"
        entries = read_manifest(manifest_path)
        require(set(entries) <= set(catalog), "Video manifest contains conditions absent from current trajectory metadata")
        # Preserve and re-probe unselected entries when updating one condition.
        for condition, entry in entries.items():
            if condition not in selected:
                source = validate_source(condition, catalog[condition], args.frames_dir.resolve())
                source = with_holds(source, args.hold_start, args.hold_end)
                matching_sources([sources[0], source])
                require(all(entry.get(k, 0) == source[k] for k in ("hold_start_frames", "hold_end_frames")),
                        f"{condition}: existing endpoint holds differ; rebuild all conditions with the same holds")
                require(entry["source_render_metadata_sha256"] == source["metadata_sha256"],
                        f"{condition}: existing manifest has stale render metadata")
                require(entry["video_sha256"] == sha256(output / entry["video_path"]),
                        f"{condition}: existing video differs from its manifest")
                entries[condition] = {**entry, **probe_video(ffprobe, output / entry["video_path"], source)}
        # Drop selected old records in memory; add each back only after verification.
        entries = {c: e for c, e in entries.items() if c not in selected}
        for source in sources:
            condition = source["condition_id"]
            entry = encode_condition(source, output, ffmpeg, ffprobe, versions, args.crf, args.overwrite, args.preset)
            entries[condition] = entry
            save_manifest(manifest_path, entries, catalog)
        matching_videos(entries.values())
        require(not args.all or len(entries) == 8, "Expected eight verified videos")
        save_manifest(manifest_path, entries, catalog)
        print(f"Complete: {len(sources)} video(s) encoded and verified. Manifest: {manifest_path}", flush=True)
    finally:
        lock.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
