#!/usr/bin/env python3
"""Discover and validate native captures locally; Argos owns visual comparison."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worktree_simulator import read_pin
from prepare_renderer import prepare
from verify import verify_exports

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def output(*command):
    return subprocess.check_output(command, text=True, cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', nargs='?', help='Dedicated simulator UUID; otherwise find or create it')
    parser.add_argument('--argos', action='store_true',
                        help='Stage verified PNGs in screenshots for a separate Argos CLI upload')
    parser.add_argument('--output', type=Path, help='Fresh PNG directory; requires --argos')
    args = parser.parse_args()
    if args.output is not None and not args.argos:
        parser.error('--output requires --argos')
    pins = read_pin(ROOT)
    runtime_suffix = 'iOS-' + '-'.join(pins['ios_version'].split('.')[:2])
    screenshots = args.output if args.output is not None else ROOT / 'screenshots'
    if args.argos:
        if screenshots.is_symlink():
            sys.exit('Refusing to replace a symlink at screenshots')
        if screenshots.exists():
            if args.output is not None:
                sys.exit('Explicit capture output already exists; choose a fresh directory')
            shutil.rmtree(screenshots)
    if output('xcodebuild', '-version').strip() != f'Xcode {pins["xcode_version"]}\nBuild version {pins["xcode_build"]}':
        sys.exit('Refusing capture: Xcode does not match simulator-pins.json')
    if output('xcodegen', '--version').strip() != f'Version: {pins["xcodegen_version"]}':
        sys.exit('XcodeGen does not match simulator-pins.json')
    runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    matches = [r for r in runtimes if r['identifier'].endswith(runtime_suffix)]
    if (len(matches) != 1 or matches[0]['buildversion'] != pins['ios_build']
            or matches[0].get('version') != pins['ios_version'] or not matches[0]['isAvailable']):
        sys.exit('Refusing capture: expected only the pinned iOS runtime version and build')
    disks = json.loads(output('xcrun', 'simctl', 'runtime', 'list', '-j'))
    minor_disks = [r for r in disks.values() if r.get('runtimeIdentifier', '').endswith(runtime_suffix)]
    if len(minor_disks) != 1 or minor_disks[0].get('build') != pins['ios_build']:
        sys.exit('Refusing capture: ambiguous or stale pinned runtime disk images')
    simulator = output(sys.executable, str(ROOT / 'Scripts/worktree_simulator.py'),
                       'ensure', '--repo', str(ROOT)).strip()
    requested = args.simulator or os.environ.get('ARGOS_SIMULATOR_UDID')
    if requested and requested != simulator:
        sys.exit('Expected the registered worktree simulator; use Scripts/worktree_simulator.py ensure')
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', '-j'))['devices']
    selected = [d for d in devices.get(matches[0]['identifier'], []) if d['udid'] == simulator]
    if (len(selected) != 1
            or selected[0]['deviceTypeIdentifier'] != 'com.apple.CoreSimulator.SimDeviceType.' + pins['device'].replace(' ', '-')
            or not selected[0]['isAvailable']):
        sys.exit('Expected registered worktree simulator on pinned device and runtime')
    build = ROOT / '.build' / 'PreviewPilot'
    build.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run-', dir=build))
    print(f'Evidence: {run}', flush=True)
    renderer, patch_digest = prepare()
    # XcodeGen supports JSON specs. This override keeps production package graphs untouched.
    generated_spec = run / 'project.json'
    generated_spec.write_text(json.dumps({
        'include': [str(HERE / 'project.yml')],
        'packages': {'SnapshotPreviews': {'path': str(renderer), 'url': None, 'revision': None}}
    }))
    (run / 'environment.json').write_text(json.dumps({'xcode': pins['xcode_version'], 'build': pins['xcode_build'],
        'runtime': matches[0], 'runtimeDisk': minor_disks[0], 'device': selected[0],
        'rendererPatchSHA256': patch_digest}, indent=2))
    subprocess.run(['xcodegen', 'generate', '--spec', str(generated_spec), '--project', str(build)],
                   cwd=ROOT, check=True)
    resolved = build / 'PreviewPilot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    resolved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HERE / 'Package.resolved', resolved)
    command = ['xcodebuild', 'test', '-project', str(build / 'PreviewPilot.xcodeproj'),
               '-scheme', 'PreviewPilot', '-destination', f'platform=iOS Simulator,id={simulator}',
               '-derivedDataPath', str(build / 'DerivedData'), '-parallel-testing-enabled', 'NO',
               '-testLanguage', 'en', '-testRegion', 'US', '-onlyUsePackageVersionsFromResolvedFile']
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('TEST_RUNNER_SNAPSHOT', 'SNAPSHOT'))}
    for mode, key, path in [('discovery', 'TEST_RUNNER_SNAPSHOTS_ALL_IMAGE_NAMES_FILE', run / 'names.txt'),
                            ('export', 'TEST_RUNNER_SNAPSHOTS_EXPORT_DIR', run / 'images')]:
        with (run / f'{mode}.log').open('w') as log:
            subprocess.run(command + ['-resultBundlePath', str(run / f'{mode}.xcresult')], cwd=ROOT,
                           env={**environment, key: str(path)}, stdout=log, stderr=subprocess.STDOUT, check=True)
        if json.loads(resolved.read_text())['pins'] != json.loads((HERE / 'Package.resolved').read_text())['pins']:
            raise ValueError('Swift package resolution changed during capture')
        subprocess.run([sys.executable, str(HERE / 'verify.py'),
                        '--names' if mode == 'discovery' else '--exports', str(path)], check=True)
    subprocess.run(['swift', str(HERE / 'ValidatePreviewImages.swift'),
                    str(run / 'images')], cwd=ROOT, check=True)
    if args.argos:
        verify_exports(run / 'images')
        images = sorted((run / 'images').glob('*.png'))
        if any(path.stat().st_size > 50_000_000 for path in images):
            sys.exit('Argos screenshot exceeds 50 MB; refusing a partial upload set')
        screenshots.mkdir(parents=True)
        for path in images:
            shutil.copy2(path, screenshots / path.name)
        print(f'Prepared {len(images)} native screenshots in {screenshots}; evidence: {run}')


if __name__ == '__main__':
    main()
