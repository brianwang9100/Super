#!/usr/bin/env python3
"""Require identical complete exports before considering new renderer baselines."""
import hashlib
import json
from pathlib import Path
import sys
from verify import expected_names, verify_exports, verify_sources


def compare(first, second):
    verify_sources()
    verify_exports(first)
    verify_exports(second)
    rows = []
    for name in sorted(expected_names()):
        left = hashlib.sha256((first / name).read_bytes()).hexdigest()
        right = hashlib.sha256((second / name).read_bytes()).hexdigest()
        rows.append({'image': name, 'firstSHA256': left, 'secondSHA256': right,
                     'identicalPNG': left == right})
    return rows


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit('Usage: repeatability.py FIRST_EXPORT SECOND_EXPORT REPORT_JSON')
    rows = compare(Path(sys.argv[1]), Path(sys.argv[2]))
    Path(sys.argv[3]).write_text(json.dumps(rows, indent=2) + '\n')
    count = sum(row['identicalPNG'] for row in rows)
    print(f'{count}/{len(rows)} byte-identical PNGs (therefore identical decoded pixels)')
    sys.exit(0 if count == len(rows) else 1)
