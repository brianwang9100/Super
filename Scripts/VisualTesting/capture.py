#!/usr/bin/env python3
"""Render existing package visual fixtures serially on the registered simulator."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from pipeline import ROOT, PACKAGES, identity, inventories, require_new_output, write_bundle
sys.path.insert(0, str(ROOT / 'Scripts'))
from worktree_simulator import read_pin


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True, timeout=120).strip()


def discover_suites(root, package):
    folder = root / f'Packages/{package}/Tests/{package}Tests/UI/Snapshots'
    files = sorted(folder.glob('*SnapshotTests.swift'))
    if package == 'Core':
        files.append(folder.parent / 'Support/VisualSnapshotExporterTests.swift')
    if package == 'Chat':
        # This UIKit behavior suite protects the focused-turn visual fixture;
        # macOS swift test cannot execute it.
        files.append(folder.parent / 'MessageListDeclarativeScrollTests.swift')
    if not files:
        raise ValueError(f'No visual suites found for {package}')
    suites = []
    for path in files:
        if not path.is_file():
            raise ValueError(f'Missing required capture suite: {path}')
        source = path.read_text()
        matches = re.findall(r'@Suite\((.*?)\)\s*(?:@MainActor\s*)?(?:final\s+)?(?:struct|class)\s+(\w+)',
                             source, re.DOTALL)
        declarations = len(re.findall(r'(?m)^\s*@Suite\b', source))
        if (not matches or len(matches) != declarations
                or any('.serialized' not in attributes for attributes, _ in matches)):
            raise ValueError(f'Capture suites must explicitly use .serialized: {path}')
        suites.extend(name for _, name in matches)
    if len(set(suites)) != len(suites):
        raise ValueError(f'Duplicate suite declaration in {package}')
    return suites


def simulator_environment():
    pins = read_pin(ROOT)
    runtime_suffix = 'iOS-' + '-'.join(pins['ios_version'].split('.')[:2])
    if output('xcodebuild', '-version') != f'Xcode {pins["xcode_version"]}\nBuild version {pins["xcode_build"]}':
        raise ValueError('Xcode does not match simulator-pins.json')
    if output('xcodegen', '--version') != f'Version: {pins["xcodegen_version"]}':
        raise ValueError('XcodeGen does not match simulator-pins.json')
    runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    matches = [r for r in runtimes if r['identifier'].endswith(runtime_suffix)]
    if (len(matches) != 1 or matches[0]['buildversion'] != pins['ios_build']
            or matches[0].get('version') != pins['ios_version'] or not matches[0]['isAvailable']):
        raise ValueError('Expected only the available pinned iOS runtime version and build')
    disks = json.loads(output('xcrun', 'simctl', 'runtime', 'list', '-j'))
    disks = [r for r in disks.values() if r.get('runtimeIdentifier', '').endswith(runtime_suffix)]
    if len(disks) != 1 or disks[0].get('build') != pins['ios_build']:
        raise ValueError('Ambiguous or stale pinned iOS runtime disk')
    simulator = output(sys.executable, str(ROOT / 'Scripts/worktree_simulator.py'), 'ensure', '--repo', str(ROOT))
    if os.environ.get('VISUAL_SIMULATOR_UDID', simulator) != simulator:
        raise ValueError('VISUAL_SIMULATOR_UDID must identify the registered worktree simulator')
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', '-j'))['devices']
    selected = [d for d in devices.get(matches[0]['identifier'], []) if d['udid'] == simulator]
    if (len(selected) != 1 or not selected[0]['isAvailable']
            or selected[0]['deviceTypeIdentifier'] != 'com.apple.CoreSimulator.SimDeviceType.' + pins['device'].replace(' ', '-')):
        raise ValueError('Expected registered device on the pinned runtime')
    if selected[0]['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', simulator], check=True, timeout=120)
    # Fresh hosted simulators can spend several minutes migrating system data.
    # Keep readiness bounded and fail before testing if boot still cannot finish.
    subprocess.run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], check=True, timeout=900)
    return simulator, {'xcode': pins['xcode_version'], 'build': pins['xcode_build'], 'runtime': matches[0], 'device': selected[0]}


def test_count(result):
    summary = json.loads(output('xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)))
    return int(summary.get('passedTests', 0)) + int(summary.get('failedTests', 0))


def verify_resolution(resolved):
    expected = json.loads(Path(__file__).with_name('Package.resolved').read_text())['pins']
    if json.loads(resolved.read_text())['pins'] != expected:
        raise ValueError('Swift package resolution changed during capture')


def run_suites(command, suites, package, evidence, environment, runner=subprocess.run, resolved=None):
    for index, suite in enumerate(suites):
        result = evidence / f'{index:02d}-{suite}.xcresult'
        print(f'Capturing {package}/{suite} ({index+1}/{len(suites)})', flush=True)
        with (evidence / f'{index:02d}-{suite}.log').open('w') as log:
            runner(command + [f'-only-testing:{package}Tests/{suite}', '-resultBundlePath', str(result)],
                   cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
        if test_count(result) <= 0:
            raise ValueError(f'No tests executed for selected suite {package}/{suite}')
        if resolved is not None:
            verify_resolution(resolved)


def capture_environment(record=False, environ=None):
    """Pass explicit comparison policy through xcodebuild into the simulator."""
    source = dict(os.environ if environ is None else environ)
    ci = any(source.get(key, '').lower() not in ('', '0', 'false')
             for key in ('CI', 'GITHUB_ACTIONS'))
    if record and ci:
        raise ValueError('Snapshot recording is forbidden in CI')
    environment = {key: value for key, value in source.items()
                   if not key.startswith(('SNAPSHOT', 'TEST_RUNNER_SNAPSHOT', 'VISUAL_RECORD',
                                          'TEST_RUNNER_VISUAL_RECORD'))}
    environment['TEST_RUNNER_CI'] = 'true' if ci else 'false'
    environment['TEST_RUNNER_VISUAL_RECORD'] = '1' if record else '0'
    return environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', choices=PACKAGES)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--record', action='store_true', help='Explicitly replace package baselines locally')
    args = parser.parse_args()
    environment = capture_environment(args.record)
    destination = args.output.resolve()
    require_new_output(destination)
    invocation = identity()
    suites = discover_suites(ROOT, args.package)
    rows = inventories()[args.package]
    simulator, environment_info = simulator_environment()
    build = ROOT / '.build/VisualTesting'
    build.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix=f'run-{args.package}-', dir=build))
    images = evidence / 'images'
    images.mkdir()
    print(f'Evidence: {evidence}', flush=True)
    (evidence / 'environment.json').write_text(json.dumps(environment_info, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate'], cwd=ROOT, check=True, timeout=120)
    resolved = ROOT / 'Super.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    resolved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(__file__).with_name('Package.resolved'), resolved)
    options = ['-project', str(ROOT / 'Super.xcodeproj'), '-scheme', args.package,
               '-destination', f'platform=iOS Simulator,id={simulator}',
               '-derivedDataPath', str(build / f'DerivedData-{args.package}'),
               '-parallel-testing-enabled', 'NO', '-testLanguage', 'en', '-testRegion', 'US',
               '-enableCodeCoverage', 'YES', '-skipPackagePluginValidation',
               '-onlyUsePackageVersionsFromResolvedFile', 'CODE_SIGNING_ALLOWED=NO']
    with (evidence / 'build.log').open('w') as log:
        subprocess.run(['xcodebuild', 'build-for-testing'] + options, cwd=ROOT, check=True,
                       stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    verify_resolution(resolved)
    environment['TEST_RUNNER_SNAPSHOT_OUTPUT_DIR'] = str(images)
    environment['TEST_RUNNER_SNAPSHOT_ARTIFACTS'] = str(evidence / 'diffs')
    # One suite per invocation plus .serialized prevents Swift Testing interleaving
    # independently of XCTest's process-level parallel-testing switch.
    run_suites(['xcodebuild', 'test-without-building'] + options, suites, args.package, evidence,
               environment, resolved=resolved)
    if identity() != invocation:
        raise ValueError('Checkout changed during capture; rerun against one revision')
    write_bundle(images, destination, args.package, rows, invocation, environment_info)
    print(f'Validated {len(rows)} {args.package} screenshots: {destination}')


if __name__ == '__main__':
    main()
