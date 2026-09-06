#!/usr/bin/env python3
"""Fail closed on missing, renamed, duplicate, or incomplete pilot images."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
INVENTORY = Path(__file__).with_name('composer-inventory.json')
UIKIT = 'Core_PreviewCollectionController.swift_collection_viewport_light.png'
FONTS = 'Core_PreviewCollectionController.swift_font_panel_light.png'


def expected_names():
    rows = json.loads(INVENTORY.read_text())
    names = [row['image'] for row in rows] + [UIKIT, FONTS]
    if len(rows) != 21 or len(set(names)) != 23:
        raise ValueError('Invalid checked-in pilot inventory')
    return names


def verify_names(names):
    expected = set(expected_names())
    if not names or len(names) != len(set(names)) or set(names) != expected:
        raise ValueError(f'Inventory mismatch: count={len(names)}, '
                         f'missing={sorted(expected-set(names))}, extra={sorted(set(names)-expected)}')


def verify_sources():
    rows = json.loads(INVENTORY.read_text())
    source = ROOT / 'Packages/Chat/Sources/Chat/UI/Previews/ChatComposerPreviews.swift'
    names = re.findall(r'#Preview\("([^"]+)"', source.read_text())
    if len(names) != len(set(names)) or set(names) != {row['preview'] for row in rows}:
        raise ValueError('Source declarations are missing, duplicated, or renamed')
    for row in rows:
        digest = hashlib.sha256((ROOT / row['baseline']).read_bytes()).hexdigest()
        if digest != row['baselineSHA256']:
            raise ValueError(f'Legacy baseline changed: {row["baseline"]}')


def verify_exports(folder):
    names = [p.name for p in folder.glob('*.png')]
    verify_names(names)
    sidecars = {p.stem + '.png' for p in folder.glob('*.json')}
    if sidecars != set(names):
        raise ValueError('Missing or extra metadata sidecars')
    for name in names:
        data = (folder / name).read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 24:
            raise ValueError(f'Invalid PNG: {name}')
        width, height = struct.unpack('>II', data[16:24])
        verify_dimensions(name, width, height)
        metadata = json.loads((folder / name).with_suffix('.json').read_text())
        display_name = name.split('.swift_', 1)[1].removesuffix('.png')
        if (metadata.get('display_name') != display_name
                or metadata.get('context', {}).get('preview', {}).get('display_name') != display_name):
            raise ValueError(f'Missing or wrong preview identity in metadata: {name}')


def verify_dimensions(name, width, height):
    dimensions = {row['image']: tuple(row['pixels']) for row in json.loads(INVENTORY.read_text())}
    dimensions.update({UIKIT: (1206, 540), FONTS: (1206, 540)})
    if (width, height) != dimensions.get(name):
        raise ValueError(f'Capture dimensions differ from the fixture contract for {name}: {width}x{height}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--names', type=Path)
    group.add_argument('--exports', type=Path)
    args = parser.parse_args()
    verify_sources()
    if args.names:
        verify_names(args.names.read_text().splitlines())
    else:
        verify_exports(args.exports)
    print('Verified exactly 21 ChatComposer previews + 2 UIKit probes')


if __name__ == '__main__':
    main()
