#!/usr/bin/env python3
"""Capture native previews and compare them with repository snapshots."""
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
from comparison import compare, record, require_local_recording

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def output(*command):
    return subprocess.check_output(command, text=True, cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', nargs='?', help='Dedicated simulator UUID; otherwise find or create it')
    parser.add_argument('--output', type=Path, help='Optional fresh directory for validated PNG captures')
    parser.add_argument('--record', action='store_true', help='Explicitly replace local repository baselines; forbidden in CI')
    args = parser.parse_args()
    if args.record:
        require_local_recording()
    screenshots = args.output
    if screenshots is not None and (screenshots.exists() or screenshots.is_symlink()):
        sys.exit('Explicit capture output already exists; choose a fresh directory')
    pins = read_pin(ROOT)
    runtime_suffix = 'iOS-' + '-'.join(pins['ios_version'].split('.')[:2])
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
    requested = args.simulator or os.environ.get('VISUAL_SIMULATOR_UDID')
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
    verify_exports(run / 'images')
    if screenshots is not None:
        screenshots.mkdir(parents=True, exist_ok=False)
        for path in sorted((run / 'images').glob('*.png')):
            shutil.copy2(path, screenshots / path.name)
        print(f'Staged native screenshots in {screenshots}; evidence: {run}', flush=True)
    operation = record if args.record else compare
    summary = operation(run / 'images', run / 'comparison')
    if summary.get('acceptedRoundingImages'):
        print(f'Accepted bounded RGB rounding in {summary["acceptedRoundingPixels"]} pixels '
              f'across {summary["acceptedRoundingImages"]} images; diff evidence: {run / "comparison"}')
    print(f'{"Recorded" if args.record else "Compared"} {len(summary["images"])} native snapshots; evidence: {run}')


if __name__ == '__main__':
    main()
