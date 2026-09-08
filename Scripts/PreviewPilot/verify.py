#!/usr/bin/env python3
"""Fail closed on missing, renamed, duplicate, or incomplete pilot images."""
import argparse
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
INVENTORY = Path(__file__).with_name('composer-inventory.json')
GROUPS = [(INVENTORY, 'ChatComposerPreviews.swift', 21),
          (Path(__file__).with_name('settings-inventory.json'), 'SettingsPanePreviews.swift', 18)]
UIKIT = 'Core_PreviewCollectionController.swift_collection_viewport_light.png'
FONTS = 'Core_PreviewCollectionController.swift_font_panel_light.png'


def inventory_rows():
    rows = []
    for path, source, count in GROUPS:
        group = json.loads(path.read_text())
        if len(group) != count or any(row['image'] != f'Chat_{source}_{row["preview"]}.png' for row in group):
            raise ValueError(f'Invalid checked-in capture inventory: {path.name}')
        rows.extend(group)
    return rows


def expected_names():
    rows = inventory_rows()
    names = [row['image'] for row in rows] + [UIKIT, FONTS]
    if len(set(names)) != len(names):
        raise ValueError('Invalid checked-in pilot inventory')
    return names


def verify_names(names):
    expected = set(expected_names())
    if not names or len(names) != len(set(names)) or set(names) != expected:
        raise ValueError(f'Inventory mismatch: count={len(names)}, '
                         f'missing={sorted(expected-set(names))}, extra={sorted(set(names)-expected)}')


def verify_sources():
    for path, filename, _ in GROUPS:
        rows = json.loads(path.read_text())
        source = ROOT / 'Packages/Chat/Sources/Chat/UI/Previews' / filename
        names = re.findall(r'#Preview\("([^"]+)"', source.read_text())
        if len(names) != len(set(names)) or set(names) != {row['preview'] for row in rows}:
            raise ValueError(f'Source declarations are missing, duplicated, or renamed: {filename}')


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
    dimensions = {row['image']: tuple(row['pixels']) for row in inventory_rows()}
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
    print(f'Verified exactly {len(expected_names())} captures across {len(GROUPS)} Chat fixture groups + 2 UIKit probes')


if __name__ == '__main__':
    main()
