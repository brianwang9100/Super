#!/usr/bin/env python3
"""Local-only preview discovery, export and parity; no baseline writes or uploads."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
from prepare_renderer import prepare
from verify import INVENTORY, verify_exports

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def output(*command):
    return subprocess.check_output(command, text=True, cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', nargs='?', help='Dedicated simulator UUID; otherwise find or create it')
    parser.add_argument('--argos', action='store_true',
                        help='Publish verified PNGs for new Argos baselines; report legacy pixel differences')
    args = parser.parse_args()
    screenshots = ROOT / 'screenshots'
    if args.argos:
        if screenshots.is_symlink():
            sys.exit('Refusing to replace a symlink at screenshots')
        if screenshots.exists():
            shutil.rmtree(screenshots)
    if output('xcodebuild', '-version').strip() != 'Xcode 26.4.1\nBuild version 17E202':
        sys.exit('Refusing capture: expected Xcode 26.4.1 / 17E202')
    if output('xcodegen', '--version').strip() != 'Version: 2.45.4':
        sys.exit('Expected XcodeGen 2.45.4')
    runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    matches = [r for r in runtimes if r['identifier'].endswith('iOS-26-4')]
    if len(matches) != 1 or matches[0]['buildversion'] != '23E254a' or not matches[0]['isAvailable']:
        sys.exit('Refusing capture: expected only iOS 26.4.1 build 23E254a for the 26.4 identifier')
    disks = json.loads(output('xcrun', 'simctl', 'runtime', 'list', '-j'))
    minor_disks = [r for r in disks.values() if r.get('runtimeIdentifier', '').endswith('iOS-26-4')]
    if len(minor_disks) != 1 or minor_disks[0].get('build') != '23E254a':
        sys.exit('Refusing capture: ambiguous or stale iOS 26.4 runtime disk images')
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', '-j'))['devices']
    expected_name = f'SB-{ROOT.parent.name}-preview-pilot'
    simulator = args.simulator or os.environ.get('ARGOS_SIMULATOR_UDID')
    if not simulator:
        candidates = [d for d in devices.get(matches[0]['identifier'], []) if d['name'] == expected_name]
        if len(candidates) > 1:
            sys.exit('Multiple dedicated simulators; specify ARGOS_SIMULATOR_UDID')
        simulator = candidates[0]['udid'] if candidates else output(
            'xcrun', 'simctl', 'create', expected_name, 'iPhone 17', matches[0]['identifier']).strip()
        devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', '-j'))['devices']
    selected = [d for d in devices.get(matches[0]['identifier'], []) if d['udid'] == simulator]
    if (len(selected) != 1 or selected[0]['name'] != expected_name
            or selected[0]['deviceTypeIdentifier'] != 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
            or not selected[0]['isAvailable']):
        sys.exit(f'Expected dedicated {expected_name} iPhone 17 on pinned runtime')
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
    (run / 'environment.json').write_text(json.dumps({'xcode': '26.4.1', 'build': '17E202',
        'runtime': matches[0], 'runtimeDisk': minor_disks[0], 'device': selected[0],
        'rendererPatchSHA256': patch_digest}, indent=2))
    subprocess.run(['xcodegen', 'generate', '--spec', str(generated_spec), '--project', str(build)],
                   cwd=ROOT, check=True)
    command = ['xcodebuild', 'test', '-project', str(build / 'PreviewPilot.xcodeproj'),
               '-scheme', 'PreviewPilot', '-destination', f'platform=iOS Simulator,id={simulator}',
               '-derivedDataPath', str(build / 'DerivedData'), '-parallel-testing-enabled', 'NO']
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('TEST_RUNNER_SNAPSHOT', 'SNAPSHOT'))}
    for mode, key, path in [('discovery', 'TEST_RUNNER_SNAPSHOTS_ALL_IMAGE_NAMES_FILE', run / 'names.txt'),
                            ('export', 'TEST_RUNNER_SNAPSHOTS_EXPORT_DIR', run / 'images')]:
        with (run / f'{mode}.log').open('w') as log:
            subprocess.run(command + ['-resultBundlePath', str(run / f'{mode}.xcresult')], cwd=ROOT,
                           env={**environment, key: str(path)}, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run([sys.executable, str(HERE / 'verify.py'),
                        '--names' if mode == 'discovery' else '--exports', str(path)], check=True)
    result = subprocess.run(['swift', str(HERE / 'ComparePreviewImages.swift'), str(ROOT),
                             str(run / 'images'), str(run / 'parity.json')], cwd=ROOT)
    if args.argos and result.returncode in (0, 1):
        validate_migration_report(json.loads((run / 'parity.json').read_text()))
        verify_exports(run / 'images')
        images = sorted((run / 'images').glob('*.png'))
        if any(path.stat().st_size > 50_000_000 for path in images):
            sys.exit('Argos screenshot exceeds 50 MB; refusing a partial upload set')
        screenshots.mkdir()
        for path in images:
            shutil.copy2(path, screenshots / path.name)
        print(f'Prepared {len(images)} native screenshots in {screenshots}; legacy report: {run / "parity.json"}')
    elif result.returncode:
        sys.exit(f'Legacy parity failed; capture evidence and comparison: {run / "parity.json"}')


def validate_migration_report(rows):
    expected = {row['image'] for row in json.loads(INVENTORY.read_text())}
    if (len(rows) != len(expected) or {row.get('image') for row in rows} != expected
            or any(row.get('status') not in ('exact', 'pixel-mismatch') for row in rows)):
        raise ValueError('Migration permits legacy pixel differences only; comparison must be complete and valid')


if __name__ == '__main__':
    main()
