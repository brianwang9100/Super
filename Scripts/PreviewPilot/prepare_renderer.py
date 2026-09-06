#!/usr/bin/env python3
"""Materialize the exact upstream renderer plus the reviewed, test-only viewport patch."""
import hashlib
from pathlib import Path
import subprocess
import tempfile

REVISION = '856a1c1585e31d4113c019050d6d0712cf6ddadc'
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def prepare():
    patch = (HERE / 'renderer.patch').read_bytes()
    digest = hashlib.sha256(patch).hexdigest()
    destination = ROOT / '.build' / 'PreviewPilot' / f'renderer-{REVISION[:12]}-{digest[:12]}'
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='renderer-fetch-', dir=destination.parent) as temporary:
            checkout = Path(temporary) / 'checkout'
            checkout.mkdir()
            for args in [('init',), ('remote', 'add', 'origin', 'https://github.com/getsentry/SnapshotPreviews.git'),
                         ('fetch', '--depth', '1', 'origin', REVISION), ('checkout', '--detach', 'FETCH_HEAD'),
                         ('apply', '--check', str(HERE / 'renderer.patch')), ('apply', str(HERE / 'renderer.patch'))]:
                subprocess.run(['git', '-C', str(checkout), *args], check=True)
            checkout.rename(destination)
    head = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
    diff = subprocess.check_output(['git', '-C', str(destination), 'diff', '--binary', 'HEAD'])
    if head != REVISION or diff != patch:
        raise ValueError('Renderer checkout differs from the reviewed revision and patch')
    return destination, digest


if __name__ == '__main__':
    print(prepare()[0])
