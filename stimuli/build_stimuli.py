"""Build selected stimuli: export physics, render PNGs, encode MP4s and probe stills.

Physics/conditions: stimuli/config/stimuli.toml. Rendering/intro: settings below.
Every selected condition is rebuilt; there are no fingerprints or cache schemas.
"""
import argparse
from contextlib import contextmanager
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
try:
    import tomllib
except ImportError:
    import tomli as tomllib  # Python <3.11

RENDERING = {"resolution": [1920, 1080], "engine": "EEVEE", "samples": 64}
ENCODING = {"crf": 15, "preset": "slow", "empty_scene_seconds": .8, "object_preview_seconds": .2}
ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'stimuli/config/stimuli.toml'
EXPORTER = ROOT / 'scripts/export_stimulus_trajectories.jl'
RENDERER = ROOT / 'stimuli/blender/render_stimuli.py'
ENCODER = ROOT / 'stimuli/video/encode_videos.py'
TRAJECTORIES = ROOT / 'stimuli/generated/trajectories'
FRAMES = ROOT / 'results/stimuli/final/pngs'
VIDEOS = ROOT / 'stimuli/generated/videos'
PREVIEW = ROOT / 'results/stimuli/preview'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def module(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    result = importlib.util.module_from_spec(spec)
    previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(result)
    finally:
        sys.dont_write_bytecode = previous
    return result


def run(command):
    print('$ ' + shlex.join([str(x) for x in command]), flush=True)
    subprocess.run([str(x) for x in command], cwd=ROOT, check=True)


def toml_text(config):
    def table(values):
        return [json.dumps(k) + ' = ' + json.dumps(v, allow_nan=False) for k, v in values.items()]
    lines = ['[materials]', *table(config['materials']), '', '[defaults]', *table(config['defaults'])]
    for condition in config['conditions']:
        lines += ['', '[[conditions]]', *table(condition)]
    return '\n'.join(lines) + '\n'


@contextmanager
def lock():
    path = ROOT / 'stimuli/generated/build.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        file = path.open('x')
    except FileExistsError:
        raise ValueError(f'{path} exists; check for an active build before removing a stale lock.') from None
    try:
        with file:
            file.write(str(os.getpid()) + '\n')
        yield
    finally:
        path.unlink(missing_ok=True)


def dependencies(blender_override):
    names = {name: shutil.which(name) for name in ('julia', 'ffmpeg', 'ffprobe')}
    names['blender'] = blender_override or shutil.which('blender')
    mac_blender = Path('/Applications/Blender.app/Contents/MacOS/Blender')
    if not names['blender'] and mac_blender.exists():
        names['blender'] = str(mac_blender)
    for name, path in names.items():
        require(path and Path(path).is_file(), f'Missing dependency: {name}')
    return names


def build(args):
    config = tomllib.loads(CONFIG.read_text())
    enabled = [c for c in config['conditions'] if c.get('enabled', config['defaults'].get('enabled', True))]
    ids = [c['condition_id'] for c in enabled]
    require(ids and len(ids) == len(set(ids)), 'Conditions must have unique IDs')
    require(all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', c) for c in ids), 'Unsafe condition ID')
    if args.practice:
        require('practice' in config, 'No practice stimulus configured')
        practice = config['practice']
        require(practice['condition_id'] not in ids, 'Practice ID must differ from main condition IDs')
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', practice['condition_id']), 'Unsafe practice ID')
        selected = [practice]
    else:
        selected = enabled if args.all else [c for c in enabled if c['condition_id'] == args.condition]
    require(selected, 'Unknown or disabled condition')
    require(not args.preview or len(selected) == 1, '--preview requires one stimulus (--condition or --practice)')
    config['conditions'] = selected
    tools = dependencies(args.blender)
    julia = [tools['julia'], '--startup-file=no', '--compiled-modules=existing', f'--project={ROOT}']
    with tempfile.TemporaryDirectory(prefix='stimuli-build-') as temporary:
        selected_config = Path(temporary) / 'stimuli.toml'
        selected_config.write_text(toml_text(config))
        # Parse the actual Julia configuration without starting physics.
        run([*julia, '-e', 'using GalileoMSC; specs=load_stimuli(ARGS[1]); println("Validated ", length(specs), " stimulus configurations.")', selected_config])
        trajectory_dir = PREVIEW / 'trajectories' if args.preview else TRAJECTORIES
        frame_dir = PREVIEW / 'pngs' if args.preview else FRAMES
        export = [*julia, EXPORTER, '--config', selected_config, '--output-dir', trajectory_dir]
        renders = [[tools['blender'], '--background', '--factory-startup', '--python-exit-code', '1',
                    '--python', RENDERER, '--', '--trajectory', trajectory_dir / f'{c["condition_id"]}.json',
                    '--output-dir', frame_dir, '--resolution', *map(str, RENDERING['resolution']),
                    '--engine', RENDERING['engine'], '--samples', str(RENDERING['samples']),
                    *(['--smoke'] if args.preview else [])] for c in selected]
        if args.dry_run:
            for command in [export, *renders]:
                print('$ ' + shlex.join(map(str, command)))
            print(f'{len(selected)} selected conditions; encoding: {ENCODING}; no physics or renders run.')
            return
        with lock():
            print('[1/3] Exporting selected trajectories at the configured physics frequency.', flush=True)
            run(export)
            encoder = module(ENCODER)
            entries = []
            for condition, render in zip(selected, renders):
                name = condition['condition_id']
                print(f'[2/3] Rendering {name}.', flush=True)
                run(render)
                if args.preview:
                    continue
                print(f'[3/3] Encoding {name}, checking duration, saving four probe stills.', flush=True)
                path = trajectory_dir / f'{name}.json'
                source = encoder.with_intro(encoder.validate_source(name, (path, encoder.read_json(path)), frame_dir),
                                             ENCODING['empty_scene_seconds'], ENCODING['object_preview_seconds'])
                entries.append(encoder.encode_condition(tools['ffmpeg'], tools['ffprobe'], source, VIDEOS,
                                                         ENCODING['crf'], ENCODING['preset']))
                encoder.save_manifest(VIDEOS, [] if args.practice else entries, ids,
                                      practice_entry=entries[-1] if args.practice else None)
            print(f'Finished: {len(selected)} conditions -> {frame_dir if args.preview else VIDEOS}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--all', action='store_true', help='Build every enabled condition')
    selection.add_argument('--condition', help='Build one condition; manifest will contain only that condition')
    selection.add_argument('--practice', action='store_true', help='Build only the separate practice stimulus; preserve main videos and manifest entries')
    parser.add_argument('--preview', action='store_true', help='One trajectory plus empty/initial/contact/final PNGs; no MP4 or production manifest')
    parser.add_argument('--dry-run', action='store_true', help='Check dependencies/config and print commands; no simulations/renders')
    parser.add_argument('--blender', help='Blender executable override')
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Build failed: {error}\n')


if __name__ == '__main__':
    main()
