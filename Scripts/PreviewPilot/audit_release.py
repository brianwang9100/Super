#!/usr/bin/env python3
"""Inspect app contents and Mach-O symbols/linkage for pilot fixtures and vendor runtimes."""
import json
from pathlib import Path
import subprocess
import sys

FORBIDDEN = ('SnapshottingTests', 'SnapshotPreviews', 'PreviewsSupport', 'SnapshotSharedModels',
             'SnapshotPreferences', 'SimpleDebugger', 'FlyingFox', 'Sentry', 'Argos',
             'PreviewChatComposer', 'ChatComposerPreviewPulse', 'PreviewCollectionController', 'composer_empty_light')


def audit(app):
    findings = []
    binaries = []
    for path in sorted(app.rglob('*')):
        if not path.is_file():
            continue
        relative = str(path.relative_to(app))
        for word in FORBIDDEN:
            if word in relative:
                findings.append(f'Unexpected artifact: {relative}')
        kind = subprocess.check_output(['file', '-b', str(path)], text=True)
        if 'Mach-O' not in kind:
            continue
        binaries.append(relative)
        evidence = subprocess.check_output(['nm', '-a', str(path)], text=True, stderr=subprocess.DEVNULL)
        evidence += subprocess.check_output(['otool', '-L', str(path)], text=True)
        evidence += subprocess.check_output(['strings', str(path)], text=True)
        for word in FORBIDDEN:
            if word in evidence:
                findings.append(f'{relative}: {word}')
    if not binaries:
        raise ValueError(f'No Mach-O found in {app}')
    return {'app': app.name, 'binariesInspected': binaries, 'findings': findings,
            'status': 'pass' if not findings else 'fail'}


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('Usage: python3 audit_release.py APP [APP ...]')
    results = [audit(Path(arg)) for arg in sys.argv[1:]]
    print(json.dumps(results, indent=2))
    sys.exit(0 if all(row['status'] == 'pass' for row in results) else 1)
