#!/usr/bin/env python3
"""Compare every visual shard to committed baselines and collect validated captures."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from capture import capture_environment
from pipeline import ROOT, PACKAGES, aggregate, identity, inventories, write_bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', action='store_true', help='Explicitly record all baselines locally')
    args = parser.parse_args()
    capture_environment(args.record)  # Reject CI recording before any filesystem mutation.
    record_args = ['--record'] if args.record else []
    destination = ROOT / 'screenshots'
    if destination.is_symlink():
        raise ValueError('Refusing to replace a symlink at screenshots')
    if destination.exists():
        shutil.rmtree(destination)
    for folder in ('Scripts/PreviewPilot', 'Scripts/VisualTesting'):
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', folder, '-p', 'test_*.py'],
                       cwd=ROOT, check=True)
    expected = inventories()
    build = ROOT / '.build/VisualTesting'
    build.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='complete-', dir=build))
    artifacts = evidence / 'artifacts'
    artifacts.mkdir()
    invocation = identity()
    print(f'Complete capture evidence: {evidence}', flush=True)
    subprocess.run([sys.executable, str(ROOT / 'Scripts/PreviewPilot/run.py'),
                    '--output', str(evidence / 'native-images'), *record_args], cwd=ROOT, check=True)
    write_bundle(evidence / 'native-images', artifacts / 'visual-native', 'native',
                 expected['native'], invocation)
    for package in PACKAGES:
        subprocess.run([sys.executable, str(Path(__file__).with_name('capture.py')), package,
                        '--output', str(artifacts / f'visual-{package}'), *record_args], cwd=ROOT, check=True)
    if identity() != invocation:
        raise ValueError('Checkout changed during capture; rerun against one revision')
    aggregate(artifacts, destination, expected, invocation)
    print(f'Validated {sum(map(len, expected.values()))} repository snapshots in {destination}', flush=True)


if __name__ == '__main__':
    main()
