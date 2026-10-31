"""Encode action PNGs plus the empty-scene/object intro, and save exact probe stills."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROBE_OFFSETS_MS = {"baseline": -1000, "preCollision": -200, "collision": 200, "postCollision": 1000}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text())


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def validate_source(condition, trajectory, frames_root):
    path, data = trajectory
    directory = frames_root / condition
    render = read_json(directory / "render_metadata.json")
    count = data["timing"]["frame_count"]
    require(render["condition_id"] == condition and render["stimulus"] == data["stimulus"],
            f"{condition}: render/trajectory settings differ; rebuild the render")
    require(render["status"] == "complete" and render["mode"] == "frames" and
            render["rendered_frames"] == list(range(count)), f"{condition}: incomplete render")
    require({p.name for p in directory.glob('frame_*.png')} == {f'frame_{i:04d}.png' for i in range(count)},
            f"{condition}: missing or extra action PNGs")
    resolution = render["resolution"]
    require(all(type(x) is int and x > 0 and x % 2 == 0 for x in resolution), "Resolution must be positive/even")
    for name in ("frame_0000.png", f"frame_{count - 1:04d}.png", "empty_scene.png"):
        with (directory / name).open('rb') as file:
            header = file.read(24)
        require(header[:8] == b'\x89PNG\r\n\x1a\n' and list(struct.unpack('>II', header[16:24])) == resolution,
                f"{condition}/{name}: invalid PNG or resolution")
    require(render["fps"] == data["timing"]["video_fps"], "Render FPS mismatch")
    return {"condition_id": condition, "directory": directory, "trajectory": data,
            "fps": Fraction(str(render["fps"])), "frame_count": count, "resolution": resolution}


def with_intro(source, empty_seconds=0.8, preview_seconds=0.2):
    counts = []
    for seconds in (empty_seconds, preview_seconds):
        count = Fraction(str(seconds)) * source["fps"]
        require(count >= 0 and count.denominator == 1, "Intro durations must be nonnegative whole-frame intervals")
        counts.append(int(count))
    require('trajectory_frame_count' not in source, "Intro already applied")
    return {**source, "trajectory_frame_count": source["frame_count"],
            "empty_scene_frames": counts[0], "object_preview_frames": counts[1],
            "trajectory_frame_offset": sum(counts), "frame_count": source["frame_count"] + sum(counts)}


def probe_frames(source):
    fps = float(source['fps'])
    contact = Fraction(source['trajectory']['collision']['first_contact_substep'],
                       source['trajectory']['timing']['physics_hz'])
    result = {}
    for name, offset in PROBE_OFFSETS_MS.items():
        # Round the exact physics contact time plus offset; ties go to the later frame.
        target = (contact + Fraction(offset, 1000)) * source["fps"] + Fraction(1, 2)
        action_frame = target.numerator // target.denominator
        require(0 <= action_frame < source['trajectory_frame_count'], f"{name}: probe outside action")
        frame = source['trajectory_frame_offset'] + action_frame
        result[name] = {"frame": frame, "trajectory_frame": action_frame,
                        "time_seconds": frame / fps, "offset_ms": offset,
                        "image_path": f"{source['condition_id']}_{name}.png"}
    return result


def ffmpeg_command(ffmpeg, source, destination, crf=15, overwrite=False, preset='slow'):
    rate = str(source['fps'])
    command = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-y' if overwrite else '-n']
    empty, preview = source['empty_scene_frames'], source['object_preview_frames']
    if empty:
        command += ['-loop', '1', '-framerate', rate, '-i', str(source['directory'] / 'empty_scene.png')]
    command += ['-framerate', rate, '-start_number', '0', '-i', str(source['directory'] / 'frame_%04d.png')]
    if empty:
        filters = (f'[0:v]trim=end_frame={empty},setpts=PTS-STARTPTS[empty];'
                   f'[1:v]tpad=start_mode=clone:start={preview},setpts=PTS-STARTPTS[action];'
                   '[empty][action]concat=n=2:v=1:a=0[out]')
        command += ['-filter_complex_threads', '1', '-filter_complex', filters, '-map', '[out]']
    else:
        command += ['-vf', f'tpad=start_mode=clone:start={preview}', '-map', '0:v:0']
    return command + ['-an', '-c:v', 'libx264', '-preset', preset, '-crf', str(crf),
                      '-threads:v', '1', '-filter_threads', '1', '-pix_fmt', 'yuv420p',
                      '-r', rate, '-fps_mode', 'cfr', '-frames:v', str(source['frame_count']),
                      '-movflags', '+faststart', str(destination)]


def probe_video(ffprobe, path, source):
    command = [ffprobe, '-v', 'error', '-count_frames', '-show_entries',
               'stream=codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,nb_read_frames,duration:format=duration',
               '-of', 'json', str(path)]
    data = json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)
    require(len(data['streams']) == 1, 'Expected one video stream without audio')
    stream = data['streams'][0]
    require(stream['codec_name'] == 'h264' and stream['pix_fmt'] == 'yuv420p', 'Unexpected video format')
    require([stream['width'], stream['height']] == source['resolution'], 'Incorrect video resolution')
    require(Fraction(stream['avg_frame_rate']) == source['fps'], 'Incorrect video FPS')
    require(int(stream['nb_read_frames']) == source['frame_count'], 'Incorrect video frame count')
    duration = float(source['frame_count'] / source['fps'])
    require(abs(float(data['format']['duration']) - duration) < 1e-5, 'Incorrect video duration')
    return {"fps": float(source['fps']), "frame_count": source['frame_count'],
            "resolution": source['resolution'], "duration_seconds": duration,
            "trajectory_frame_count": source['trajectory_frame_count'],
            "trajectory_frame_offset": source['trajectory_frame_offset'],
            "empty_scene_frames": source['empty_scene_frames'], "object_preview_frames": source['object_preview_frames']}


def encode_condition(ffmpeg, ffprobe, source, output_dir, crf=15, preset='slow'):
    condition = source['condition_id']
    probes = probe_frames(source)
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f'.{condition}-', dir=output_dir) as temporary:
        temporary = Path(temporary)
        video = temporary / f'{condition}.mp4'
        subprocess.run(ffmpeg_command(ffmpeg, source, video, crf, True, preset), check=True)
        entry = probe_video(ffprobe, video, source)
        expression = '+'.join(f'eq(n,{p["frame"]})' for p in probes.values())
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(video),
                        '-vf', f"select='{expression}'", '-fps_mode', 'vfr', '-frames:v', str(len(probes)),
                        '-threads:v', '1', '-filter_threads', '1', '-start_number', '0',
                        str(temporary / 'probe_%02d.png')], check=True)
        for i, probe in enumerate(probes.values()):
            (temporary / f'probe_{i:02d}.png').replace(output_dir / probe['image_path'])
        video.replace(output_dir / video.name)
    return {"condition_id": condition, "video_path": f'{condition}.mp4', **entry,
            "first_contact_time_seconds": source['trajectory']['collision']['first_contact_time_seconds'],
            "probes": probes}


def save_manifest(output_dir, entries, expected_ids, *, practice_entry=None):
    # Main subset builds advertise their fresh outputs. Practice is independent:
    # building it preserves the existing main manifest, and vice versa.
    path = output_dir / 'video_manifest.json'
    previous = read_json(path) if path.exists() else {}
    manifest = {
        "complete_condition_set": {e['condition_id'] for e in entries} == set(expected_ids),
        "expected_condition_count": len(expected_ids),
        "duration_policy": 'empty scene, stationary objects, fixed action; no endpoint hold',
        "conditions": entries}
    if practice_entry is not None:
        manifest = previous or manifest
        manifest['practice'] = practice_entry
    elif 'practice' in previous:
        manifest['practice'] = previous['practice']
    atomic_json(path, manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--all', action='store_true')
    inputs.add_argument('--condition')
    parser.add_argument('--trajectory-dir', type=Path, default=ROOT / 'stimuli/generated/trajectories')
    parser.add_argument('--frames-dir', type=Path, default=ROOT / 'results/stimuli/final/pngs')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'stimuli/generated/videos')
    parser.add_argument('--empty-scene-seconds', type=float, default=.8)
    parser.add_argument('--object-preview-seconds', type=float, default=.2)
    parser.add_argument('--crf', type=int, default=15)
    parser.add_argument('--preset', default='slow')
    args = parser.parse_args()
    try:
        import tomllib
    except ImportError:
        import tomli as tomllib
    config = tomllib.loads((ROOT / 'stimuli/config/stimuli.toml').read_text())
    ids = [c['condition_id'] for c in config['conditions'] if c.get('enabled', config['defaults'].get('enabled', True))]
    selected = ids if args.all else [args.condition]
    require(all(c in ids for c in selected), 'Unknown or disabled condition')
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    require(ffmpeg and ffprobe, 'FFmpeg and FFprobe required')
    entries = []
    for condition in selected:
        path = args.trajectory_dir / f'{condition}.json'
        source = with_intro(validate_source(condition, (path, read_json(path)), args.frames_dir),
                            args.empty_scene_seconds, args.object_preview_seconds)
        entries.append(encode_condition(ffmpeg, ffprobe, source, args.output_dir, args.crf, args.preset))
    save_manifest(args.output_dir, entries, ids)
    print(f'Encoded {len(entries)} videos -> {args.output_dir}')


if __name__ == '__main__':
    main()
