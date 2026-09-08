#!/usr/bin/env python3
"""Capture every visual shard locally and publish only the complete upload folder."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from pipeline import ROOT, PACKAGES, aggregate, identity, inventories, write_bundle


def main():
    destination = ROOT / 'screenshots'
    if destination.is_symlink():
        raise ValueError('Refusing to replace a symlink at screenshots')
    if destination.exists():
        shutil.rmtree(destination)
    subprocess.run(['npm', 'run', 'test:visual:guards'], cwd=ROOT, check=True)
    expected = inventories()
    build = ROOT / '.build/VisualTesting'
    build.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='complete-', dir=build))
    artifacts = evidence / 'artifacts'
    artifacts.mkdir()
    invocation = identity()
    print(f'Complete capture evidence: {evidence}', flush=True)
    subprocess.run([sys.executable, str(ROOT / 'Scripts/PreviewPilot/run.py'), '--argos',
                    '--output', str(evidence / 'native-images')], cwd=ROOT, check=True)
    write_bundle(evidence / 'native-images', artifacts / 'visual-native', 'native',
                 expected['native'], invocation)
    for package in PACKAGES:
        subprocess.run([sys.executable, str(Path(__file__).with_name('capture.py')), package,
                        '--output', str(artifacts / f'visual-{package}')], cwd=ROOT, check=True)
    if identity() != invocation:
        raise ValueError('Checkout changed during capture; rerun against one revision')
    aggregate(artifacts, destination, expected, invocation)
    print(f'Prepared {sum(map(len, expected.values()))} screenshots in {destination}', flush=True)


if __name__ == '__main__':
    main()
