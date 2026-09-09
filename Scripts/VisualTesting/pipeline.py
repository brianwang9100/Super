"""Validate complete visual artifacts against the tracked capture inventory."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import warnings

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('Bible', 'Chat', 'Core', 'Todo')
MAX_IMAGE_BYTES = 50_000_000
Image.MAX_IMAGE_PIXELS = 40_000_000


def identity():
    """Bind artifacts to this checkout and Actions invocation, including reruns."""
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if os.environ.get('GITHUB_SHA') and os.environ['GITHUB_SHA'] != sha:
        raise ValueError('Checkout does not match GITHUB_SHA')
    return {'sha': sha, 'run_id': os.environ.get('GITHUB_RUN_ID', 'local'),
            'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT', 'local')}


def validate_rows(rows):
    if not rows:
        raise ValueError('Empty capture inventory')
    names = []
    for row in rows:
        name = row['image']
        dimensions = row['pixels']
        if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+\.png', name)
                or not isinstance(dimensions, list) or len(dimensions) != 2
                or any(type(value) is not int or value <= 0 for value in dimensions)
                or dimensions[0] * dimensions[1] > Image.MAX_IMAGE_PIXELS):
            raise ValueError(f'Invalid capture inventory row: {row}')
        names.append(name)
    if len(set(names)) != len(names):
        raise ValueError('Duplicate capture identities')
    return {row['image']: row['pixels'] for row in rows}


def validate_package_identity(row):
    """Accept a historical mapping or explicit canonical names for a new fixture."""
    if 'legacy' in row:
        if 'testName' in row or 'captureName' in row:
            raise ValueError(f'A capture cannot mix legacy and explicit identities: {row}')
        legacy_name = Path(row['legacy']).name
        variant = row.get('variant')
        if variant is not None:
            if (variant != 'dismissed' or row['package'] != 'Bible'
                    or row['suite'] != 'BibleScreenSnapshotTests'
                    or Path(legacy_name).stem.split('.')[0] not in {
                        'selectionActiveLight', 'selectionActiveDark',
                        'selectionActiveLightXXL', 'selectionActiveDarkXXL'}):
                raise ValueError(f'Unknown shared-baseline variant: {row}')
            legacy_name = f'{Path(legacy_name).stem}-dismissed.png'
        expected = f'{row["package"]}_{row["suite"]}_{legacy_name}'
    else:
        # These are the exporter-sanitized components, not raw #function strings.
        components = [row.get(key) for key in ('suite', 'testName', 'captureName')]
        if (row.get('package') not in PACKAGES or 'variant' in row
                or any(not isinstance(value, str)
                       or not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*', value)
                       for value in components)):
            raise ValueError(f'Invalid explicit capture identity: {row}')
        suite, test_name, capture_name = components
        expected = f'{row["package"]}_{suite}_{test_name}.{capture_name}.png'
    if row.get('image') != expected:
        raise ValueError(f'Package capture identity differs from its fixture mapping: {row}')


def inventories():
    rows = json.loads((Path(__file__).with_name('package-inventory.json')).read_text())
    if {row['package'] for row in rows} != set(PACKAGES):
        raise ValueError('Package inventory must include exactly Bible, Chat, Core, and Todo')
    for row in rows:
        validate_package_identity(row)
    result = {package: [row for row in rows if row['package'] == package] for package in PACKAGES}
    native = []
    for name in ('composer-inventory.json', 'settings-inventory.json'):
        native.extend(json.loads((ROOT / 'Scripts/PreviewPilot' / name).read_text()))
    native.extend({'image': f'Core_PreviewCollectionController.swift_{name}.png', 'pixels': [1206, 540]}
                  for name in ('collection_viewport_light', 'font_panel_light'))
    result['native'] = native
    validate_rows([row for group in result.values() for row in group])
    return result


def validate_images(folder, rows):
    expected = validate_rows(rows)
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError(f'Missing or symlink capture directory: {folder}')
    paths = list(folder.iterdir())
    if {path.name for path in paths} != set(expected):
        actual = {path.name for path in paths}
        raise ValueError(f'Incomplete capture set: missing={sorted(set(expected)-actual)}, '
                         f'extra={sorted(actual-set(expected))}')
    digests = {}
    for path in paths:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_IMAGE_BYTES:
            raise ValueError(f'Invalid image file: {path}')
        try:
            with warnings.catch_warnings():
                warnings.simplefilter('error', Image.DecompressionBombWarning)
                with Image.open(path) as decoded:
                    if decoded.format != 'PNG' or list(decoded.size) != expected[path.name]:
                        raise ValueError(f'Incorrect image format or dimensions: {path}')
                    decoded.verify()
                # verify() checks PNG structure; load() also decodes the full pixel payload.
                with Image.open(path) as decoded:
                    decoded.load()
        except Exception as error:
            raise ValueError(f'Cannot decode expected PNG {path}: {error}') from error
        digests[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return digests


def require_new_output(output):
    if output.exists() or output.is_symlink():
        raise ValueError(f'Output already exists; choose a fresh capture directory: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)


def write_bundle(source, output, shard, rows, invocation, evidence=None):
    digests = validate_images(source, rows)
    require_new_output(output)
    temporary = Path(tempfile.mkdtemp(prefix='.visual-', dir=output.parent))
    try:
        shutil.copytree(source, temporary / 'images')
        manifest = {'schema': 1, 'shard': shard, **invocation, 'images': digests}
        if evidence is not None:
            manifest['environment'] = evidence
        (temporary / 'capture.json').write_text(json.dumps(manifest, indent=2) + '\n')
        temporary.rename(output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def aggregate(artifacts, output, expected, invocation):
    """Reject any incomplete/foreign shard before flattening or publishing output."""
    validate_rows([row for rows in expected.values() for row in rows])
    if (artifacts.is_symlink() or not artifacts.is_dir()
            or {path.name for path in artifacts.iterdir()} != {f'visual-{key}' for key in expected}):
        raise ValueError('Artifact directory must contain the exact expected shard set')
    sources = []
    for shard, rows in expected.items():
        folder = artifacts / f'visual-{shard}'
        if (folder.is_symlink() or not folder.is_dir()
                or {p.name for p in folder.iterdir()} != {'capture.json', 'images'}
                or (folder / 'capture.json').is_symlink()):
            raise ValueError(f'Incomplete or malformed artifact: {shard}')
        manifest = json.loads((folder / 'capture.json').read_text())
        if (manifest.get('schema') != 1 or manifest.get('shard') != shard
                or any(manifest.get(key) != value for key, value in invocation.items())):
            raise ValueError(f'Artifact belongs to another capture invocation: {shard}')
        digests = validate_images(folder / 'images', rows)
        if manifest.get('images') != digests:
            raise ValueError(f'Artifact content changed after validation: {shard}')
        sources.extend((folder / 'images' / name) for name in digests)
    require_new_output(output)
    temporary = Path(tempfile.mkdtemp(prefix='.visual-', dir=output.parent))
    try:
        for source in sources:
            # Exclusive creation remains a second defense against accidental overwrite.
            with source.open('rb') as incoming, (temporary / source.name).open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)
        temporary.rename(output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
