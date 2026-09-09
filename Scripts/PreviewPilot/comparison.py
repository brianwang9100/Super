"""Compare native captures with repository PNGs; recording is explicit and local."""
import json
import os
from pathlib import Path
import shutil
import tempfile

from PIL import Image, ImageChops
from verify import expected_names, verify_dimensions, verify_exports, verify_names

BASELINES = Path(__file__).with_name('__Snapshots__')
PNG_END = b'\x00\x00\x00\x00IEND\xaeB`\x82'
# Two independent local native runs reproduced the same 167 pixels across 20/41
# CI baselines: RGB channel rounding of one, with no alpha changes. The largest
# image-level fraction was 38/539082 (0.00705%). Keep a narrow universal bound:
# at most one changed pixel per 10,000 pixels (0.01%), RGB delta <= 1, exact alpha.
MAX_RGB_CHANNEL_DELTA = 1
PIXELS_PER_ROUNDING_PIXEL = 10_000


def require_local_recording():
    """Reject recording before creating output or modifying any baseline in CI."""
    if any(os.environ.get(key) for key in ('CI', 'GITHUB_ACTIONS')):
        raise ValueError('Snapshot recording is forbidden in CI or GITHUB_ACTIONS')


def decode(path):
    """Fully decode a complete PNG into unpremultiplied RGBA pixels."""
    if not path.read_bytes().endswith(PNG_END):
        raise ValueError(f'Incomplete PNG: {path.name}')
    try:
        with Image.open(path) as image:
            if image.format != 'PNG':
                raise ValueError(f'Expected PNG: {path.name}')
            verify_dimensions(path.name, *image.size)
            image.verify()
        with Image.open(path) as image:
            image.load()
            return image.convert('RGBA')
    except (OSError, SyntaxError, IndexError) as error:
        raise ValueError(f'Invalid PNG {path.name}: {error}') from error



def difference(expected, actual, path):
    """Write a visible red mask even when the difference is in alpha alone."""
    delta = ImageChops.difference(expected, actual)
    mask = delta.getchannel('R')
    for band in ('G', 'B', 'A'):
        mask = ImageChops.lighter(mask, delta.getchannel(band))
    histogram = mask.histogram()
    changed = sum(histogram[1:])
    maximum = max(index for index, count in enumerate(histogram) if count)
    alpha_maximum = delta.getchannel('A').getextrema()[1]
    rgb_maximum = max(delta.getchannel(band).getextrema()[1] for band in ('R', 'G', 'B'))
    backdrop = actual.convert('L').convert('RGB').point(lambda value: value // 3)
    backdrop.paste((255, 0, 0), mask=mask.point(lambda value: 255 if value else 0))
    backdrop.save(path)
    return changed, maximum, rgb_maximum, alpha_maximum


def compare(exports, artifacts, *, baselines=BASELINES):
    """Fail closed except for bounded RGB rounding; alpha must always match exactly."""
    exports, artifacts, baselines = map(Path, (exports, artifacts, baselines))
    artifacts.mkdir(parents=True, exist_ok=False)
    errors, rows = [], []
    for validator in (lambda: verify_exports(exports),
                      lambda: verify_names([path.name for path in baselines.glob('*.png')])):
        try:
            validator()
        except (ValueError, OSError, KeyError) as error:
            errors.append(str(error))
    names = set(expected_names()) | {p.name for folder in (exports, baselines) for p in folder.glob('*.png')}
    for kind in ('expected', 'actual', 'diff'):
        (artifacts / kind).mkdir()
    for name in sorted(names):
        expected_path, actual_path = baselines / name, exports / name
        row = {'image': name, 'status': 'equal'}
        try:
            if not expected_path.is_file() or not actual_path.is_file():
                raise ValueError('Missing baseline' if not expected_path.is_file() else 'Missing capture')
            expected, actual = decode(expected_path), decode(actual_path)
            if expected.size != actual.size:
                raise ValueError(f'Dimension mismatch: expected {expected.size}, actual {actual.size}')
            if expected.tobytes() != actual.tobytes():
                changed, maximum, rgb_maximum, alpha_maximum = difference(expected, actual, artifacts / 'diff' / name)
                total = expected.width * expected.height
                # Integer arithmetic makes the inclusive 0.01% boundary exact.
                rounding = (alpha_maximum == 0 and rgb_maximum <= MAX_RGB_CHANNEL_DELTA
                            and changed * PIXELS_PER_ROUNDING_PIXEL <= total)
                row.update(status='accepted-rounding' if rounding else 'changed', changedPixels=changed,
                           maxChannelDelta=maximum, maxRGBChannelDelta=rgb_maximum,
                           maxAlphaChannelDelta=alpha_maximum, changedPixelFraction=changed / total,
                           totalPixels=total)
        except (ValueError, OSError, SyntaxError) as error:
            row.update(status='invalid', error=str(error))
        if row['status'] != 'equal':
            for source, kind in ((expected_path, 'expected'), (actual_path, 'actual')):
                if source.is_file():
                    shutil.copy2(source, artifacts / kind / name)
        rows.append(row)
    passed = not errors and all(row['status'] in ('equal', 'accepted-rounding') for row in rows)
    rounded = [row for row in rows if row['status'] == 'accepted-rounding']
    summary = {'passed': passed, 'comparison': 'decoded RGBA with bounded RGB rounding',
               'roundingPolicy': {'maxRGBChannelDelta': MAX_RGB_CHANNEL_DELTA, 'maxAlphaChannelDelta': 0,
                                  'maxChangedPixelFraction': 1 / PIXELS_PER_ROUNDING_PIXEL},
               'acceptedRoundingImages': len(rounded),
               'acceptedRoundingPixels': sum(row['changedPixels'] for row in rounded),
               'errors': errors, 'images': rows}
    (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    if not passed:
        raise ValueError(f'Native snapshot comparison failed; evidence: {artifacts}')
    return summary


def record(exports, artifacts, *, baselines=BASELINES):
    """Validate the whole inventory before explicitly replacing local baselines."""
    require_local_recording()
    exports, artifacts, baselines = map(Path, (exports, artifacts, baselines))
    verify_exports(exports)
    names = sorted(expected_names())
    # Decode every image before the first baseline mutation, including PNG CRCs.
    for name in names:
        decode(exports / name)
    if baselines.is_symlink() or any((baselines / name).is_symlink() for name in names):
        raise ValueError('Refusing to record through a baseline symlink')
    extra = {p.name for p in baselines.glob('*.png')} - set(names)
    if extra:
        raise ValueError(f'Refusing to silently delete unexpected baselines: {sorted(extra)}')
    baselines.mkdir(parents=True, exist_ok=True)
    # Atomic replacement per PNG preserves existing files if a copy fails.
    for name in names:
        with tempfile.NamedTemporaryFile(dir=baselines, prefix='.record-', delete=False) as temporary:
            staged = Path(temporary.name)
        try:
            shutil.copy2(exports / name, staged)
            staged.replace(baselines / name)
        finally:
            staged.unlink(missing_ok=True)
    return compare(exports, artifacts, baselines=baselines)
